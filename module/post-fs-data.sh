#!/system/bin/sh
# DeX Display Control, post-fs-data stage. Only does something during a KernelSU "soft reboot".
#
# A soft reboot stops SurfaceFlinger and zygote but leaves Qualcomm's display composer running.
# A composer that outlives its SurfaceFlinger ignores new hotplugs: after a soft reboot no external
# display worked until the next full reboot (Galaxy Z Fold8, 2026-11-17). ksud runs module
# post-fs-data scripts between its "stop" and "start", so restarting the composer here gives the new
# SurfaceFlinger a fresh one. Plain stop/start, not ctl.restart: the composer's
# "onrestart restart surfaceflinger" would start SurfaceFlinger before ksud is done.
# At a normal boot this stage runs before the composer exists (and within 120 s of boot), so the
# checks below skip it.

LOG=/data/adb/fold-display/composer-refresh.log
SVC=vendor.qti.hardware.display.composer

mkdir -p /data/adb/fold-display
tail -n 100 "$LOG" > "$LOG.trim" 2>/dev/null && mv -f "$LOG.trim" "$LOG"
exec >> "$LOG" 2>&1

up=$(cut -d. -f1 /proc/uptime)
sf=$(getprop init.svc.surfaceflinger)
hwc=$(getprop "init.svc.$SVC")
echo "== $(date) uptime ${up}s surfaceflinger=$sf composer=$hwc"

if [ "$up" -gt 120 ] && [ "$sf" != running ] && [ "$hwc" = running ]; then
    stop "$SVC"
    start "$SVC"
    i=0
    until [ "$(getprop "init.svc.$SVC")" = running ] || [ "$i" -ge 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    echo "composer restarted: $(getprop "init.svc.$SVC")"
else
    echo "skipped (not a soft reboot)"
fi
exit 0
