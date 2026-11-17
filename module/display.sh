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
# - Experimental 4K 75 Hz: Qualcomm's DP debugfs takes a replacement EDID (drm_dp/edid, hex text) and
#   uses it at the next REAL hotplug - for whatever monitor that is, and while it is set the kernel
#   does not read the monitor's own EDID at all. So it is armed only on request, for the monitor
#   connected at that moment, kept 60 s for a re-plug, and cleared on every other disconnect with
#   `echo 0 > drm_dp/sim`. Writing invalid hex to drm_dp/edid did NOT clear it on Samsung's kernel
#   (a Dell's custom EDID was handed to the next monitor, an LG, on 2026-11-17), and a short valid
#   string makes a 0-byte custom EDID, so neither is used. Every connect checks the EDID it reads
#   against the custom one and reports a leak instead of trusting the clear.
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

reconnect() {
    log "reconnect (override '$(getprop $PROP)')"
    rm -f "$DMC"
    echo off > $CONN/status
    sleep 2
    echo detect > $CONN/status
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
    [ -f "$BASE/custom.armed" ] && { read -r ca _ < "$BASE/custom.armed"; echo "custom=armed:$ca"; }
    [ -f "$BASE/custom.active" ] && { read -r ca < "$BASE/custom.active"; echo "custom=active:$ca"; }
    [ -f "$BASE/custom.leak" ] && echo "custom=leak"
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

# ---- Experimental: 4K 75 Hz through a custom EDID timing ------------------------------------

debugfs_up() {
    [ -e "$DBG/edid" ] && return 0
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
    [ -e "$DBG/edid" ]
}

# Custom EDID state files: custom.sum = checksum of the custom EDID written this boot (also marks
# that one was written); custom.armed = "<id> <uptime>", waiting for the re-plug; custom.active =
# in use by the connected monitor; custom.leak = a connect read the custom EDID without it being
# armed, i.e. a clear failed.
# Clear: sim mode off calls set_edid(NULL). It also aborts DP AUX and link activity, so it only runs
# with nothing connected; a pending clear runs at the next disconnect.
custom_clear() {
    [ -f "$BASE/custom.sum" ] || return 0
    if connected; then log "custom EDID clear waits for the disconnect"; return 1; fi
    debugfs_up || return 1
    echo 0 > "$DBG/sim" 2>/dev/null
    rm -f "$BASE/custom.sum" "$BASE/custom.armed" "$BASE/custom.active" "$BASE/custom.leak"
    log "custom EDID cleared (sim mode off)"
}

# On disconnect: an EDID just armed survives 60 s, the time to re-plug the same monitor; anything
# else is cleared, so the next monitor is read with its own EDID.
custom_on_disconnect() {
    [ -f "$BASE/custom.sum" ] || return 0
    if [ -f "$BASE/custom.armed" ] && [ ! -f "$BASE/custom.active" ]; then
        read -r _ at < "$BASE/custom.armed"
        read -r up _ < /proc/uptime
        [ "${up%.*}" -le $((${at:-0} + 60)) ] && { log "custom EDID kept 60 s for the re-plug"; return 0; }
    fi
    custom_clear
}

# On connect: is the EDID just read our custom one? Expected after arming; a leak otherwise.
custom_on_connect() {
    [ -f "$BASE/custom.sum" ] || return 0
    read -r want < "$BASE/custom.sum"
    got=$(edid_hex | cksum)
    if [ "$got" = "$want" ]; then
        if [ -f "$BASE/custom.armed" ]; then
            read -r cid _ < "$BASE/custom.armed"
            echo "$cid" > "$BASE/custom.active"; rm -f "$BASE/custom.armed"
            log "custom 4K 75 Hz EDID in use for $cid"
        elif [ ! -f "$BASE/custom.active" ]; then
            touch "$BASE/custom.leak"
            log "WARNING: a custom EDID is still in use without being armed (clear failed); unplug to clear"
        fi
    else
        # The monitor's own EDID was read: no custom EDID in effect any more.
        rm -f "$BASE/custom.sum" "$BASE/custom.armed" "$BASE/custom.active" "$BASE/custom.leak"
    fi
}

# Make the 4K 75 Hz EDID from the connected monitor's real one: a CVT-RB style timing (htotal 3920,
# vtotal 2229, 655.35 MHz - the most a standard timing descriptor can hold) replaces the serial
# number, dummy or text descriptor. Prints the hex, or nothing if the monitor does not qualify.
make_75() {
    h=$(edid_hex)
    [ "${#h}" -ge 256 ] || return 1
    # Needs 4K60 today, and a range limit (descriptor 0xfd) allowing 75 Hz and >= 656 MHz.
    case " $(offered)" in *" 3840:2160:60 "*) ;; *) return 1 ;; esac
    slot=""; ok75=0
    for o in 54 72 90 108; do
        d=${h:$((o * 2)):36}
        case "$d" in
            000000fd*)
                fl=$((0x${d:8:2})); vmax=$((0x${d:12:2})); pmax=$((0x${d:18:2}))
                [ $((fl & 2)) -ne 0 ] && vmax=$((vmax + 255))
                [ "$vmax" -ge 75 ] && [ $((pmax * 10)) -ge 656 ] && ok75=1 ;;
            000000ff*|00000010*|000000fe*) [ -z "$slot" ] && slot=$o ;;
        esac
    done
    [ "$ok75" = 1 ] && [ -n "$slot" ] || return 1
    # Physical size from the first timing descriptor (bytes 12-14).
    mm=${h:132:6}
    # 18 bytes: pclk ffff (655.35 MHz) | hact 3840 / hblank 80 (00 50 f0) | vact 2160 / vblank 69
    # (70 45 80) | hfp 8, hsw 32 (08 20) | vfp 55, vsw 8 (78 0c) | size | no border | digital
    # separate sync, H+ V- (1a). Same bytes as the EDID tested on the Dell U3225QE (2026-11-17).
    dtd="ffff0050f07045800820780c${mm}00001a"
    new="${h:0:$((slot * 2))}$dtd${h:$((slot * 2 + 36))}"
    sum=0; i=0
    while [ "$i" -lt 127 ]; do sum=$((sum + 0x${new:$((i * 2)):2})); i=$((i + 1)); done
    ck=$(printf '%02x' $(((256 - sum % 256) % 256)))
    echo "${new:0:254}$ck${new:256}"
}

exp75_cmd() {
    connected || { echo "error=No external display connected"; return 1; }
    case "$1" in
        on)
            [ -f "$BASE/custom.leak" ] && { echo "error=An older custom EDID is still in use. Unplug the monitor and plug it back in first."; return 1; }
            case " $(offered)" in *" 3840:2160:75 "*) echo "ok=1"; return ;; esac
            x=$(make_75)
            [ -n "$x" ] || { echo "error=This monitor does not qualify (needs 4K 60 Hz and a range up to 75 Hz)"; return 1; }
            debugfs_up || { echo "error=Qualcomm DisplayPort debugfs not available"; return 1; }
            printf '%s' "$x" > "$DBG/edid" || { echo "error=Could not write the custom EDID"; return 1; }
            printf '%s' "$x" | cksum > "$BASE/custom.sum"
            read -r up _ < /proc/uptime
            echo "$(edid_id) ${up%.*}" > "$BASE/custom.armed"
            log "custom 4K 75 Hz EDID armed for $(edid_id); re-plug within 60 s"
            echo "ok=1"; echo "replug=1" ;;
        off)
            # Not armed any more: the next disconnect clears it (it cannot be cleared while connected).
            rm -f "$BASE/custom.armed"
            echo "ok=1"; [ -f "$BASE/custom.sum" ] && echo "replug=1" ;;
        *) echo "error=use: exp75 on|off" ;;
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
    while :; do
        read -r st < $CONN/status 2>/dev/null
        if [ "$st" != "$prev" ]; then
            if [ "$st" = connected ]; then
                sum=$(cksum < $CONN/edid 2>/dev/null)
                wait_sf >/dev/null
                custom_on_connect
                # With a leaked custom EDID the monitor is misidentified: apply no profile to it.
                [ -f "$BASE/custom.leak" ] || on_connect
                pace
                inner_apply
                guard_start
            elif [ "$prev" = connected ]; then
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
                custom_on_connect
                [ -f "$BASE/custom.leak" ] || on_connect
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
    exp75) exp75_cmd "$2" ;;
    watch) tail -n 300 "$LOG" > "$LOG.trim" 2>/dev/null && mv -f "$LOG.trim" "$LOG"; watch ;;
    boot)
        # A fresh kernel has no custom EDID and no running guard.
        rm -f "$BASE/custom.active" "$BASE/custom.armed" "$BASE/custom.sum" "$BASE/custom.leak" "$BASE/guard.run" "$BASE/guard.pid" "$BASE/guard.armed" "$BASE/guard.keypid" "$DMC"
        last=$(cat "$BASE/last" 2>/dev/null)
        want=$(cat "$PROF/$last" 2>/dev/null)
        valid "$want" && setprop $PROP "$want"
        ;;
    *) echo "use: display.sh status [full] | set W:H:HZ | reset | phone on|off | phone-guard on|off | inner-hz N|off | exp75 on|off | watch | boot" ;;
esac
