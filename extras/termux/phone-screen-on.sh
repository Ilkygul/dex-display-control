#!/data/data/com.termux/files/usr/bin/bash
# Wake the phone screen while DeX runs on a monitor, and tell DeX Display Control the wake is on
# purpose (so "Keep phone screen off" lets it stay on until it turns off again).
# Termux needs root for this (grant it in KernelSU Manager > Superuser). Falls back to the plain
# Android command when the module is not installed or disabled.
M=/data/adb/modules/fold-display
su -c "[ -f $M/display.sh ] && [ ! -f $M/disable ] && sh $M/display.sh phone on" 2>/dev/null \
    || su -c "cmd power wakeup --display-id 0"
