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
    rm -f "$DMC"
}

unpace() { service call SurfaceFlingerAIDL 85 >/dev/null 2>&1 && log "pacesetter reset to the Fold"; }

# Point composer and DisplayManager at mode $1 (W:H:HZ, or empty for the monitor's own default)
# and reconnect so both take it. $2 = SurfaceFlinger display id (for the DisplayManager lookup).
apply_mode() {
    want=$1; sid=$2
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
    read -r d1 < /sys/class/drm/card0-DSI-1/dpms 2>/dev/null
    read -r d2 < /sys/class/drm/card0-DSI-2/dpms 2>/dev/null
    [ "$d1" = On ] || [ "$d2" = On ] && echo "phone=on" || echo "phone=off"
    [ -f "$BASE/guard.armed" ] && echo "armed=1" || echo "armed=0"
    [ -f "$BASE/custom.active" ] && { read -r ca < "$BASE/custom.active"; echo "custom=active:$ca"; }
    [ -f "$BASE/extra.modes" ] && { read -r xm < "$BASE/extra.modes"; echo "extra_modes=$xm"; }
    [ -d "$EXTRA" ] && for f in "$EXTRA"/*; do [ -f "$f" ] && echo "extra_on=${f##*/}"; done
    if ! connected; then
        echo "connected=0"
        return 0
    fi
    echo "connected=1"
    echo "edid=$(edid_hex)"
    disp=$(dumpsys SurfaceFlinger --displays 2>/dev/null)
    # One pass over SurfaceFlinger's displays: the phone panel's render rate (the one powered on).
    cur=""; typ=""; pm=""
    while IFS= read -r l; do
        case "$l" in
            "Display "*) cur=${l#Display }; typ=""; pm="" ;;
            *connectionType=*) typ=${l#*=} ;;
            *powerMode=*) pm=${l#*=} ;;
            *renderRate=*) [ "$typ" = Internal ] && [ "$pm" = ON ] && { r=${l#*=}; echo "inner_rate=${r% Hz}"; } ;;
        esac
    done <<EOF
$disp
EOF
    b=$(printf '%s\n' "$disp" | ext_from)
    sfid=${b%%
*}; sfid=${sfid#Display }
    [ -n "$sfid" ] || return 0
    echo "sfid=$sfid"
    printf '%s\n' "$b" | sed -n \
        -e 's/.*activeMode={id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/current=\1@\2/p' \
        -e 's/^ *renderRate=\([0-9.]*\) Hz.*/render=\1/p' \
        -e 's/^ *{id=[0-9]*, hwcId=[0-9]*, resolution=\([0-9x]*\), vsyncRate=\([0-9.]*\) Hz.*/mode=\1@\2/p'
    # Pacesetter and this display's frame counters (HWC + GPU); two readings give frames/s.
    pid=""; n=0
    while IFS='=' read -r k v; do
        case "$k" in
            pid) pid=$v ;;
            fc) n=$((n + v)) ;;
        esac
    done <<EOF
$(dumpsys SurfaceFlinger --scheduler 2>/dev/null | sed -n \
    -e 's/^ *pacesetterDisplayId=\([0-9]*\).*/pid=\1/p' \
    -e "/^[A-Za-z]* Display $sfid\$/,/^[A-Za-z]* Display [0-9]/s/^ *[HG][WP][CU] frame count: \([0-9]*\).*/fc=\1/p")
EOF
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
    echo "$key:1" > "$PROF/$id-$var"
    echo "$id" > "$BASE/last"
    log "set $id ($var) -> $key"
    apply_mode "$key" "$(ext_sf_id)"
    spawn sh "$0" pace
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
    prop=$(getprop $PROP); prop=${prop%:1}
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

# Uses system min/peak_refresh_rate. The user's values (also those set by refresh-rate apps) are
# saved on connect and put back on disconnect; ours are re-applied if something changes them meanwhile.
inner_apply() {
    hz=$(get_set inner_hz)
    case "$hz" in 120|80|60|48|30|20) ;; *) inner_restore; return 0 ;; esac
    connected || return 0
    if [ ! -f "$BASE/refresh.saved" ]; then
        echo "$(settings get system min_refresh_rate) $(settings get system peak_refresh_rate)" > "$BASE/refresh.saved"
    fi
    [ "$(settings get system peak_refresh_rate)" = "$hz.0" ] && [ "$(settings get system min_refresh_rate)" = "$hz.0" ] && return 0
    settings put system peak_refresh_rate "$hz.0"
    settings put system min_refresh_rate "$hz.0"
    log "phone screen refresh -> $hz Hz"
}

inner_restore() {
    [ -f "$BASE/refresh.saved" ] || return 0
    read -r mn pk < "$BASE/refresh.saved"
    case "$mn" in null|"") settings delete system min_refresh_rate >/dev/null 2>&1 ;; *) settings put system min_refresh_rate "$mn" ;; esac
    case "$pk" in null|"") settings delete system peak_refresh_rate >/dev/null 2>&1 ;; *) settings put system peak_refresh_rate "$pk" ;; esac
    rm -f "$BASE/refresh.saved"
    log "phone screen refresh restored (min $mn, peak $pk)"
}

inner_cmd() {
    case "$1" in
        120|80|60|48|30|20) put_set inner_hz "$1"; inner_apply; echo "ok=1" ;;
        off) put_set inner_hz ""; inner_restore; echo "ok=1" ;;
        *) echo "error=use: inner-hz 120|80|60|48|30|20|off" ;;
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
        rm -f "$BASE/custom.sum" "$BASE/extra.modes" "$BASE/extra.base"
        log "custom EDID cleared; monitor read with its own EDID"
    else
        # Nothing to read now: keep custom.sum, the next connect checks what the monitor sends.
        sim_off
        rm -f "$BASE/extra.modes" "$BASE/extra.base"
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
    rm -f "$BASE/custom.sum" "$BASE/custom.active" "$BASE/extra.modes" "$BASE/extra.base"
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
HZ_STEPS="70 75 80 85 90 100 110 120 144 165"

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
    ar=$((ha * va)); sc=$((hz10 > 600 ? hz10 - 600 : 600 - hz10))
    if [ "$ar" -gt "$best_ar" ] || { [ "$ar" -eq "$best_ar" ] && [ "$sc" -lt "$best_sc" ]; }; then
        best_ar=$ar; best_sc=$sc; best="$ha $hb $hfp $hsw $va $vb $vfp $vsw $hp $vp"; best_hz=$(((hz10 + 5) / 10))
    fi
}

cks() { s=0; i=0; while [ "$i" -lt "${#1}" ]; do s=$((s + 0x${1:$i:2})); i=$((i + 2)); done; printf '%02x' $(((256 - s % 256) % 256)); }

# Writes $BASE/extra.hex (the new EDID) and $BASE/extra.modes ("W:H:HZ:BPP ..."); 1 if nothing fits.
# mksh arithmetic is 32-bit, hence the divisions before multiplying.
make_extra() {
    h=$(edid_hex)
    [ "${#h}" -ge 256 ] || return 1
    by n 126
    [ "$n" -le 6 ] && [ "${#h}" -eq $(((n + 1) * 256)) ] || return 1
    best=""; best_ar=0; best_sc=99999
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
    top=0
    for k in $(offered); do case "$k" in "$ha:$va:"*) z=${k##*:}; [ "$z" -gt "$top" ] && top=$z ;; esac; done
    cap=$(link_cap); [ -n "$cap" ] || cap=17280000
    list=""
    for hz in $HZ_STEPS; do
        [ "$hz" -gt "$top" ] && [ "$hz" -le "$vmax" ] || continue
        khz=$((frame / 100 * hz / 10))
        [ $((khz * 18)) -le $((cap / 100 * 98)) ] || continue
        bpp=18
        for t in 24 30; do [ "$t" -le "$maxb" ] && [ $((khz * t)) -le "$cap" ] && bpp=$t; done
        list="$list $hz:$bpp"
    done
    set -- $list
    while [ "$#" -gt 5 ]; do shift; done
    [ "$#" -gt 0 ] || return 1
    asp=00
    [ $((ha * 9)) -eq $((va * 16)) ] && asp=04
    [ $((ha * 10)) -eq $((va * 16)) ] && asp=05
    [ $((ha * 27)) -eq $((va * 64)) ] && asp=06
    tim=""; modes=""
    for m in "$@"; do
        hz=${m%:*}
        p=$((frame / 100 * hz / 100 - 1))
        tim="$tim$(printf '%02x%02x%02x' $((p & 255)) $(((p >> 8) & 255)) $(((p >> 16) & 255)))$asp"
        tim="$tim$(le16 $((ha - 1)))$(le16 $((hb - 1)))$(le16 $(((hfp - 1) | hp)))$(le16 $((hsw - 1)))"
        tim="$tim$(le16 $((va - 1)))$(le16 $((vb - 1)))$(le16 $(((vfp - 1) | vp)))$(le16 $((vsw - 1)))"
        modes="$modes $ha:$va:$m"
    done
    nb=$(($# * 20))
    sec="12$(printf '%02x' $((nb + 3)))0300"0300$(printf '%02x' $nb)$tim
    blk="70$sec$(cks "$sec")"
    while [ "${#blk}" -lt 254 ]; do blk="${blk}00"; done
    blk="$blk$(cks "$blk")"
    b0="${h:0:252}$(printf '%02x' $((n + 1)))"
    b0="$b0$(cks "$b0")"
    echo "$b0${h:256}$blk" > "$BASE/extra.hex"
    echo "${modes# }" > "$BASE/extra.modes"
    echo "$ha:$va:$best_hz" > "$BASE/extra.base"
}

# Build, write and apply for monitor $1. 0 = at least one extra rate offered now; 1 = none fits;
# 2 = no debugfs; 3 = the kernel took none of them (cleared again).
extra_apply() {
    make_extra || return 1
    debugfs_up || return 2
    read -r x < "$BASE/extra.hex"
    printf '%s' "$x" > "$DBG/edid" || return 2
    printf '%s' "$x" | cksum > "$BASE/custom.sum"
    echo "$1" > "$BASE/custom.active"
    read -r xm < "$BASE/extra.modes"
    log "extra refresh rates for $1 ($xm); software re-plug"
    hw_replug
    have=" $(offered)"; got=""
    for m in $xm; do case "$have" in *" ${m%:*} "*) got="$got ${m%:*}" ;; esac; done
    [ -n "$got" ] && { log "offered now:$got"; return 0; }
    log "none of the extra rates was accepted; back to the monitor's own EDID"
    custom_clear
    return 3
}

# Watcher, on connect: re-apply for a monitor that has extra rates switched on.
extra_auto() {
    id=$(edid_id)
    [ -n "$id" ] && [ -f "$EXTRA/$id" ] && [ ! -f "$BASE/custom.active" ] || return 0
    log "$id: extra refresh rates are on for this monitor; applying"
    extra_apply "$id"
}

extra_cmd() {
    settle
    connected || { echo "error=No external display connected"; return 1; }
    id=$(edid_id)
    case "$1" in
        on)
            mkdir -p "$EXTRA"
            [ -f "$BASE/custom.active" ] && { touch "$EXTRA/$id"; echo "ok=1"; return; }
            extra_apply "$id"
            case $? in
                0) touch "$EXTRA/$id"; echo "ok=1" ;;
                1) echo "error=No higher refresh rate fits this monitor and the link (or its EDID has no usable timing)" ;;
                2) echo "error=Qualcomm DisplayPort debugfs not available" ;;
                *) echo "error=The phone did not accept the extra rates for this monitor" ;;
            esac ;;
        off)
            rm -f "$EXTRA/$id"
            custom_clear
            echo "ok=1" ;;
        *) echo "error=use: extra on|off" ;;
    esac
}

# ---- Watcher ----------------------------------------------------------------------------------

# Cheap watcher: every 3 s one sysfs read and one /proc stat; while a monitor is connected also an
# EDID checksum (one small process), and every 30 s a pacesetter and refresh-rate check.
watch() {
    pidf=$BASE/watch.pid
    old=$(cat "$pidf" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q display.sh "/proc/$old/cmdline" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$pidf"
    prev=""; sum=""; tick=0
    sfp=$(pidof surfaceflinger)
    # Started without a monitor (boot, or after a crash): nothing of ours may stay applied.
    connected || { inner_restore; custom_clear; }
    rm -f "$BASE/replug.busy"
    # A software re-plug interrupted halfway would leave the DP output off.
    [ -f "$BASE/extdisp.off" ] && { echo "ExtDispOff,0" > $XD 2>/dev/null; rm -f "$BASE/extdisp.off"; log "DP output switched back on after an interrupted re-plug"; }
    while :; do
        read -r st < $CONN/status 2>/dev/null
        if [ "$st" != "$prev" ]; then
            if [ "$st" = connected ]; then
                sum=$(cksum < $CONN/edid 2>/dev/null)
                wait_sf >/dev/null
                custom_on_connect || wait_sf >/dev/null
                extra_auto
                on_connect
                pace
                inner_apply
                guard_start
            elif [ "$prev" = connected ] && [ ! -f "$BASE/replug.busy" ]; then
                guard_stop wake
                unpace
                inner_restore
                custom_on_disconnect
            fi
            read -r prev < $CONN/status 2>/dev/null
            sum=$(cksum < $CONN/edid 2>/dev/null)
        elif [ "$st" = connected ]; then
            # Same cable, new EDID: the monitor switched mode itself (XREAL ultrawide).
            s2=$(cksum < $CONN/edid 2>/dev/null)
            if [ -n "$s2" ] && [ "$s2" != "$sum" ]; then
                log "EDID changed without unplugging"
                sum=$s2
                custom_on_connect || wait_sf >/dev/null
                on_connect
                pace
            fi
            tick=$((tick + 1))
            if [ $((tick % 10)) = 0 ]; then
                pacesetter_ok || { log "pacesetter lost; re-applying"; pace_now; }
                inner_apply
                [ "$(get_set phone_guard)" = 1 ] && [ ! -f "$BASE/guard.pid" ] && guard_start
            fi
        fi
        if [ -z "$sfp" ] || [ ! -d "/proc/$sfp" ]; then
            sleep 5
            sfp=$(pidof surfaceflinger)
            [ "$st" = connected ] && { log "SurfaceFlinger restarted"; pace; }
        fi
        sleep 3
    done
}

case "$1" in
    status) status "$2" ;;
    set) set_mode "$2" ;;
    reset) reset_mode ;;
    pace) pace ;;
    phone) phone_cmd "$2" ;;
    phone-guard) guard_cmd "$2" ;;
    guard-run) guard_run ;;
    inner-hz) inner_cmd "$2" ;;
    extra|exp75) extra_cmd "$2" ;;
    watch) tail -n 300 "$LOG" > "$LOG.trim" 2>/dev/null && mv -f "$LOG.trim" "$LOG"; watch ;;
    boot)
        # A fresh kernel has no custom EDID and no running guard.
        rm -f "$BASE/custom.active" "$BASE/custom.sum" "$BASE/extra.modes" "$BASE/extra.base" "$BASE/extdisp.off" "$BASE/replug.busy" "$BASE/guard.run" "$BASE/guard.pid" "$BASE/guard.armed" "$BASE/guard.keypid" "$DMC"
        last=$(cat "$BASE/last" 2>/dev/null)
        want=$(cat "$PROF/$last" 2>/dev/null)
        valid "$want" && setprop $PROP "$want"
        ;;
    *) echo "use: display.sh status [full] | set W:H:HZ | reset | phone on|off | phone-guard on|off | inner-hz N|off | extra on|off | watch | boot" ;;
esac
