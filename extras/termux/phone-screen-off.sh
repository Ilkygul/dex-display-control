#!/data/data/com.termux/files/usr/bin/bash
# Turn the phone screen off while DeX keeps running on the monitor (only the phone's own display
# group sleeps). With "Keep phone screen off" on, DeX Display Control keeps it off from here on.
# Termux needs root for this (grant it in KernelSU Manager > Superuser).
su -c '
info=$(cmd display get-displays --type external)
case "$info" in *"state ON"*) ;; *) echo "No active external display; nothing changed." >&2; exit 1;; esac
M=/data/adb/modules/fold-display
[ -f $M/display.sh ] && [ ! -f $M/disable ] && sh $M/display.sh phone off || cmd power sleep --display-id 0
'
