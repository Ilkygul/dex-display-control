#!/system/bin/sh
# DeX Display Control, uninstall: put everything this module changed back.
B=/data/adb/fold-display

# Stop the watcher and the phone-screen guard.
rm -f "$B/guard.run"
for f in watch.pid guard.pid; do
    p=$(cat "$B/$f" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null
done
for p in $(pidof getevent); do grep -q event4 "/proc/$p/cmdline" 2>/dev/null && kill "$p"; done

# Phone screen refresh rate: the user's own values.
if [ -f "$B/refresh.saved" ]; then
    read -r mn pk < "$B/refresh.saved"
    case "$mn" in null|"") settings delete system min_refresh_rate ;; *) settings put system min_refresh_rate "$mn" ;; esac
    case "$pk" in null|"") settings delete system peak_refresh_rate ;; *) settings put system peak_refresh_rate "$pk" ;; esac
fi

# Composer mode override, app frame clock, custom EDID.
setprop vendor.display.hdmi_cfg_idx ""
service call SurfaceFlingerAIDL 85 >/dev/null 2>&1
# Custom EDID and DSC: cleared with the DP output off (software re-plug), as the module does it.
# (KernelSU usually runs this at the next boot, when none of it is set any more.)
D=/sys/kernel/debug/drm_dp
if [ -e "$D/sim" ] && { [ -f "$B/custom.sum" ] || [ -d "$B/dsc" ]; }; then
    echo "ExtDispOff,1" > /sys/class/dp_sec/dex 2>/dev/null
    sleep 4
    echo 0 > "$D/sim" 2>/dev/null
    echo 0 > "$D/dsc_feature_enable" 2>/dev/null
    echo 0 > "$D/fec_feature_enable" 2>/dev/null
    echo "ExtDispOff,0" > /sys/class/dp_sec/dex 2>/dev/null
fi

# Phone screen on, in case the guard was holding it off.
cmd power wakeup --display-id 0 >/dev/null 2>&1

rm -rf "$B"
