#!/system/bin/sh
# DeX Display Control (module id fold-display): resolution and refresh rate for an external display
# on the Fold's USB-C DisplayPort, kept in line with DeX, the apps' frame clock and the phone screen.
#
# How the pieces fit (all found on this Fold, One UI 9 / Android 17, 2026-11-17):
# - Qualcomm's composer fixes the output mode once, when a display connects: the EDID's preferred
#   mode, unless vendor.display.hdmi_cfg_idx holds "width:height:fps:format". Any other shape (a
#   plain index) crash-loops the composer, so every value goes through valid() first.
# - SurfaceFlinger never changes an external display's mode after connect (setDesiredMode returns
#   early for External), so a change means reconnecting: forcing the DRM connector off and on.
# - DisplayManager keeps a "user preferred mode" per display (DeX writes one on first connect) and
#   sizes the DeX desktop from it; it must equal the cable's mode or DeX is zoomed or cropped. It is
#   only re-read when the display is added again, so it is set before the reconnect.
# - Apps take their frame clock from SurfaceFlinger's pacesetter display, the inner panel even in
#   DeX (capped at 60 Hz there). forcePacesetter (SurfaceFlingerAIDL code 84; 85 resets) hands it to
#   the external display. SurfaceFlinger drops it whenever it re-adds a display, so it is checked
#   again every 30 s while a monitor is connected.
# - /sys/class/dp_sec/dp_error_info is NOT live (it kept a previous monitor's name and mode). Names
#   and EDIDs come from the DRM connector, modes from SurfaceFlinger, the link from the kernel's
#   mode-set line (captured right after each connect: the ring buffer only holds ~90 s here).
# - The phone's own screens are power group 0, the external display its own group, so
#   `cmd power sleep --display-id 0` darkens only the phone and DeX keeps running without a lock.
# - Experimental extra refresh rates: Qualcomm's DP debugfs takes a replacement EDID (drm_dp/edid, hex text) and
#   uses it at the next hotplug - for whatever monitor that is; while it is set the kernel does not
#   read the monitor's own EDID at all. Samsung's dp_sec "ExtDispOff,1" / "ExtDispOff,0" (written to
#   /sys/class/dp_sec/dex) switches the DP output off and on again, which is a full hotplug in software
#   (link retrained, EDID re-read): it applies a new EDID without touching the cable (tested 2026-11-17).
#   Clearing is `echo 0 > drm_dp/sim`, done only while the output is off (it aborts DP AUX traffic).
#   Writing invalid hex to drm_dp/edid did NOT clear it on Samsung's kernel (a Dell's custom EDID went
#   to the next monitor, an LG), and a short valid string makes a 0-byte custom EDID: neither is used.
#   Every connect compares the EDID read with the custom one and repairs a leak by itself.
# - The real limit of the DisplayPort output is link bandwidth: 4 lanes x HBR2 = 17.28 Gbit/s after
#   coding (dp_display_validate_link_clock). Samsung trains HBR2 even when HBR3 is allowed in debugfs,
#   and a monitor whose USB hub is in use may get only 2 lanes (8.64 Gbit/s). The 675 MHz
#   qcom,max-pclk-frequency-khz is not the limit: the engine runs two pixels per clock (an LG at
#   5120x2160 60 Hz runs 704 MHz).
# Desired mode on connect: this module's profile for the monitor variant (same monitor, same mode
# list), else its profile for the monitor, else DeX's own preferred mode, else the EDID default -
# each only if the monitor offers it right now.

BASE=/data/adb/fold-display
PROF=$BASE/profiles
SET=$BASE/settings
CONN=/sys/class/drm/card0-DP-1
PROP=vendor.display.hdmi_cfg_idx
LOG=$BASE/display.log
LINK=$BASE/link.txt
DMC=$BASE/dm.cache
DBG=/sys/kernel/debug/drm_dp
mkdir -p "$PROF"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# One state-changing action at a time (commands, the confirmation timer, the watcher's connect
# handling): they all reconnect the monitor and would otherwise trip over each other. mkdir is atomic;
# a lock whose owner died is taken over; after 2 minutes the waiter goes ahead anyway.
LOCKD=$BASE/op.lock
lock() {
    i=0
    while ! mkdir "$LOCKD" 2>/dev/null; do
        o=$(cat "${LOCKD:?}/pid" 2>/dev/null)
        if [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null; then
            rm -f "${LOCKD:?}/pid"; rmdir "$LOCKD" 2>/dev/null; continue
        fi
        i=$((i + 1)); [ "$i" -ge 120 ] && { log "lock held by ${o:-?} for 2 minutes; going ahead"; break; }
        sleep 1
    done
    echo $$ > "${LOCKD:?}/pid" 2>/dev/null
}
unlock() {
    o=$(cat "${LOCKD:?}/pid" 2>/dev/null)
    [ "$o" = $$ ] || [ -z "$o" ] || return 0
    rm -f "${LOCKD:?}/pid"; rmdir "$LOCKD" 2>/dev/null
}

# Start "$@" detached in its own session, then wait a moment before returning: the caller (KernelSU's
# service stage, or the page through ksu.exec) may end its process group as soon as this script
# exits, and that killed children before setsid had moved them out (found 2026-11-17: the watcher
# and the phone guard silently did not start).
spawn() {
    setsid "$@" </dev/null >/dev/null 2>>"$BASE/watch.err" &
    sleep 1
}

connected() { read -r s < $CONN/status 2>/dev/null; [ "$s" = connected ]; }

edid_hex() { od -An -tx1 -v $CONN/edid 2>/dev/null | tr -d ' \n'; }

edid_id() { od -An -tx1 -j8 -N8 $CONN/edid 2>/dev/null | tr -d ' \n'; }

valid() { echo "$1" | grep -qE '^[0-9]{3,5}:[0-9]{3,5}:[0-9]{2,3}:1$'; }

# settings: key=value lines
get_set() { sed -n "s/^$1=//p" "$SET" 2>/dev/null | head -n 1; }
put_set() {
    { grep -v "^$1=" "$SET" 2>/dev/null; [ -n "$2" ] && echo "$1=$2"; } > "$SET.tmp"
    mv -f "$SET.tmp" "$SET"
}

# From `dumpsys SurfaceFlinger --displays` on stdin, the external display's block (empty if none).
ext_from() {
    blk=""; ext=0
    while IFS= read -r l; do
        case "$l" in
            "Display "*)
                [ "$ext" = 1 ] && { printf '%s\n' "$blk"; return 0; }
                blk="$l"; ext=0 ;;
            *connectionType=External*) ext=1; blk="$blk
$l" ;;
            *) blk="$blk
$l" ;;
        esac
    done
    [ "$ext" = 1 ] && printf '%s\n' "$blk"
}

ext_block() { dumpsys SurfaceFlinger --displays 2>/dev/null | ext_from; }

ext_sf_id() { b=$(ext_block); b=${b%%
*}; echo "${b#Display }"; }

# "1920x1080@120.00" -> "1920:1080:120"
to_key() {
    res=${1%@*}; hz=${1#*@}
    int=${hz%.*}; dec=${hz#*.}; [ "$dec" = "$hz" ] && dec=0
    case "$dec" in [5-9]*) int=$((int + 1)) ;; esac
    echo "${res%x*}:${res#*x}:$int"
}

modes_of() { sed -n 's/^ *{id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/\1@\2/p'; }

# Space-separated W:H:HZ keys the external display offers now.
offered() { ext_block | modes_of | while read -r m; do printf '%s ' "$(to_key "$m")"; done; }

# Monitor variant: same EDID id, same mode list (XREAL ultrawide, or the 4K 75 Hz test EDID).
variant() { ext_block | modes_of | sort -u | cksum | sed 's/ .*//'; }

active_mode() {
    ext_block | sed -n 's/.*activeMode={id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/\1@\2/p' | head -n 1
}

# Wait (up to ~30 s) until SurfaceFlinger has the external display; prints its id.
wait_sf() {
    i=0
    while [ "$i" -lt 15 ]; do
        s=$(ext_sf_id)
        [ -n "$s" ] && { echo "$s"; return 0; }
        sleep 2; i=$((i + 1))
    done
    return 1
}

# DisplayManager's logical display id for SurfaceFlinger display $1 (matched by uniqueId).
dm_id() {
    dumpsys display 2>/dev/null | grep -F "mBaseDisplayInfo=DisplayInfo{" | grep -m1 -F "uniqueId \"local:$1\"" |
        sed -n 's/.*displayId \([0-9]*\).*/\1/p'
}

# DisplayManager's user preferred mode for logical display $1 as "W:H:HZ", empty if none.
dm_pref() {
    p=$(cmd display get-user-preferred-display-mode "$1" 2>/dev/null)
    p=${p#*: }
    set -- $p
    [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
    to_key "${1}x${2}@${3}"
}

dm_set() { cmd display set-user-preferred-display-mode "$2" "$3" "$4" "$1" >/dev/null 2>&1; }

dm_clear() { cmd display clear-user-preferred-display-mode "$1" >/dev/null 2>&1; }

# replug.busy marks our own reconnects, so the watcher does not treat them as an unplug.
reconnect() {
    log "reconnect (override '$(getprop $PROP)')"
    rm -f "$DMC"
    touch "$BASE/replug.busy"
    echo off > $CONN/status
    sleep 2
    echo detect > $CONN/status
    sleep 2
    rm -f "$BASE/replug.busy"
}

# Commands wait (up to 20 s) while a reconnect of ours is in progress, instead of failing on it.
settle() {
    i=0
    while [ -f "$BASE/replug.busy" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
    connected && wait_sf >/dev/null
}

pace_now() {
    sid=$(ext_sf_id)
    [ -n "$sid" ] || return 1
    service call SurfaceFlingerAIDL 84 i64 "$sid" >/dev/null 2>&1 && log "pacesetter -> $sid"
}

pacesetter_ok() {
    sid=$(ext_sf_id)
    [ -z "$sid" ] && return 0
    p=$(dumpsys SurfaceFlinger --scheduler 2>/dev/null | sed -n 's/^ *pacesetterDisplayId=\([0-9]*\).*/\1/p' | head -n 1)
    [ "$p" = "$sid" ]
}

# After a connect: hand the apps' clock to the display and keep the kernel's mode-set line.
pace() {
    wait_sf >/dev/null || return
    # Let a reconnect or DeX rebuild settle first: a display removed right after being made
    # pacesetter would leave SurfaceFlinger without one.
    sleep 5
    pace_now || return
    l=$(dmesg 2>/dev/null | grep "dp_panel_resolution_info: [0-9]" | tail -n 1)
    l=${l#*dp_panel_resolution_info: }
    [ -n "$l" ] && echo "$(edid_id)|$l" > "$LINK"
    dsc_note
    mode_info
    rm -f "$DMC"
}

unpace() { service call SurfaceFlingerAIDL 85 >/dev/null 2>&1 && log "pacesetter reset to the Fold"; }

# Point composer and DisplayManager at mode $1 (W:H:HZ, or empty for the monitor's own default)
# and reconnect so both take it. $2 = SurfaceFlinger display id (for the DisplayManager lookup).
dex_recover_cmd() {
    case "$1" in
        on) put_set dex_recover 1; log "switch: bring DeX back after a reconnect ON"; echo "ok=1" ;;
        off) put_set dex_recover 0; log "switch: bring DeX back after a reconnect OFF"; echo "ok=1" ;;
        *) echo "error=use: dex-recover on|off" ;;
    esac
}

# Monitor detection without a monitor connected: auto (the watcher looks every 3 s, every 15 s with
# the screens off) or on request (it waits without any timer until `display.sh wake` or the page).
MANUAL=$BASE/detect.manual
wake_watcher() {
    # Opened read-write so it never blocks, also when no watcher holds the FIFO.
    [ -p "$BASE/tick" ] && echo 1<>"$BASE/tick"
}
detect_cmd() {
    case "$1" in
        auto) rm -f "$MANUAL"; log "switch: detect a monitor by itself ON"; wake_watcher; echo "ok=1" ;;
        manual) : > "$MANUAL"; log "switch: detect a monitor by itself OFF (on request)"; wake_watcher; echo "ok=1" ;;
        *) echo "error=use: detect auto|manual" ;;
    esac
}

# DeX running on the external display right now?
dex_on() {
    s=$(ext_sf_id); [ -n "$s" ] || return 1
    dumpsys display 2>/dev/null | grep -F "mBaseDisplayInfo=DisplayInfo{" | grep -F "uniqueId \"local:$s\"" | grep -q FLAG_EXTERNAL_DEX_HOSTING
}

# After a reconnect: if DeX was running before ($1 = 1) but Samsung's DeX does not take the monitor
# back (seen: "desktop ineligible" right after a quick reconnect, the monitor left in mirroring), a
# second reconnect brings it back.
dex_recover() {
    [ "$1" = 1 ] && [ "$(get_set dex_recover)" != 0 ] || return 0
    i=0; while [ "$i" -lt 13 ]; do sleep 2; dex_on && return 0; i=$((i + 1)); done
    log "DeX did not come back after the reconnect; reconnecting once more"
    reconnect
    i=0; while [ "$i" -lt 13 ]; do sleep 2; dex_on && { log "DeX back"; return 0; }; i=$((i + 1)); done
    log "DeX still not back; start DeX from the quick settings"
}

apply_mode() {
    want=$1; sid=$2
    wasdex=0; dex_on && wasdex=1
    dmid=""; [ -n "$sid" ] && dmid=$(dm_id "$sid")
    if [ -n "$want" ]; then
        setprop $PROP "$want:1"
        if [ -n "$dmid" ]; then
            IFS=: read -r w h hz <<EOF
$want
EOF
            dm_set "$dmid" "$w" "$h" "$hz"
        fi
    else
        setprop $PROP ""
        [ -n "$dmid" ] && dm_clear "$dmid"
    fi
    reconnect
    dex_recover $wasdex
}

profile_for() { # $1 id, $2 variant -> saved W:H:HZ (without :1) or empty
    v=$(cat "$PROF/$1-$2" 2>/dev/null)
    [ -z "$v" ] && v=$(cat "$PROF/$1" 2>/dev/null)
    valid "$v" && echo "${v%:1}"
}

status() {
    # Kept lean because the page polls it every second while open: one pass per source, shell
    # builtins for the rest, and the heavy `dumpsys display` cached 10 s ("status full" skips it).
    read -r up _ < /proc/uptime
    echo "t=$up"
    echo "phone_guard=$(get_set phone_guard)"
    echo "inner_hz=$(get_set inner_hz)"
    # Whole-phone power, only read when someone asks (the page while it is open): the fuel gauge's
    # system current (ISYS, mA; Samsung reports it as power_now/power_avg) and system voltage (mV).
    # It covers the whole phone whether it runs on its battery or on the monitor's or a charger's power.
    PS=/sys/class/power_supply/battery
    read -r v 2>/dev/null < $PS/power_now && echo "sys_ma=$v"
    read -r v 2>/dev/null < $PS/power_avg && echo "sys_ma_avg=$v"
    read -r v 2>/dev/null < $PS/voltage_sys && echo "sys_mv=$v"
    read -r v 2>/dev/null < $PS/status && echo "batt_status=$v"
    read -r d1 < /sys/class/drm/card0-DSI-1/dpms 2>/dev/null
    read -r d2 < /sys/class/drm/card0-DSI-2/dpms 2>/dev/null
    [ "$d1" = On ] || [ "$d2" = On ] && echo "phone=on" || echo "phone=off"
    [ -f "$BASE/guard.armed" ] && echo "armed=1" || echo "armed=0"
    [ -f "$BASE/custom.active" ] && { read -r ca < "$BASE/custom.active"; echo "custom=active:$ca"; }
    [ -f "$BASE/extra.modes" ] && { read -r xm < "$BASE/extra.modes"; echo "extra_modes=$xm"; }
    [ -d "$EXTRA" ] && for f in "$EXTRA"/*; do [ -f "$f" ] && case "$f" in *.off) ;; *) echo "extra_on=${f##*/}" ;; esac; done
    echo "dsc_auto=$(get_set dsc_auto)"
    [ -d "$DSCD" ] && for f in "$DSCD"/*; do [ -f "$f" ] && { read -r v < "$f"; echo "dsc_mon=${f##*/}:$v"; }; done
    [ -f "$BASE/modeinfo" ] && while read -r v; do echo "mi=$v"; done < "$BASE/modeinfo"
    [ -f "$BASE/dsc.state" ] && { read -r v < "$BASE/dsc.state"; echo "dsc_active=$v"; }
    if [ -f "$CONF" ]; then
        read -r _ cp cd < "$CONF"; read -r u _ < /proc/uptime; u=${u%.*}
        echo "confirm_prev=$cp"; echo "confirm_left=$((cd - u > 0 ? cd - u : 0))"
    fi
    # Heat: Android's thermal status and the HAL's temperatures (one cheap dumpsys), and how far the
    # GPU and the fastest CPU cores are held back right now (sysfs).
    dumpsys thermalservice 2>/dev/null | sed -n -e 's/^Thermal Status: \([0-9]*\).*/th_status=\1/p' \
        -e '/Current temperatures from HAL/,/Current cooling/s/.*mValue=\([0-9.]*\), mType=[0-9]*, mName=\([A-Z]*\), mStatus=\([0-9]*\).*/t_\2=\1:\3/p'
    G=/sys/class/kgsl/kgsl-3d0
    read -r v 2>/dev/null < $G/max_gpuclk && echo "gpu_max=$v"
    read -r v 2>/dev/null < $G/gpuclk && echo "gpu_now=$v"
    read -r v _ 2>/dev/null < $G/gpu_available_frequencies && echo "gpu_top=$v"
    read -r v _ 2>/dev/null < $G/gpu_busy_percentage && echo "gpu_busy=$v"
    read -r v 2>/dev/null < /sys/kernel/gpu/gpu_max_clock && echo "gpu_smax=$v"
    # Per CPU core group: current : maximum allowed now : hardware maximum (kHz), and the group's
    # busy and total time from /proc/stat (two readings give the load).
    for c in /sys/devices/system/cpu/cpufreq/policy*; do
        read -r a1 2>/dev/null < $c/scaling_cur_freq; read -r a2 2>/dev/null < $c/scaling_max_freq; read -r a3 2>/dev/null < $c/cpuinfo_max_freq
        read -r rc 2>/dev/null < $c/related_cpus
        bz=0; tt=0
        while read -r cn us ni sy id io irq sirq st _; do
            case "$cn" in cpu[0-9]*) ;; *) continue ;; esac
            case " $rc " in *" ${cn#cpu} "*) ;; *) continue ;; esac
            b1=$((us + ni + sy + irq + sirq + st)); bz=$((bz + b1)); tt=$((tt + b1 + id + io))
        done < /proc/stat
        echo "cpu_${c##*/}=$a1:$a2:$a3:$bz:$tt"
    done
    for c in /sys/devices/system/cpu/cpufreq/policy*; do pol=$c; done
    read -r v 2>/dev/null < $pol/scaling_max_freq && echo "cpu_max=$v"
    read -r v 2>/dev/null < $pol/cpuinfo_max_freq && echo "cpu_top=$v"
    echo "thermal_fallback=$(get_set thermal_fallback)"
    echo "dex_recover=$(get_set dex_recover)"
    if [ -f "$MANUAL" ]; then echo "detect=manual"; else echo "detect=auto"; fi
    # The page is open: a watcher waiting for a request takes a look now.
    [ -f "$BASE/asleep" ] && { rm -f "$BASE/asleep"; wake_watcher; }
    echo "desk_mode=$(get_set desk_mode)"
    echo "desk_limits=$(get_set desk_bat):$(get_set desk_ap):$(get_set desk_skin)"
    [ -f "$BASE/desk.state" ] && { read -r v < "$BASE/desk.state"; echo "desk_state=$v"; }
    [ -f "$THL" ] && { read -r _ tp _ < "$THL"; echo "thermal_lowered=$tp"; }
    disp=$(dumpsys SurfaceFlinger --displays 2>/dev/null)
    # One pass over SurfaceFlinger's displays: the phone panel that is on (render rate, id).
    cur=""; typ=""; pm=""; inid=""
    while IFS= read -r l; do
        case "$l" in
            "Display "*) cur=${l#Display }; typ=""; pm="" ;;
            *connectionType=*) typ=${l#*=} ;;
            *powerMode=*) pm=${l#*=} ;;
            *renderRate=*) [ "$typ" = Internal ] && [ "$pm" = ON ] && { r=${l#*=}; echo "inner_rate=${r% Hz}"; inid=$cur; } ;;
        esac
    done <<EOF
$disp
EOF
    b=""; sfid=""
    if connected; then
        b=$(printf '%s\n' "$disp" | ext_from)
        sfid=${b%%
*}; sfid=${sfid#Display }
    fi
    # Pacesetter and the frame counters (HWC + GPU) of the monitor and of the phone panel; two
    # readings give frames per second.
    pid=""; n=0; ni=0; sp=${sfid:-none}; ip=${inid:-none}
    while IFS='=' read -r k v; do
        case "$k" in
            pid) pid=$v ;;
            fc) n=$((n + v)) ;;
            fi) ni=$((ni + v)) ;;
        esac
    done <<EOF
$(dumpsys SurfaceFlinger --scheduler 2>/dev/null | sed -n \
    -e 's/^ *pacesetterDisplayId=\([0-9]*\).*/pid=\1/p' \
    -e "/^[A-Za-z]* Display $sp\$/,/^[A-Za-z]* Display [0-9]/s/^ *[HG][WP][CU] frame count: \([0-9]*\).*/fc=\1/p" \
    -e "/^[A-Za-z]* Display $ip\$/,/^[A-Za-z]* Display [0-9]/s/^ *[HG][WP][CU] frame count: \([0-9]*\).*/fi=\1/p")
EOF
    [ -n "$inid" ] && echo "inner_frames=$ni"
    if [ -z "$sfid" ]; then
        connected && echo "connected=1" || echo "connected=0"
        return 0
    fi
    echo "connected=1"
    echo "edid=$(edid_hex)"
    bid=$(edid_id); [ -f "$BASE/bad/$bid" ] && echo "bad=$(tr '\n' ' ' < "$BASE/bad/$bid")"
    [ -s "$XR/$bid" ] && echo "own=$(tr '\n' ' ' < "$XR/$bid")"
    echo "sfid=$sfid"
    printf '%s\n' "$b" | sed -n \
        -e 's/.*activeMode={id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/current=\1@\2/p' \
        -e 's/^ *renderRate=\([0-9.]*\) Hz.*/render=\1/p' \
        -e 's/^ *{id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/mode=\1@\2/p'
    echo "frames=$n"
    if [ "$pid" = "$sfid" ]; then
        echo "pacesetter=1"
    else
        echo "pacesetter=0"
        printf '%s\n' "$disp" | sed -n "/^Display $pid\$/,/^Display /s/^ *renderRate=\([0-9.]*\) Hz.*/apprate=\1/p"
    fi
    # Android's (and so DeX's) view of the display, and the monitor variant (cached 10 s).
    ct=""; cs=""; [ -f "$DMC" ] && read -r ct cs _ < "$DMC"
    if [ "$1" = full ] || [ -z "$ct" ] || [ "$cs" != "$sfid" ] || [ "${up%.*}" -ge $((ct + 10)) ] || [ "${up%.*}" -lt "$ct" ]; then
        di=$(dumpsys display 2>/dev/null | grep -F "mBaseDisplayInfo=DisplayInfo{" | grep -m1 -F "uniqueId \"local:$sfid\"")
        dmid=${di#*displayId }; dmid=${dmid%%[!0-9]*}
        nm=${di#*DisplayInfo\{\"}; nm=${nm%%\"*}
        case "$di" in *FLAG_EXTERNAL_DEX_HOSTING*) dex=1 ;; *) dex=0 ;; esac
        real=""; case "$di" in *", real "*) real=${di#*, real }; real=${real%%,*}; real=$(echo $real | tr -d ' ') ;; esac
        dens=""; case "$di" in *", density "*) dens=${di#*, density }; dens=${dens%%[!0-9]*} ;; esac
        pref=""; [ -n "$dmid" ] && pref=$(dm_pref "$dmid")
        var=$(printf '%s\n' "$b" | modes_of | sort -u | cksum | sed 's/ .*//')
        printf '%s %s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "${up%.*}" "$sfid" "$dmid" "$nm" "$dex" "$real" "$dens" "$pref" "$var" > "$DMC"
    fi
    { read -r _; read -r dmid; read -r nm; read -r dex; read -r real; read -r dens; read -r pref; read -r var; } < "$DMC"
    echo "name=$nm"
    echo "dmid=$dmid"
    echo "dex=$dex"
    echo "dexsize=$real"
    echo "density=$dens"
    echo "dexpref=$pref"
    echo "variant=$var"
    [ -f "$LINK" ] && { read -r l < "$LINK"; echo "link=$l"; }
    for f in "$PROF"/*; do
        [ -f "$f" ] || continue
        read -r v < "$f"
        echo "profile=${f##*/}:$v"
    done
    echo "prop=$(getprop $PROP)"
}

set_mode() {
    key=$1
    valid "$key:1" || { echo "error=Invalid mode: $key"; return 1; }
    settle
    connected || { echo "error=No external display connected"; return 1; }
    id=$(edid_id)
    [ -n "$id" ] || { echo "error=Cannot identify the monitor (no EDID)"; return 1; }
    case " $(offered)" in
        *" $key "*) ;;
        *) echo "error=This monitor does not offer $key"; return 1 ;;
    esac
    var=$(variant)
    prev=$(active_mode); prev=${prev:+$(to_key "$prev")}
    arm=0
    pc=""; [ -f "$CONF" ] && read -r _ pc _ < "$CONF"
    if [ "$pc" = DSC ]; then
        :   # DSC itself still waits for confirmation; that one undoes everything if needed.
    elif [ "$2" != keep ] && [ -n "$prev" ] && [ "$prev" != "$key" ] && experimental "$id"; then
        # Keep the first unconfirmed mode's predecessor if one is already pending.
        p0=""; [ -f "$CONF" ] && read -r _ p0 _ < "$CONF"
        echo "$id-$var ${p0:-$prev} $(($(up_s) + CONF_S + 12))" > "$CONF"
        arm=1
    elif [ -f "$CONF" ]; then
        rm -f "${CONF:?}"
    fi
    echo "$key:1" > "$PROF/$id-$var"
    echo "$id" > "$BASE/last"
    log "set $id ($var) -> $key"
    apply_mode "$key" "$(ext_sf_id)"
    spawn sh "$0" pace
    [ "$arm" = 1 ] && { spawn sh "$0" revert-timer; echo "confirm=$CONF_S"; }
    echo "ok=1"
}

reset_mode() {
    settle
    connected || { echo "error=No external display connected"; return 1; }
    id=$(edid_id)
    rm -f "$PROF/$id-$(variant)" "$PROF/$id"
    log "reset $id to the monitor's own default mode"
    apply_mode "" "$(ext_sf_id)"
    spawn sh "$0" pace
    echo "ok=1"
}

# Called by the watcher when a display appears (or its EDID changes): make the cable, DisplayManager
# (DeX) and the profile agree, reconnecting at most once.
on_connect() {
    id=$(edid_id)
    [ -n "$id" ] || return
    echo "$id" > "$BASE/last"
    sid=$(wait_sf) || return
    # DisplayManager adds the display a moment after SurfaceFlinger does.
    i=0; dmid=""
    while [ "$i" -lt 10 ]; do
        dmid=$(dm_id "$sid")
        [ -n "$dmid" ] && break
        sleep 1; i=$((i + 1))
    done
    pref=""; [ -n "$dmid" ] && pref=$(dm_pref "$dmid")
    act=$(active_mode); act=${act:+$(to_key "$act")}
    have=" $(offered)"
    want=$(profile_for "$id" "$(variant)")
    case "$have" in *" $want "*) ;; *) [ -n "$want" ] && log "$id: profile $want not offered now"; want="" ;; esac
    if [ -z "$want" ] && [ -n "$pref" ]; then
        # No usable profile: honour DeX's own resolution choice, if the monitor offers it.
        case "$have" in *" $pref "*) want=$pref ;; esac
    fi
    # Lowered because of heat: stay at 60 Hz at that resolution until the watcher says it cooled down.
    if [ -f "$THL" ]; then
        read -r tid tprev _ < "$THL"
        if [ "$tid" = "$id" ]; then
            low="${tprev%:*}:60"
            case "$have" in *" $low "*) want=$low ;; esac
        else
            rm -f "${THL:?}"
        fi
    fi
    # On connect, never start in a mode that failed on this monitor before (it would stay black).
    tgt=${want:-$act}
    if [ -n "$tgt" ] && mode_bad "$tgt" "$id"; then
        nb=$(dsc_best "${tgt%:*}" "$id")
        log "$id: $tgt did not work before; using ${nb:-the default}"
        want=$nb
    fi
    prop=$(getprop $PROP); prop=${prop%:1}
    # Remembered so the next connect (also after a reboot) asks for it before any re-plug.
    [ -n "$want" ] && [ ! -f "$THL" ] && echo "$want" > "$BASE/lastmode.$id"
    if [ -n "$want" ]; then
        [ "$act" = "$want" ] && [ "$pref" = "$want" ] && { [ "$prop" = "$want" ] || setprop $PROP "$want:1"; return; }
        log "$id: cable $act, DeX ${pref:-none}, wanted $want"
        apply_mode "$want" "$sid"
    else
        # Monitor default. Only an override left by another monitor, or a DeX preference the
        # monitor no longer offers, needs undoing.
        [ -z "$prop" ] && { [ -z "$pref" ] || [ "$pref" = "$act" ]; } && return
        log "$id: no usable profile; back to the monitor default (override '$prop', DeX ${pref:-none})"
        apply_mode "" "$sid"
    fi
}

# ---- Phone screen ---------------------------------------------------------------------------

phone_is_on() {
    read -r d1 < /sys/class/drm/card0-DSI-1/dpms 2>/dev/null
    read -r d2 < /sys/class/drm/card0-DSI-2/dpms 2>/dev/null
    [ "$d1" = On ] || [ "$d2" = On ]
}

phone_sleep() { cmd power sleep --display-id 0 >/dev/null 2>&1; }
phone_wake() { cmd power wakeup --display-id 0 >/dev/null 2>&1; }

# The guard: while it runs, the phone's screens stay off unless the side key or the phone command
# woke them on purpose. Two processes: a getevent reader on the side key (blocked in the kernel
# between presses, so no CPU) and a 0.5 s check of the panels' DRM power state (sysfs, no forks
# besides sleep). Started by the watcher only while the switch is on and a monitor is connected.
guard_run() {
    pidf=$BASE/guard.pid
    old=$(cat "$pidf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q display.sh "/proc/$old/cmdline" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$pidf"
    log "phone guard on"
    touch "$BASE/guard.armed"
    phone_is_on && phone_sleep
    # Side key: a press while the phone screen is off is a wish to see it; disarm until it is off again.
    ( getevent -q /dev/input/event4 2>/dev/null | while read -r t c v; do
        [ "$t" = 0001 ] && [ "$c" = 0074 ] && [ "$v" = 00000001 ] || continue
        phone_is_on || { rm -f "$BASE/guard.armed"; log "side key: phone screen allowed on"; }
      done ) &
    keyp=$!
    echo "$keyp" > "$BASE/guard.keypid"
    was_on=0
    while [ -f "$BASE/guard.run" ]; do
        if phone_is_on; then
            if [ -f "$BASE/guard.armed" ]; then
                sleep 0.3   # the side-key reader may still be about to disarm
                if [ -f "$BASE/guard.armed" ]; then
                    phone_sleep
                    log "phone screen woke without the side key; turned off again"
                fi
            fi
            was_on=1
        else
            # Off again (side key, timeout or the off command): guard it from now on.
            [ "$was_on" = 1 ] && touch "$BASE/guard.armed"
            was_on=0
        fi
        sleep 0.5
    done
    pkill -P "$keyp" 2>/dev/null; kill "$keyp" 2>/dev/null
    for p in $(pidof getevent); do grep -q event4 "/proc/$p/cmdline" 2>/dev/null && kill "$p"; done
    rm -f "$BASE/guard.armed" "$pidf" "$BASE/guard.keypid"
    log "phone guard off"
}

guard_start() {
    [ "$(get_set phone_guard)" = 1 ] && connected || return 0
    touch "$BASE/guard.run"
    spawn sh "$0" guard-run
}

# Stop the guard; $1=wake also turns the phone screen back on if the guard was holding it off.
guard_stop() {
    [ -f "$BASE/guard.run" ] || [ -f "$BASE/guard.pid" ] || return 0
    held=0; [ -f "$BASE/guard.armed" ] && ! phone_is_on && held=1
    rm -f "$BASE/guard.run"
    i=0; while [ -f "$BASE/guard.pid" ] && [ "$i" -lt 10 ]; do sleep 0.3; i=$((i + 1)); done
    [ "$1" = wake ] && [ "$held" = 1 ] && phone_wake
}

phone_cmd() {
    case "$1" in
        on) rm -f "$BASE/guard.armed"; phone_wake; echo "ok=1" ;;
        off) phone_sleep; [ -f "$BASE/guard.run" ] && touch "$BASE/guard.armed"; echo "ok=1" ;;
        *) echo "error=use: phone on|off" ;;
    esac
}

guard_cmd() {
    case "$1" in
        on) put_set phone_guard 1; log "switch: keep phone screen off ON"; guard_start; echo "ok=1" ;;
        off) put_set phone_guard 0; log "switch: keep phone screen off OFF"; guard_stop wake; echo "ok=1" ;;
        *) echo "error=use: phone-guard on|off" ;;
    esac
}

# ---- Phone screen refresh rate while a monitor is connected ---------------------------------

# `settings` passes our stdin/stdout/stderr to system_server; a stderr that is a file under
# /data/adb (the watcher's log) is refused there ("Failed transaction"), so every call goes through
# /dev/null and its output is checked: only a number or "null" counts as a value.
sset() { settings "$@" </dev/null 2>/dev/null; }
sval() { v=$(sset get system "$1"); case "$v" in null|[0-9]*) echo "$v" ;; *) echo "?" ;; esac; }

# Per screen, not global: Android's peak/min_refresh_rate settings are global votes that also held
# apps on the monitor at 60 fps, so the phone screen gets a preferred mode on display 0 only
# (DisplayManager), 60 or 120 Hz. The previous preferred mode of display 0 is saved and put back
# on unplug. (DeX itself keeps the phone screen at about 60 Hz while it runs.)
inner_size() { dumpsys display 2>/dev/null | grep -m1 -F 'mBaseDisplayInfo=DisplayInfo{"Built-in Screen"' | sed -n 's/.*real \([0-9]*\) x \([0-9]*\).*/\1 \2/p'; }

inner_apply() {
    hz=$(get_set inner_hz)
    case "$hz" in 120|60) ;; *) inner_restore; return 0 ;; esac
    connected || return 0
    set -- $(inner_size); [ -n "$2" ] || return 0
    cur=$(cmd display get-user-preferred-display-mode 0 </dev/null 2>/dev/null); cur=${cur#*: }
    if [ ! -f "$BASE/refresh.saved" ]; then
        # Never save our own value as the user's.
        case "$cur" in "$1 $2 $hz"*) cur="-1 -1 0.0" ;; esac
        echo "pref $cur" > "$BASE/refresh.saved"
    fi
    case "$cur" in "$1 $2 $hz"*) return 0 ;; esac
    cmd display set-user-preferred-display-mode "$1" "$2" "$hz" 0 </dev/null >/dev/null 2>&1
    log "phone screen -> $hz Hz (display 0 only)"
}

inner_restore() {
    [ -f "$BASE/refresh.saved" ] || return 0
    read -r k w h z _ < "$BASE/refresh.saved"
    if [ "$k" = pref ]; then
        if [ "${w:--1}" -gt 0 ] 2>/dev/null; then
            cmd display set-user-preferred-display-mode "$w" "$h" "${z%.*}" 0 </dev/null >/dev/null 2>&1
        else
            cmd display clear-user-preferred-display-mode 0 </dev/null >/dev/null 2>&1
        fi
        log "phone screen preferred mode restored (${w:-none})"
    else
        # Saved by an older version (global settings): put those back, values only.
        mn=$k; pk=$w
        case "$mn" in null) sset delete system min_refresh_rate ;; [0-9]*) sset put system min_refresh_rate "$mn" ;; esac
        case "$pk" in null) sset delete system peak_refresh_rate ;; [0-9]*) sset put system peak_refresh_rate "$pk" ;; esac
        log "phone screen refresh restored (old global settings: min $mn, peak $pk)"
    fi
    rm -f "$BASE/refresh.saved"
}

inner_verify() { rm -f "$BASE/refresh.check"; }

inner_cmd() {
    case "$1" in
        120|60) put_set inner_hz "$1"; inner_apply; echo "ok=1" ;;
        off) put_set inner_hz ""; inner_restore; echo "ok=1" ;;
        *) echo "error=use: inner-hz 120|60|off" ;;
    esac
}

# ---- Custom EDID (experimental extra refresh rates) ----------------------------------------

debugfs_up() {
    [ -e "$DBG/edid" ] && return 0
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
    [ -e "$DBG/edid" ]
}

# Custom EDID state files: custom.sum = checksum of the custom EDID written this boot (also marks
# that one was written); custom.active = "<id>" in use by the connected monitor.
XD=/sys/class/dp_sec/dex

# Software re-plug: DP output off, optional action in between (while nothing is driven), output on.
# extdisp.off marks the window, so a crash in between is undone at the next watcher start.
hw_replug() {
    hwdex=0; dex_on && hwdex=1
    touch "$BASE/replug.busy" "$BASE/extdisp.off"
    echo "ExtDispOff,1" > $XD 2>/dev/null
    sleep 4
    [ -n "$1" ] && "$@"
    echo "ExtDispOff,0" > $XD 2>/dev/null
    rm -f "$BASE/extdisp.off"
    rm -f "$DMC"
    i=0; ok=1
    while [ "$i" -lt 20 ]; do
        connected && [ -n "$(ext_sf_id)" ] && { ok=0; break; }
        sleep 1; i=$((i + 1))
    done
    sleep 2
    rm -f "$BASE/replug.busy"
    [ "$ok" = 0 ] && dex_recover $hwdex
    return $ok
}

sim_off() { debugfs_up && echo 0 > "$DBG/sim" 2>/dev/null; }

# Clear the custom EDID. With a monitor connected: off, clear, on - the monitor is read again with its
# own EDID. With nothing connected: just clear.
custom_clear() {
    [ -f "$BASE/custom.sum" ] || return 0
    rm -f "$BASE/custom.active"
    if connected; then
        log "clearing the custom EDID (software re-plug)"
        pr=$(getprop $PROP); pr=${pr%:1}
        if [ -n "$pr" ] && [ -f "$BASE/extra.modes" ]; then
            read -r xm < "$BASE/extra.modes"
            # The monitor's own data does not have it: go to the native mode the rates were made from
            # (not "no override": some monitors, like the LG 40U990A, prefer a smaller mode).
            nb=""; read -r nb 2>/dev/null < "$BASE/extra.base"
            case " $xm " in
                *" $pr:"*)
                    setprop $PROP "${nb:+$nb:1}"
                    # DeX's preferred mode too, so the reconnect below is the only one.
                    sid=$(ext_sf_id); dmid=""; [ -n "$sid" ] && dmid=$(dm_id "$sid")
                    if [ -n "$nb" ] && [ -n "$dmid" ]; then
                        IFS=: read -r w hh hz <<EOF
$nb
EOF
                        dm_set "$dmid" "$w" "$hh" "$hz"
                    fi
                    log "override $pr exists only in the custom EDID; now '${nb:-none}'" ;;
            esac
        fi
        hw_replug sim_off
        want=""; read -r want 2>/dev/null < "$BASE/custom.sum"
        if [ -n "$want" ] && [ "$(edid_hex | cksum)" = "$want" ]; then
            # Still ours: keep custom.sum, so the next connect tries again.
            log "custom EDID still in effect after clearing; will retry on the next connect"
            return 1
        fi
        rm -f "$BASE/custom.sum" "$BASE/extra.modes" "$BASE/extra.base" "$BASE/extra.real"
        log "custom EDID cleared; monitor read with its own EDID"
    else
        # Nothing to read now: keep custom.sum, the next connect checks what the monitor sends.
        sim_off
        rm -f "$BASE/extra.modes" "$BASE/extra.base" "$BASE/extra.real"
        log "custom EDID cleared (checked again at the next connect)"
    fi
}

custom_on_disconnect() { custom_clear; }

# On connect: the EDID just read is our custom one only while 4K 75 Hz is active for this monitor.
# Anything else is a leak (another monitor got it): repair it right away. Returns 1 after a repair,
# so the caller re-reads the monitor.
custom_on_connect() {
    [ -f "$BASE/custom.sum" ] || return 0
    want=""; read -r want 2>/dev/null < "$BASE/custom.sum"
    got=$(edid_hex | cksum)
    if [ "$got" = "$want" ]; then
        [ -f "$BASE/custom.active" ] && return 0
        log "custom EDID found on a connect where it does not belong; repairing"
        custom_clear
        return 1
    fi
    # The monitor's own EDID was read: nothing custom in effect.
    rm -f "$BASE/custom.sum" "$BASE/custom.active" "$BASE/extra.modes" "$BASE/extra.base" "$BASE/extra.real"
    return 0
}

# ---- Extra refresh rates ----------------------------------------------------------------------
# The monitor's native timing (largest detailed timing in its EDID, the one closest to 60 Hz; base
# block, CTA and DisplayID timings are all looked at) run with a faster pixel clock:
# same blanking, so only the refresh rate changes. Steps above what the monitor already offers at
# that resolution, up to its own maximum vertical rate (range limits), and only if it fits the live
# link at 6-bit colour with 2 % headroom; the kernel picks the highest bit depth that fits (30, 24
# or 18 bpp). Up to five rates go into an added DisplayID extension block (type I timings), so the
# monitor's own data stays as it is. Tested: LG 40U990A 5120x2160 at 70/75/80 Hz (18 bpp), 2026-11-17.
# Remembered per monitor in $EXTRA/<id> and applied again on every connect.
EXTRA=$BASE/extra
XR=$BASE/xrates        # your own rates per monitor: XR/<id>, one W:H:HZ per line
HZ_STEPS="70 75 80 85 90 100 105 110 115 120 144 165"

# Link payload as the kernel counts it (kHz x bits): link rate x lanes x 8.
link_cap() {
    # dp_debug answers a single read only (the shell's read builtin reads byte by byte): use cat.
    lr=""; ln=""
    while IFS='=' read -r k v; do
        case "$k" in *link_rate) lr=$v ;; *num_lanes) ln=$v ;; esac
    done <<EOF
$(cat "$DBG/dp_debug" 2>/dev/null)
EOF
    [ -n "$lr" ] && [ -n "$ln" ] && [ "$ln" -gt 0 ] && echo $((lr * ln * 8))
}

by() { eval "$1=\$((0x\${h:$(($2 * 2)):2}))"; }
le16() { printf '%02x%02x' $(($1 & 255)) $((($1 >> 8) & 255)); }
# Detailed timing (18 bytes, EDID/CTA) at byte $1 -> ha hb hfp hsw va vb vfp vsw hp vp pk (kHz).
dtd_at() {
    by a $1; by b $(($1 + 1)); pk=$(((a | b << 8) * 10)); [ "$pk" -gt 0 ] || return 1
    by a $(($1 + 2)); by b $(($1 + 3)); by c $(($1 + 4)); ha=$((a | (c >> 4) << 8)); hb=$((b | (c & 15) << 8))
    by a $(($1 + 5)); by b $(($1 + 6)); by c $(($1 + 7)); va=$((a | (c >> 4) << 8)); vb=$((b | (c & 15) << 8))
    by a $(($1 + 8)); by b $(($1 + 9)); by c $(($1 + 10)); by d $(($1 + 11))
    hfp=$((a | ((d >> 6) & 3) << 8)); hsw=$((b | ((d >> 4) & 3) << 8))
    vfp=$(((c >> 4) | ((d >> 2) & 3) << 4)); vsw=$(((c & 15) | (d & 3) << 4))
    by fl $(($1 + 17)); hp=0; vp=0
    [ $((fl & 0x18)) -eq 24 ] && { [ $((fl & 2)) -ne 0 ] && hp=32768; [ $((fl & 4)) -ne 0 ] && vp=32768; }
    return 0
}

w16() { by lo $2; by hi $(($2 + 1)); eval "$1=\$(($lo | $hi << 8))"; }

# DisplayID type I timing (20 bytes) at byte $1 -> same variables.
did_at() {
    by a $1; by b $(($1 + 1)); by c $(($1 + 2)); pk=$((((a | b << 8 | c << 16) + 1) * 10))
    w16 ha $(($1 + 4)); w16 hb $(($1 + 6)); w16 hfp $(($1 + 8)); w16 hsw $(($1 + 10))
    w16 va $(($1 + 12)); w16 vb $(($1 + 14)); w16 vfp $(($1 + 16)); w16 vsw $(($1 + 18))
    hp=$((hfp & 32768)); vp=$((vfp & 32768))
    ha=$((ha + 1)); hb=$((hb + 1)); hfp=$(((hfp & 32767) + 1)); hsw=$((hsw + 1))
    va=$((va + 1)); vb=$((vb + 1)); vfp=$(((vfp & 32767) + 1)); vsw=$((vsw + 1))
}

# Keep the timing just parsed if it beats the best so far: larger area, then closer to 60 Hz.
consider() {
    [ "$hfp" -gt 0 ] && [ "$hsw" -gt 0 ] && [ "$vsw" -gt 0 ] && [ "$ha" -gt 0 ] && [ "$va" -gt 0 ] || return
    fr=$(((ha + hb) * (va + vb)))
    hz10=$((pk * 10 / (fr / 1000)))
    [ "$hz10" -ge 500 ] || return
    seen="$seen $ha:$va:$(((hz10 + 5) / 10))"
    alltim="$alltim $ha,$hb,$hfp,$hsw,$va,$vb,$vfp,$vsw,$hp,$vp,$hz10"
    ar=$((ha * va)); sc=$((hz10 > 600 ? hz10 - 600 : 600 - hz10))
    if [ "$ar" -gt "$best_ar" ] || { [ "$ar" -eq "$best_ar" ] && [ "$sc" -lt "$best_sc" ]; }; then
        best_ar=$ar; best_sc=$sc; best="$ha $hb $hfp $hsw $va $vb $vfp $vsw $hp $vp"; best_hz=$(((hz10 + 5) / 10))
    fi
}

cks() { s=0; i=0; while [ "$i" -lt "${#1}" ]; do s=$((s + 0x${1:$i:2})); i=$((i + 2)); done; printf '%02x' $(((256 - s % 256) % 256)); }

# One DisplayID 1.2 extension block (128 bytes, hex) with $2 type I timings given as hex in $1.
did_block() {
    nb=$(($2 * 20))
    sec="12$(printf '%02x' $((nb + 3)))0300"0300$(printf '%02x' $nb)$1
    blk="70$sec$(cks "$sec")"
    while [ "${#blk}" -lt 254 ]; do blk="${blk}00"; done
    echo "$blk$(cks "$blk")"
}

# Writes $BASE/extra.hex (the new EDID) and $BASE/extra.modes ("W:H:HZ:BPP ..."); 1 if nothing fits.
# mksh arithmetic is 32-bit, hence the divisions before multiplying.
make_extra() {
    # While a custom EDID of ours is in effect the connector shows that one: use the saved original.
    h=""; [ -f "$BASE/custom.active" ] && read -r h 2>/dev/null < "$BASE/extra.real"
    [ -n "$h" ] || h=$(edid_hex)
    [ "${#h}" -ge 256 ] || return 1
    by n 126
    [ "$n" -le 5 ] && [ "${#h}" -eq $(((n + 1) * 256)) ] || return 1
    best=""; best_ar=0; best_sc=99999; seen=""; alltim=""
    for o in 54 72 90 108; do dtd_at $o && consider; done
    e=1
    while [ "$e" -le "$n" ]; do
        eb=$((e * 128)); by tag $eb
        if [ "$tag" = 2 ]; then
            by d $((eb + 2)); o=$((eb + d))
            [ "$d" -ge 4 ] && while [ $((o + 18)) -le $((eb + 127)) ]; do dtd_at $o && consider; o=$((o + 18)); done
        elif [ "$tag" = 112 ]; then
            by sl $((eb + 2)); i=$((eb + 5)); end=$((eb + 5 + sl))
            [ "$end" -le $((eb + 127)) ] || end=$((eb + 127))
            while [ $((i + 3)) -le "$end" ]; do
                by bt $i; by bl $((i + 2))
                if [ "$bt" = 3 ]; then
                    t=$((i + 3)); while [ $((t + 20)) -le $((i + 3 + bl)) ]; do did_at $t; consider; t=$((t + 20)); done
                fi
                i=$((i + 3 + bl))
            done
        fi
        e=$((e + 1))
    done
    [ -n "$best" ] || return 1
    set -- $best
    ha=$1; hb=$2; hfp=$3; hsw=$4; va=$5; vb=$6; vfp=$7; vsw=$8; hp=$9; vp=${10}
    frame=$(((ha + hb) * (va + vb)))
    nat="$ha,$hb,$hfp,$hsw,$va,$vb,$vfp,$vsw,$hp,$vp"
    # Deepest colour the monitor takes (EDID 1.4 byte 20), and its maximum vertical rate.
    by e 20; maxb=24
    case $(((e >> 4) & 7)) in 1) maxb=18 ;; 2) maxb=24 ;; 3|4|5|6) maxb=30 ;; esac
    vmax=0
    for o in 72 90 108; do
        case "${h:$((o * 2)):8}" in
            000000fd) by f $((o + 4)); by v $((o + 6)); [ $((f & 2)) -ne 0 ] && v=$((v + 255)); vmax=$v ;;
        esac
    done
    [ "$vmax" -gt 0 ] || vmax=120
    cap=$(link_cap); [ -n "$cap" ] || cap=17280000
    # With DSC (on for this monitor and supported): compressed to 8 bits per pixel on the link, but
    # the monitor's decoder takes at most <peak> Mpixel/s per slice; Qualcomm uses 4 slices above
    # 2560 pixels wide here (LG 40U990A: 340 per slice; 355 = black screen, 323 = fine). 96 % margin
    # for the automatic rates; your own rates are added as asked (the 30 s confirmation protects).
    dpk=$(dsc_peak "${h:16:16}")
    tagof() {   # $1 = kHz -> dsc or bits per pixel the kernel will use
        if [ -n "$dpk" ]; then echo dsc; return; fi
        bp=18; for t in 24 30; do [ "$t" -le "$maxb" ] && [ $(($1 * t)) -le "$cap" ] && bp=$t; done; echo $bp
    }
    # Your own rates (extra-add W:H:HZ), from that resolution's timing closest to 60 Hz.
    own=""; xf="$XR/${h:16:16}"; [ -f "$xf" ] || xf=/dev/null
    while read -r want; do
        [ -n "$want" ] || continue
        ww=${want%%:*}; r=${want#*:}; wh=${r%%:*}; wz=${r#*:}
        case "$seen " in *" $ww:$wh:$wz "*) continue ;; esac
        bt=""; bs=99999
        for tt in $alltim; do
            IFS=, read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 <<EOF
$tt
EOF
            [ "$a1" = "$ww" ] && [ "$a5" = "$wh" ] || continue
            sc=$((a11 > 600 ? a11 - 600 : 600 - a11))
            [ "$sc" -lt "$bs" ] && { bs=$sc; bt="$a1,$a2,$a3,$a4,$a5,$a6,$a7,$a8,$a9,$a10"; }
        done
        [ -n "$bt" ] || { log "own rate $want: no timing for ${ww}x$wh in this monitor's EDID"; continue; }
        IFS=, read -r a1 a2 _ _ a5 a6 _ <<EOF
$bt
EOF
        khz=$(((a1 + a2) * (a5 + a6) / 100 * wz / 10))
        own="$own $ww:$wh:$wz:$(tagof $khz):$bt"
    done < "$xf"
    auto=""
    for hz in $HZ_STEPS; do
        [ "$hz" -le "$vmax" ] || continue
        case "$seen " in *" $ha:$va:$hz "*) continue ;; esac
        case "$own " in *" $ha:$va:$hz:"*) continue ;; esac
        khz=$((frame / 100 * hz / 10))
        if [ -n "$dpk" ]; then
            sl=2; [ "$ha" -gt 2560 ] && sl=4
            [ $((khz / sl)) -le $((dpk * 960)) ] && [ $((khz * 8)) -le $((cap / 100 * 98)) ] || continue
        else
            [ $((khz * 18)) -le $((cap / 100 * 98)) ] || continue
        fi
        auto="$auto $ha:$va:$hz:$(tagof $khz):$nat"
    done
    # The kernel reads at most 4 EDID blocks (512 bytes): base + 3 extensions, so the room left for
    # our DisplayID blocks (five timings each) depends on how many the monitor already has. Your own
    # rates first; the automatic ones fill the rest, as an even spread that keeps the fastest.
    room=$(((3 - n) * 5)); [ "$room" -gt 0 ] || return 1
    set -- $own
    while [ "$#" -gt "$room" ]; do shift; done
    sel="$*"; left=$((room - $#))
    set -- $auto
    if [ "$#" -gt "$left" ]; then
        cnt=$#; pick=""; k=0
        while [ "$k" -lt "$left" ]; do
            idx=$cnt; [ "$left" -gt 1 ] && idx=$(((k * (cnt - 1) + (left - 1) / 2) / (left - 1) + 1))
            eval "pick=\"\$pick \${$idx}\""
            k=$((k + 1))
        done
        set -- $pick
    fi
    sel="$sel $*"
    set -- $sel
    [ "$#" -gt 0 ] || return 1
    tim=""; modes=""; blocks=""; nt=0
    for m in "$@"; do
        IFS=: read -r mw mh hz tg tf <<EOF
$m
EOF
        IFS=, read -r ha hb hfp hsw va vb vfp vsw hp vp <<EOF
$tf
EOF
        asp=00
        [ $((ha * 9)) -eq $((va * 16)) ] && asp=04
        [ $((ha * 10)) -eq $((va * 16)) ] && asp=05
        [ $((ha * 27)) -eq $((va * 64)) ] && asp=06
        p=$(((ha + hb) * (va + vb) / 100 * hz / 100 - 1))
        tim="$tim$(printf '%02x%02x%02x' $((p & 255)) $(((p >> 8) & 255)) $(((p >> 16) & 255)))$asp"
        tim="$tim$(le16 $((ha - 1)))$(le16 $((hb - 1)))$(le16 $(((hfp - 1) | hp)))$(le16 $((hsw - 1)))"
        tim="$tim$(le16 $((va - 1)))$(le16 $((vb - 1)))$(le16 $(((vfp - 1) | vp)))$(le16 $((vsw - 1)))"
        modes="$modes $mw:$mh:$hz:$tg"
        nt=$((nt + 1))
        # A DisplayID extension block holds five type I timings: start a new block after five.
        if [ "$nt" = 5 ]; then blocks="$blocks $(did_block "$tim" 5)"; tim=""; nt=0; fi
    done
    [ "$nt" -gt 0 ] && blocks="$blocks $(did_block "$tim" $nt)"
    nx=0; ext=""; for b in $blocks; do ext="$ext$b"; nx=$((nx + 1)); done
    b0="${h:0:252}$(printf '%02x' $((n + nx)))"
    b0="$b0$(cks "$b0")"
    echo "$b0${h:256}$ext" > "$BASE/extra.hex"
    echo "${modes# }" > "$BASE/extra.modes"
    IFS=, read -r ha hb _ _ va vb _ <<EOF
$nat
EOF
    echo "$ha:$va:$best_hz" > "$BASE/extra.base"
    echo "$h" > "$BASE/extra.real"
}

# Build, write and apply for monitor $1. 0 = at least one extra rate offered now; 1 = none fits;
# 2 = no debugfs; 3 = the kernel took none of them (cleared again).
extra_apply() {
    # Our custom EDID is in effect but the monitor's own copy is gone: start from the monitor again.
    if [ -f "$BASE/custom.active" ] && [ ! -f "$BASE/extra.real" ]; then
        log "$1: original EDID copy missing; reading the monitor again first"
        custom_clear
    fi
    make_extra || return 1
    debugfs_up || return 2
    read -r x < "$BASE/extra.hex"
    printf '%s' "$x" > "$DBG/edid" || return 2
    printf '%s' "$x" | cksum > "$BASE/custom.sum"
    echo "$1" > "$BASE/custom.active"
    read -r xm < "$BASE/extra.modes"
    log "extra refresh rates for $1 ($xm); software re-plug"
    hw_replug
    # Android may still be adding the display (right after boot it took longer than the re-plug
    # wait): give it up to 20 s before concluding the rates were not taken.
    i=0; got=""
    while [ "$i" -lt 10 ]; do
        have=" $(offered)"
        for m in $xm; do case "$have" in *" ${m%:*} "*) got="$got ${m%:*}" ;; esac; done
        [ -n "$got" ] && break
        sleep 2; i=$((i + 1))
    done
    [ -n "$got" ] && { log "offered now:$got"; return 0; }
    log "none of the extra rates was accepted; back to the monitor's own EDID"
    custom_clear
    return 3
}

# Watcher, on connect: re-apply for a monitor that has extra rates switched on.
extra_auto() {
    id=$(edid_id)
    # With DSC on for this monitor, extra rates come along unless switched off for it.
    [ -n "$id" ] && dsc_wanted "$id" && [ ! -f "$EXTRA/$id.off" ] && [ ! -f "$EXTRA/$id" ] && { mkdir -p "$EXTRA"; touch "$EXTRA/$id"; }
    [ -n "$id" ] && [ -f "$EXTRA/$id" ] && [ ! -f "$BASE/custom.active" ] || return 0
    log "$id: extra refresh rates are on for this monitor; applying"
    extra_apply "$id"
}

# Your own refresh rate for a resolution of this monitor: add/remove, then apply (one re-plug).
xrate_cmd() {
    settle
    connected || { echo "error=No external display connected"; return 1; }
    id=$(edid_id); xk=$2
    echo "$xk" | grep -qE '^[0-9]{3,5}:[0-9]{3,5}:[0-9]{2,3}$' || { echo "error=Use W:H:HZ, for example 3840:2160:100"; return 1; }
    z=${xk##*:}; [ "$z" -ge 20 ] && [ "$z" -le 240 ] || { echo "error=Refresh rate between 20 and 240 Hz"; return 1; }
    mkdir -p "$XR" "$EXTRA"
    case "$1" in
        add) grep -qx "$xk" "$XR/$id" 2>/dev/null || echo "$xk" >> "$XR/$id"; log "$id: own rate $xk added"
             rm -f "${EXTRA:?}/${id:?}.off"; touch "$EXTRA/$id" ;;
        del) [ -f "$XR/$id" ] && { grep -vx "$xk" "$XR/$id" > "$XR/$id.tmp"; mv -f "$XR/$id.tmp" "$XR/$id"; }; log "$id: own rate $xk removed" ;;
    esac
    extra_apply "$id"
    case $? in
        0) case " $(offered)" in *" $xk "*) echo "ok=1" ;; *) [ "$1" = add ] && echo "error=Added, but the phone did not accept $xk (link or decoder)" || echo "ok=1" ;; esac ;;
        1) [ "$1" = del ] && { custom_clear; echo "ok=1"; } || echo "error=No room or no timing for that resolution" ;;
        *) echo "error=The phone did not accept the new rates" ;;
    esac
}

extra_cmd() {
    settle
    connected || { echo "error=No external display connected"; return 1; }
    id=$(edid_id)
    case "$1" in
        on)
            mkdir -p "$EXTRA"
            extra_apply "$id"
            case $? in
                0) touch "$EXTRA/$id"; rm -f "${EXTRA:?}/${id:?}.off"; echo "ok=1" ;;
                1) echo "error=No higher refresh rate fits this monitor and the link (or its EDID has no usable timing)" ;;
                2) echo "error=Qualcomm DisplayPort debugfs not available" ;;
                *) echo "error=The phone did not accept the extra rates for this monitor" ;;
            esac ;;
        off)
            rm -f "$EXTRA/$id"; touch "$EXTRA/$id.off"
            custom_clear
            echo "ok=1" ;;
        *) echo "error=use: extra on|off" ;;
    esac
}

# ---- Experimental: Display Stream Compression (DSC) ---------------------------------------------
# Qualcomm's driver has DSC and FEC switched off on this phone; debugfs dsc_feature_enable and
# fec_feature_enable switch them on, and the next connect reads the monitor's DSC capabilities
# (only monitors that report DSC use it; then every mode is sent compressed, 8 bits per pixel on the
# link). The switches are global and reset on boot, so on every connect they are set to what that
# monitor wants. Per monitor, $DSCD/<id> holds the decision:
#   peak=<N>  on; the monitor's decoder takes N Mpixel/s per slice (kernel log; 340 if not printed)
#   off       turned off (by the user, or a check that was not confirmed)
#   none      the monitor reports no DSC
#   (no file) not checked yet: checked at connect when "dsc_auto" is on in the settings.
# What the phone does not check is that decoder limit: with up to 4 slices (two DSC encoders, two
# slices each), a mode whose pixel clock / 4 exceeds it stays black (LG 40U990A at 120 Hz: 355 > 340).
# Such modes are refused, and avoided on connect.
DSCD=$BASE/dsc

dsc_flag() { debugfs_up || return 1; read -r f < "$DBG/dsc_feature_enable"; [ "$f" = Y ]; }
dsc_set() { debugfs_up || return 1; echo "$1" > "$DBG/fec_feature_enable"; echo "$1" > "$DBG/dsc_feature_enable"; }
dsc_state() { v=""; read -r v 2>/dev/null < "$DSCD/$1"; echo "$v"; }
dsc_wanted() { case "$(dsc_state "$1")" in peak=*) return 0 ;; esac; return 1; }

# Decoder limit for monitor $1 if DSC is on for it and the switches are on; empty otherwise.
dsc_peak() {
    dsc_wanted "$1" && dsc_flag || return 0
    pk=$(dsc_state "$1"); pk=${pk#peak=}
    [ "${pk:-0}" -gt 0 ] 2>/dev/null && echo "$pk"
}

# After a connect with the switches on: does the monitor take DSC, and its per-slice limit.
dsc_learn() {
    # Separate greps: the peak line is printed dozens of times per connect.
    l=$(dmesg 2>/dev/null | grep "secdp_show_sink_caps: DSC version" | tail -n 1)
    case "$l" in *"support:1"*) ;; *) return 1 ;; esac
    pk=$(dmesg 2>/dev/null | sed -n 's/.*peak_throughput=\([0-9]*\).*/\1/p' | tail -n 1)
    echo "peak=${pk:-340}" > "$DSCD/$1"
    log "$1: DSC supported, decoder limit ${pk:-340} Mpixel/s per slice"
}

# Remember what the kernel did at the last mode set (compression on or off) for the status page.
dsc_note() {
    c=$(dmesg 2>/dev/null | grep "dp_catalog_panel_dsc_cfg: compression:" | tail -n 1)
    case "$c" in "") ;; *"compression:0x0 "*) echo 0 > "$BASE/dsc.state" ;; *) echo 1 > "$BASE/dsc.state" ;; esac
}

# Pixel clock (kHz) of mode W:H:HZ from the kernel's mode list.
clk_of() {
    w=${1%%:*}; r=${1#*:}; hh=${r%%:*}; z=${r#*:}
    cat "$DBG/edid_modes" 2>/dev/null | while read -r res fz _ _ _ ck _; do
        [ "$res" = "${w}x$hh" ] && [ "$fz" = "$z" ] && { echo "$ck"; break; }
    done
}

# Mode $1 was reverted before on monitor $2 (black or flickering).
mode_bad() { grep -qx "$1" "$BASE/bad/$2" 2>/dev/null; }

# Mode $1 fits the DSC decoder of monitor $2 (always true without DSC).
dsc_fits() {
    mode_bad "$1" "$2" && return 1
    pk=$(dsc_peak "$2"); [ -n "$pk" ] || return 0
    ck=$(clk_of "$1"); [ -n "$ck" ] || return 0
    [ $((ck / 4)) -le $((pk * 1000)) ]
}

# Fastest offered mode at resolution $1 (W:H) that fits the decoder of monitor $2.
dsc_best() {
    bz=0
    for k in $(offered); do
        case "$k" in "$1:"*) z=${k##*:}; [ "$z" -gt "$bz" ] && dsc_fits "$k" "$2" && bz=$z ;; esac
    done
    [ "$bz" -gt 0 ] && echo "$1:$bz"
}

# Colour depth per mode for the page: "W:H:HZ:bits per pixel:dsc|plain:too fast 0|1", the way the
# kernel picks it (deepest the monitor takes, max_bpp 30, stepping down by 6 to 18 until it fits the
# link; with DSC the deepest, compressed). Written after every connect.
mode_info() {
    debugfs_up && connected || return
    id=$(edid_id)
    e=$(od -An -tx1 -j20 -N1 $CONN/edid 2>/dev/null | tr -d ' \n')
    maxb=24
    case $(((0x${e:-80} >> 4) & 7)) in 1) maxb=18 ;; 2) maxb=24 ;; 3|4|5|6) maxb=30 ;; esac
    mb=30; read -r mb 2>/dev/null < "$DBG/max_bpp"; [ "${mb:-30}" -lt "$maxb" ] && maxb=$mb
    cap=$(link_cap); [ -n "$cap" ] || cap=17280000
    pk=$(dsc_peak "$id")
    cat "$DBG/edid_modes" 2>/dev/null | while read -r res fz _ _ _ ck _; do
        [ -n "$ck" ] || continue
        key="${res%x*}:${res#*x}:$fz"
        if mode_bad "$key" "$id"; then
            dm=plain; [ -n "$pk" ] && dm=dsc
            echo "$key:$maxb:$dm:1"
        elif [ -n "$pk" ]; then
            ov=0; [ $((ck / 4)) -gt $((pk * 1000)) ] && ov=1
            echo "$key:$maxb:dsc:$ov"
        else
            bb=$maxb
            while [ "$bb" -ge 18 ] && [ $((ck * bb)) -gt "$cap" ]; do bb=$((bb - 6)); done
            [ "$bb" -ge 18 ] && echo "$key:$bb:plain:0"
        fi
    done > "$BASE/modeinfo"
}

# Arm the confirmation for DSC on monitor $1: without "confirm" within 45 s it goes off again.
dsc_arm() {
    echo "$1 DSC $(($(up_s) + 45))" > "$CONF"
    spawn sh "$0" revert-timer
}

# Switch DSC off for monitor $1 (decision $2: off or none) and reconnect without it.
dsc_disable() {
    mkdir -p "$DSCD"; echo "$2" > "$DSCD/$1"; dsc_set 0
    if [ -f "$EXTRA/$1" ]; then extra_apply "$1"; else hw_replug; fi
}

# Watcher, on connect: checks a new monitor (with dsc_auto on), then sets the switches to what this
# monitor wants. 0 = the switches changed and a re-plug is still needed.
dsc_auto() {
    id=$(edid_id); [ -n "$id" ] || return 1
    debugfs_up || return 1
    if [ -z "$(dsc_state "$id")" ] && [ "$(get_set dsc_auto)" = 1 ]; then
        mkdir -p "$DSCD"
        log "$id: not checked for DSC yet; checking"
        dsc_set 1; hw_replug
        if dsc_learn "$id"; then
            [ -f "$EXTRA/$id.off" ] || { mkdir -p "$EXTRA"; touch "$EXTRA/$id"; }
            dsc_arm "$id"
        else
            log "$id: no DSC"
            echo none > "$DSCD/$id"; dsc_set 0; hw_replug
        fi
        return 1
    fi
    want=N; dsc_wanted "$id" && want=Y
    read -r f < "$DBG/dsc_feature_enable"
    [ "$f" = "$want" ] && return 1
    if [ "$want" = Y ]; then dsc_set 1; else dsc_set 0; fi
    log "$id: DSC switches -> $want"
    return 0
}

dsc_cmd() {
    case "$1" in
        auto-on) put_set dsc_auto 1; log "switch: check new monitors for DSC ON"; echo "ok=1"; return ;;
        auto-off) put_set dsc_auto 0; log "switch: check new monitors for DSC OFF"; echo "ok=1"; return ;;
    esac
    settle
    connected || { echo "error=No external display connected"; return 1; }
    debugfs_up || { echo "error=Qualcomm DisplayPort debugfs not available"; return 1; }
    id=$(edid_id); [ -n "$id" ] || { echo "error=Cannot identify the monitor"; return 1; }
    mkdir -p "$DSCD"
    case "$1" in
        on)
            dsc_set 1; echo "peak=340" > "$DSCD/$id"
            log "$id: DSC on; software re-plug"
            hw_replug
            if ! dsc_learn "$id"; then
                dsc_disable "$id" none >/dev/null
                echo "error=This monitor does not report DSC support"; return 1
            fi
            # Extra rates come with DSC (unless switched off for this monitor), worked out with the
            # compression limits.
            [ -f "$EXTRA/$id.off" ] || { mkdir -p "$EXTRA"; touch "$EXTRA/$id"; }
            [ -f "$EXTRA/$id" ] && extra_apply "$id"
            dsc_arm "$id"
            echo "confirm=45"; echo "ok=1" ;;
        off)
            log "$id: DSC off"
            [ -f "$CONF" ] && { read -r cf cp _ < "$CONF"; [ "$cp" = DSC ] && rm -f "${CONF:?}"; }
            dsc_disable "$id" off
            echo "ok=1" ;;
        *) echo "error=use: dsc on|off|auto-on|auto-off" ;;
    esac
}

# ---- Confirm or go back ----------------------------------------------------------------------
# An experimental mode (custom EDID or DSC in use) can leave the monitor black while the phone
# thinks all is well. Such a change must be confirmed in time, or it is undone by itself.
# confirm.pending: "<profile file> <previous W:H:HZ> <deadline uptime>", or "<id> DSC <deadline>"
# after DSC was switched on for a monitor.
CONF=$BASE/confirm.pending
CONF_S=30

experimental() { [ -f "$BASE/custom.active" ] || dsc_wanted "$1"; }

up_s() { read -r u _ < /proc/uptime; echo "${u%.*}"; }

revert_now() {
    [ -f "$CONF" ] || return 1
    read -r f prev _ < "$CONF"; rm -f "${CONF:?}"
    if [ "$prev" = DSC ]; then
        log "$f: DSC not confirmed; off again"
        settle
        dsc_disable "$f" off
        return 0
    fi
    log "not confirmed: back to $prev"
    # The mode that was not kept probably left the monitor black or flickering: remember it for this
    # monitor so it is crossed out and not chosen again (bad/<id>, one W:H:HZ per line).
    fl=""; read -r fl 2>/dev/null < "$PROF/$f"; fl=${fl%:1}
    if [ -n "$fl" ] && [ "$fl" != "$prev" ]; then
        mkdir -p "$BASE/bad"; grep -qx "$fl" "$BASE/bad/${f%%-*}" 2>/dev/null || echo "$fl" >> "$BASE/bad/${f%%-*}"
        log "${f%%-*}: $fl remembered as not working"
    fi
    echo "$prev:1" > "$PROF/$f"
    settle
    apply_mode "$prev" "$(ext_sf_id)"
    pace
}

revert_timer() {
    while [ -f "$CONF" ]; do
        read -r _ _ dl < "$CONF"
        [ "$(up_s)" -ge "${dl:-0}" ] && { lock; revert_now; unlock; return; }
        sleep 1
    done
}

confirm_cmd() {
    case "$1" in
        back) if revert_now; then echo "ok=1"; else echo "error=Nothing to undo"; fi ;;
        *) if [ -f "$CONF" ]; then
               rm -f "${CONF:?}"; log "confirmed"
               # Kept: it works on this monitor after all.
               act=$(active_mode); act=${act:+$(to_key "$act")}; ci=$(edid_id)
               if [ -n "$act" ] && mode_bad "$act" "$ci"; then
                   grep -vx "$act" "$BASE/bad/$ci" > "$BASE/bad/$ci.tmp"; mv -f "$BASE/bad/$ci.tmp" "$BASE/bad/$ci"
                   log "$ci: $act works after all; no longer marked"
               fi
           fi
           echo "ok=1" ;;
    esac
}

# ---- Heat: optional automatic 60 Hz while the phone is hot -------------------------------------
# Samsung's thermal service caps the GPU (kgsl thermal_pwrlevel; level 8 = 646 of 1300 MHz) and the
# CPU when its skin estimate gets high; at 5120x2160 apps then fall to ~50 fps on a 110 Hz monitor.
# With "thermal_fallback" on, the watcher (every 30 s) lowers the monitor to 60 Hz at the same
# resolution when the GPU is held back hard (level >= 6, 826 MHz) or the thermal status is critical
# (>= 4) twice in a row, and goes back to the saved mode after 3 cool checks (level <= 2, status
# <= 2) and at least 3 minutes. The saved profile is not touched. $THL = "<id> <mode before> <since>".
THL=$BASE/thermal.lowered
hot_n=0; cool_n=0

thermal_guard() {
    id=$(edid_id); [ -n "$id" ] || return
    if [ "$(get_set thermal_fallback)" != 1 ]; then
        [ -f "$THL" ] && thermal_back "switched off"
        return
    fi
    pl=0; read -r pl 2>/dev/null < /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel
    st=$(dumpsys thermalservice 2>/dev/null | sed -n 's/^Thermal Status: \([0-9]*\).*/\1/p' | head -n 1)
    st=${st:-0}
    if [ ! -f "$THL" ]; then
        dk=""; [ -f "$BASE/desk.state" ] && read -r dk _ < "$BASE/desk.state"
        # With the temperature override at full speed the GPU is not held back, so the status alone does not count.
        if [ "$pl" -ge 6 ] || { [ "$st" -ge 4 ] && [ "$dk" != on ]; }; then hot_n=$((hot_n + 1)); else hot_n=0; fi
        [ "$hot_n" -ge 2 ] || return
        act=$(active_mode); act=${act:+$(to_key "$act")}
        [ -n "$act" ] && [ "${act##*:}" -gt 60 ] || return
        low="${act%:*}:60"
        case " $(offered)" in *" $low "*) ;; *) return ;; esac
        echo "$id $act $(up_s)" > "$THL"; hot_n=0; cool_n=0
        log "$id: phone hot (GPU level $pl, thermal status $st); $act -> $low until it cools down"
        lock; apply_mode "$low" "$(ext_sf_id)"; unlock; pace
    else
        dk=""; [ -f "$BASE/desk.state" ] && read -r dk _ < "$BASE/desk.state"
        # With the temperature override at full speed the status stays high on purpose: then only
        # whether the GPU is held back counts.
        if [ "$pl" -le 2 ] && { [ "$st" -le 2 ] || [ "$dk" = on ]; }; then cool_n=$((cool_n + 1)); else cool_n=0; fi
        read -r _ _ t0 < "$THL"
        [ "$cool_n" -ge 3 ] && [ $(($(up_s) - ${t0:-0})) -ge 180 ] && thermal_back "cooled down (GPU level $pl, thermal status $st)"
    fi
}

thermal_back() {
    read -r tid prev _ < "$THL"; rm -f "${THL:?}"; cool_n=0; hot_n=0
    connected && [ "$tid" = "$(edid_id)" ] || return
    log "$tid: $1; back to $prev"
    lock; apply_mode "$prev" "$(ext_sf_id)"; unlock; pace
}

thermal_cmd() {
    case "$1" in
        on) put_set thermal_fallback 1; log "switch: 60 Hz while hot ON"; echo "ok=1" ;;
        off) put_set thermal_fallback 0; log "switch: 60 Hz while hot OFF"; echo "ok=1" ;;
        *) echo "error=use: thermal-fallback on|off" ;;
    esac
}

# ---- Experimental temperature override: run hotter while the phone sits untouched next to a monitor
# Samsung's thermal service limits the GPU (kgsl thermal_pwrlevel) and the CPU (cpufreq
# scaling_max_freq, adjusted every 2-4 s) from an estimated skin temperature (~43-45 C), which is
# meant for a phone in the hand. With the temperature override on and a monitor connected, a small loop puts those
# limits back to full speed once a second, and remembers what Samsung asked for. Limits that protect
# parts take over again: Samsung's own values come back at once when the battery reaches 41 C, the
# board near the chip 80 C, the skin estimate 56 C, or any sensor is at "emergency"; the override
# resumes below 38 / 72 / 52 C. The kernel's own chip protection (thermal zones, cooling devices) is
# separate and never touched. Costs a few sysfs reads per second and one thermal reading per 5 s,
# only while it runs.
DESK_BAT=41; DESK_AP=80; DESK_SKIN=56
DESK_BAT_OK=38; DESK_AP_OK=72; DESK_SKIN_OK=52

desk_temps() {   # -> d_st d_bat d_ap d_skin (whole degrees)
    d_st=0; d_bat=0; d_ap=0; d_skin=0
    while IFS='=' read -r k v; do
        v=${v%%.*}
        case "$k" in
            st) d_st=$v ;;
            BAT) [ "$v" -gt "$d_bat" ] && d_bat=$v ;;
            AP) [ "$v" -gt "$d_ap" ] && d_ap=$v ;;
            SKIN) [ "$v" -gt "$d_skin" ] && d_skin=$v ;;
        esac
    done <<EOF
$(dumpsys thermalservice 2>/dev/null | sed -n -e 's/^Thermal Status: \([0-9]*\).*/st=\1/p' \
    -e '/Current temperatures from HAL/,/Current cooling/s/.*mValue=\([0-9.]*\), mType=[0-9]*, mName=\([A-Z]*\), mStatus=.*/\2=\1/p')
EOF
}

# Under load Samsung rewrites the CPU limits about every second, faster than a 1 s loop can undo.
# While the override is active the files go to root:root 644, so Samsung's thermal software
# (running as system) cannot change them; the original owner and mode come back with its values.
# Samsung's own CPU limit driver (cpufreq_limit): cpufreq_max_limit holds a "virtual" frequency
# that its table maps to a maximum per core group (1267200 held the fast cores at 2.88 GHz); -1
# releases it. Owned radio:system 664, written by Samsung's framework.
CFL=/sys/devices/system/cpu/cpufreq_limit/cpufreq_max_limit
# Samsung's GPU limit (MHz), separate from Qualcomm's kgsl level: it held the GPU at 422 MHz under
# load with the kgsl limit already released, and at 160 MHz without the override. system:system 644.
GMX=/sys/kernel/gpu/gpu_max_clock

desk_cpu_block() {
    if [ -f $GMX ]; then
        o_gmx=$(stat -c '%U:%G %a' $GMX 2>/dev/null)
        read -r gtop _ < /sys/kernel/gpu/gpu_freq_table
        read -r v < $GMX; [ "$v" != "$gtop" ] && w_gmx=$v
        chown root:root $GMX 2>/dev/null; chmod 644 $GMX 2>/dev/null; echo "$gtop" > $GMX
    fi
    if [ -f $CFL ]; then
        o_cfl=$(stat -c '%U:%G %a' $CFL 2>/dev/null)
        read -r v < $CFL; [ "$v" != -1 ] && w_cfl=$v
        echo -1 > $CFL; chown root:root $CFL 2>/dev/null; chmod 644 $CFL 2>/dev/null
    fi
    for i in $POLS; do
        F=/sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq
        eval "o_$i=\"$(stat -c '%U:%G %a' $F 2>/dev/null)\""
        chown root:root $F 2>/dev/null; chmod 644 $F 2>/dev/null
    done
}
desk_cpu_unblock() {
    if [ -f $GMX ]; then
        [ -n "$w_gmx" ] && echo "$w_gmx" > $GMX
        o=${o_gmx:-system:system 644}; chown "${o% *}" $GMX 2>/dev/null; chmod "${o#* }" $GMX 2>/dev/null
    fi
    if [ -f $CFL ]; then
        [ -n "$w_cfl" ] && echo "$w_cfl" > $CFL
        o=${o_cfl:-radio:system 664}; chown "${o% *}" $CFL 2>/dev/null; chmod "${o#* }" $CFL 2>/dev/null
    fi
    for i in $POLS; do
        F=/sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq
        eval "o=\$o_$i"; [ -n "$o" ] || o="system:system 664"
        chown "${o% *}" $F 2>/dev/null; chmod "${o#* }" $F 2>/dev/null
    done
}

# Safety net: if the override is not running, the CPU limit files must be Samsung's again.
desk_cpu_reset() {
    old=$(cat "$BASE/desk.pid" 2>/dev/null)
    [ -n "$old" ] && kill -0 "$old" 2>/dev/null && return 0
    for F in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
        [ "$(stat -c %U $F 2>/dev/null)" = root ] || continue
        chown system:system $F 2>/dev/null; chmod 664 $F 2>/dev/null
        log "CPU limit file $F given back to Samsung (override not running)"
    done
    if [ -f $GMX ] && [ "$(stat -c %U $GMX 2>/dev/null)" = root ]; then
        chown system:system $GMX 2>/dev/null; chmod 644 $GMX 2>/dev/null
        log "Samsung GPU limit given back (override not running)"
    fi
    if [ -f $CFL ] && [ "$(stat -c %U $CFL 2>/dev/null)" = root ]; then
        chown radio:system $CFL 2>/dev/null; chmod 664 $CFL 2>/dev/null
        log "Samsung CPU limit driver given back (override not running)"
    fi
}

desk_run() {
    pidf=$BASE/desk.pid
    old=$(cat "$pidf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q display.sh "/proc/$old/cmdline" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$pidf"
    G=/sys/class/kgsl/kgsl-3d0/thermal_pwrlevel
    POLS=""; for c in /sys/devices/system/cpu/cpufreq/policy*; do [ -w "$c/scaling_max_freq" ] && POLS="$POLS ${c##*policy}"; done
    # Samsung's wish per node (the value it last set).
    read -r w_g < $G
    for i in $POLS; do read -r v < /sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq; eval "w_$i=$v"; done
    mode=on; t=0; n_over=0
    desk_cpu_block
    echo "on full speed" > "$BASE/desk.state"
    lb=$(get_set desk_bat); la=$(get_set desk_ap); ls=$(get_set desk_skin); [ "$ls" = 999 ] && ls=ignored
    log "temperature override on (Samsung's limits overridden; back at battery ${lb:-41} C, board ${la:-80} C, skin ${ls:-56})"
    # Only the copy named in desk.pid keeps running (a restart must never leave two).
    while [ -f "$BASE/desk.run" ] && { dp=""; read -r dp 2>/dev/null < "$pidf"; [ "$dp" = $$ ]; }; do
        if [ $((t % 5)) = 0 ]; then
            # Limits can be tuned in the settings file (desk_bat, desk_ap, desk_skin); the "cool
            # again" levels stay 3-8 degrees lower.
            DESK_BAT=$(get_set desk_bat); DESK_BAT=${DESK_BAT:-41}; DESK_BAT_OK=$((DESK_BAT - 3))
            DESK_AP=$(get_set desk_ap); DESK_AP=${DESK_AP:-80}; DESK_AP_OK=$((DESK_AP - 8))
            DESK_SKIN=$(get_set desk_skin); DESK_SKIN=${DESK_SKIN:-56}; DESK_SKIN_OK=$((DESK_SKIN - 4))
            desk_temps
            if [ "$mode" = on ]; then
                why=""
                [ "$d_bat" -ge "$DESK_BAT" ] && why="battery ${d_bat} C"
                [ "$d_ap" -ge "$DESK_AP" ] && why="board ${d_ap} C"
                [ "$d_skin" -ge "$DESK_SKIN" ] && why="skin ${d_skin} C"
                [ "$d_st" -ge 5 ] && why="thermal status $d_st"
                if [ -n "$why" ]; then
                    mode=back
                    echo "$w_g" > $G
                    for i in $POLS; do eval "echo \$w_$i" > /sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq; done
                    desk_cpu_unblock
                    echo "back $why" > "$BASE/desk.state"
                    log "temperature override: $why; Samsung's limits back"
                fi
            elif [ "$d_bat" -lt "$DESK_BAT_OK" ] && [ "$d_ap" -lt "$DESK_AP_OK" ] && [ "$d_skin" -lt "$DESK_SKIN_OK" ] && [ "$d_st" -lt 5 ]; then
                mode=on
                desk_cpu_block
                echo "on full speed" > "$BASE/desk.state"
                log "temperature override: cool again (battery $d_bat C, board $d_ap C, skin $d_skin C); full speed"
            fi
        fi
        if [ "$mode" = on ]; then
            if [ -f $CFL ]; then read -r v < $CFL; [ "$v" != -1 ] && { w_cfl=$v; echo -1 > $CFL; n_over=$((n_over + 1)); }; fi
            if [ -f $GMX ]; then read -r v < $GMX; [ "$v" != "$gtop" ] && { w_gmx=$v; echo "$gtop" > $GMX; n_over=$((n_over + 1)); }; fi
            read -r g < $G
            if [ "$g" != 0 ]; then w_g=$g; echo 0 > $G; n_over=$((n_over + 1)); fi
            for i in $POLS; do
                P=/sys/devices/system/cpu/cpufreq/policy$i
                read -r v < $P/scaling_max_freq; read -r top < $P/cpuinfo_max_freq
                if [ "$v" != "$top" ]; then eval "w_$i=$v"; echo "$top" > $P/scaling_max_freq; n_over=$((n_over + 1)); fi
            done
        else
            [ -f $CFL ] && read -r w_cfl < $CFL
            [ -f $GMX ] && read -r w_gmx < $GMX
            read -r w_g < $G
            for i in $POLS; do read -r v < /sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq; eval "w_$i=$v"; done
        fi
        sleep 1; t=$((t + 1))
    done
    # Hand everything back to Samsung.
    echo "$w_g" > $G
    for i in $POLS; do eval "echo \$w_$i" > /sys/devices/system/cpu/cpufreq/policy$i/scaling_max_freq; done
    [ "$mode" = on ] && desk_cpu_unblock
    dp=""; read -r dp 2>/dev/null < "$pidf"
    [ "$dp" = $$ ] && rm -f "$BASE/desk.state" "$pidf"
    log "temperature override off ($n_over limits put back to full speed)"
}

desk_start() {
    [ "$(get_set desk_mode)" = 1 ] && connected || return 0
    touch "$BASE/desk.run"
    spawn sh "$0" desk-run
}

desk_stop() {
    [ -f "$BASE/desk.run" ] || [ -f "$BASE/desk.pid" ] || return 0
    rm -f "$BASE/desk.run"
    i=0; while [ -f "$BASE/desk.pid" ] && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
}

# Limits, all above Samsung's own: battery 41/45/50, board 80/90/100, skin 56/65/off (999).
desk_limit_cmd() {
    case "$1:$2" in
        bat:41|bat:45|bat:50|ap:80|ap:90|ap:100|skin:56|skin:65) put_set "desk_$1" "$2" ;;
        skin:off) put_set desk_skin 999 ;;
        *) echo "error=use: temp-limit bat 41|45|50 | ap 80|90|100 | skin 56|65|off"; return 1 ;;
    esac
    log "temperature override limit $1 -> $2"
    echo "ok=1"
}

desk_cmd() {
    case "$1" in
        on) put_set desk_mode 1; log "switch: temperature override ON"; desk_start; echo "ok=1" ;;
        off) put_set desk_mode 0; log "switch: temperature override OFF"; desk_stop; echo "ok=1" ;;
        *) echo "error=use: temp-override on|off" ;;
    esac
}

# ---- Watcher ----------------------------------------------------------------------------------

# Everything that follows a connect (also used when the watcher finds the state drifted).
connect_steps() {
    lock
    # Ask the composer for this monitor's last mode right away, so the re-plugs below (DSC, extra
    # rates) do not come up in the monitor's preferred mode first (the LG's own 120 Hz is too fast
    # for its decoder with DSC: black). Falls back to the first mode if not offered.
    id=$(edid_id); lk=""
    [ -n "$id" ] && read -r lk 2>/dev/null < "$BASE/lastmode.$id"
    valid "$lk:1" && [ "$(getprop $PROP)" != "$lk:1" ] && setprop $PROP "$lk:1"
    custom_on_connect || wait_sf >/dev/null
    if dsc_auto; then
        # The switches only count at a connect: the extra rates' re-plug does it, or one now.
        id=$(edid_id)
        if [ -f "$EXTRA/$id" ]; then [ -f "$BASE/custom.active" ] && extra_apply "$id"; else hw_replug; fi
    fi
    extra_auto
    on_connect
    unlock
    pace
    inner_apply
    guard_start
    desk_start
}

# A reconnect the watcher missed (for example while it was busy) leaves things half done: DSC
# switches not as this monitor wants, extra rates on but not applied, or a mode override not in
# effect although offered. 0 = drifted.
drift() {
    [ -f "$BASE/replug.busy" ] && return 1
    id=$(edid_id); [ -n "$id" ] || return 1
    if debugfs_up; then
        read -r f < "$DBG/dsc_feature_enable"
        w=N; dsc_wanted "$id" && w=Y
        [ "$f" = "$w" ] || return 0
    fi
    [ -f "$EXTRA/$id" ] && [ ! -f "$BASE/custom.active" ] && return 0
    pr=$(getprop $PROP); pr=${pr%:1}
    [ -n "$pr" ] || return 1
    b=$(ext_block)
    a=$(printf '%s\n' "$b" | sed -n 's/.*activeMode={id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/\1@\2/p' | head -n 1)
    [ -n "$a" ] || return 1
    [ "$(to_key "$a")" = "$pr" ] && return 1
    for m in $(printf '%s\n' "$b" | modes_of); do [ "$(to_key "$m")" = "$pr" ] && return 0; done
    return 1
}

# Cheap watcher: every 3 s one sysfs read and one /proc stat; while a monitor is connected also an
# EDID checksum (one small process), and every 30 s a pacesetter and refresh-rate check.
watch() {
    pidf=$BASE/watch.pid
    old=$(cat "$pidf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q display.sh "/proc/$old/cmdline" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$pidf"
    prev=""; sum=""; tick=0; gone=0; gone_t=0
    # Wait without starting a process: `sleep` is a separate program on Android (fork + exec every
    # 3 s was 85 % of the watcher's CPU time). read -t on an idle FIFO waits inside the shell.
    [ -p "$BASE/tick" ] || { rm -f "$BASE/tick"; mkfifo "$BASE/tick" 2>/dev/null; }
    fifo=0
    if [ -p "$BASE/tick" ] && exec 9<>"$BASE/tick"; then fifo=1; nap() { read -t "$1" -u9 _ 2>/dev/null; }; else nap() { sleep "$1"; }; fi
    sfp=$(pidof surfaceflinger)
    # Started without a monitor (boot, or after a crash): nothing of ours may stay applied.
    connected || { inner_restore; custom_clear; }
    rm -f "$BASE/replug.busy"
    desk_cpu_reset
    # A software re-plug interrupted halfway would leave the DP output off.
    [ -f "$BASE/extdisp.off" ] && { echo "ExtDispOff,0" > $XD 2>/dev/null; rm -f "$BASE/extdisp.off"; log "DP output switched back on after an interrupted re-plug"; }
    while :; do
        # Only the watcher named in watch.pid keeps running.
        wp=""; read -r wp 2>/dev/null < "$pidf"; [ "$wp" = $$ ] || exit 0
        read -r st < $CONN/status 2>/dev/null
        if [ "$st" != "$prev" ]; then
            if [ "$st" = connected ]; then
                [ "$gone" = 1 ] && log "monitor back after $(($(up_s) - gone_t)) s (mode switch or re-plug); settings kept"
                gone=0
                sum=$(cksum < $CONN/edid 2>/dev/null)
                wait_sf >/dev/null
                connect_steps
            elif [ "$prev" = connected ] && [ ! -f "$BASE/replug.busy" ]; then
                # Our custom EDID goes at once (it must never reach another monitor). The rest waits:
                # monitors that switch mode by reconnecting (XREAL ultrawide, input or menu changes)
                # come back within seconds, and then nothing needs undoing.
                custom_on_disconnect
                gone_t=$(up_s); gone=1
            fi
            read -r prev < $CONN/status 2>/dev/null
            sum=$(cksum < $CONN/edid 2>/dev/null)
        elif [ "$st" != connected ] && [ "$gone" = 1 ] && [ $(($(up_s) - gone_t)) -ge 8 ]; then
            # Still gone after 8 s: a real unplug.
            gone=0
            log "monitor unplugged"
            guard_stop wake
            desk_stop
            [ -f "$THL" ] && rm -f "${THL:?}"
            unpace
            inner_restore
        elif [ "$st" = connected ]; then
            # Same cable, new EDID: the monitor switched mode itself (most do it by reconnecting,
            # which is caught above). Checked every 9 s: cksum is a separate program.
            s2=$sum; [ $((tick % 3)) = 0 ] && s2=$(cksum < $CONN/edid 2>/dev/null)
            if [ -n "$s2" ] && [ "$s2" != "$sum" ]; then
                log "EDID changed without unplugging"
                sum=$s2
                lock
                custom_on_connect || wait_sf >/dev/null
                on_connect
                unlock
                pace
            fi
            tick=$((tick + 1))
            if [ $((tick % 10)) = 0 ]; then
                if drift; then
                    log "state does not match this monitor (missed reconnect?); applying again"
                    connect_steps
                    sum=$(cksum < $CONN/edid 2>/dev/null)
                fi
                pacesetter_ok || { log "pacesetter lost; re-applying"; pace_now; }
                thermal_guard
                inner_apply
                [ "$(get_set phone_guard)" = 1 ] && [ ! -f "$BASE/guard.pid" ] && guard_start
                [ "$(get_set desk_mode)" = 1 ] && [ ! -f "$BASE/desk.pid" ] && desk_start
            fi
        fi
        if [ -z "$sfp" ] || [ ! -d "/proc/$sfp" ]; then
            sleep 5
            sfp=$(pidof surfaceflinger)
            [ "$st" = connected ] && { log "SurfaceFlinger restarted"; pace; }
        fi
        if [ "$st" != connected ] && [ "$gone" != 1 ] && [ "$fifo" = 1 ] && [ -f "$MANUAL" ]; then
            # Detection on request: no timer at all, so it costs nothing until `display.sh wake`
            # (a script, Tasker, Termux) or the page being opened.
            : > "$BASE/asleep"
            read -u9 _ 2>/dev/null
            rm -f "$BASE/asleep"
        # No monitor and the phone's screens off: look less often (a plug-in wakes the screen anyway).
        elif [ "$st" != connected ] && ! phone_is_on; then nap 15; else nap 3; fi
    done
}

case "$1" in
    status) status "$2" ;;
    set) lock; set_mode "$2" "$3"; unlock ;;
    confirm) if [ "$2" = back ]; then lock; confirm_cmd back; unlock; else confirm_cmd; fi ;;
    revert-timer) revert_timer ;;
    thermal-fallback) thermal_cmd "$2" ;;
    inner-verify) inner_verify ;;
    dex-recover) dex_recover_cmd "$2" ;;
    detect) detect_cmd "$2" ;;
    wake) rm -f "$BASE/asleep"; wake_watcher; echo "ok=1" ;;
    extra-add) lock; xrate_cmd add "$2"; unlock ;;
    extra-del) lock; xrate_cmd del "$2"; unlock ;;
    forget-failed) connected && { i=$(edid_id); rm -f "${BASE:?}/bad/${i:?}"; log "$i: failed modes forgotten"; mode_info; }; echo "ok=1" ;;
    temp-override|desk-mode) desk_cmd "$2" ;;
    temp-limit|desk-limit) desk_limit_cmd "$2" "$3" ;;
    desk-run) desk_run ;;
    dsc) case "$2" in auto-*) dsc_cmd "$2" ;; *) lock; dsc_cmd "$2"; unlock ;; esac ;;
    reset) lock; reset_mode; unlock ;;
    pace) pace ;;
    phone) phone_cmd "$2" ;;
    phone-guard) guard_cmd "$2" ;;
    guard-run) guard_run ;;
    inner-hz) inner_cmd "$2" ;;
    extra|exp75) lock; extra_cmd "$2"; unlock ;;
    watch) tail -n 300 "$LOG" > "$LOG.trim" 2>/dev/null && mv -f "$LOG.trim" "$LOG"; watch ;;
    boot)
        # A fresh kernel has no custom EDID and no running guard.
        rm -f "$BASE/op.lock/pid"; rmdir "$BASE/op.lock" 2>/dev/null
        rm -f "$BASE/confirm.pending" "$BASE/dsc.state" "$BASE/modeinfo" "$BASE/thermal.lowered" "$BASE/desk.run" "$BASE/desk.pid" "$BASE/desk.state" "$BASE/custom.active" "$BASE/custom.sum" "$BASE/extra.modes" "$BASE/extra.base" "$BASE/extra.real" "$BASE/extdisp.off" "$BASE/replug.busy" "$BASE/guard.run" "$BASE/guard.pid" "$BASE/guard.armed" "$BASE/guard.keypid" "$BASE/asleep" "$DMC"
        last=$(cat "$BASE/last" 2>/dev/null)
        want=$(cat "$PROF/$last" 2>/dev/null)
        valid "$want" && setprop $PROP "$want"
        ;;
    *) echo "use: display.sh status [full] | set W:H:HZ | reset | phone on|off | phone-guard on|off | inner-hz N|off | extra on|off | dsc on|off|auto-on|auto-off | thermal-fallback on|off | dex-recover on|off | detect auto|manual | wake | temp-override on|off | temp-limit bat|ap|skin N | confirm [back] | watch | boot" ;;
esac
