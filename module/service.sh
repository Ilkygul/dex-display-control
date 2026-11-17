#!/system/bin/sh
# DeX Display Control, service stage: clear state a fresh kernel no longer has, restore the mode saved
# for the last monitor (the composer reads it at the next connect or soft reboot), and start the
# small connect watcher. The watcher guards against a second copy itself, since ksud runs this
# again on every soft reboot (and "boot" must then not wipe a running guard: it only runs once
# per kernel boot, marked in /dev).
M=${0%/*}
if [ ! -f /dev/.fold-display-booted ]; then
    touch /dev/.fold-display-booted
    sh "$M/display.sh" boot
fi
nohup setsid sh "$M/display.sh" watch </dev/null >/dev/null 2>&1 &
exit 0
