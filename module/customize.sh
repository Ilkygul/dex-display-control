# DeX Display Control installer (sourced by KernelSU / Magisk).
SKIPUNZIP=0

ui_print "- DeX Display Control"
case "$(getprop ro.board.platform)" in
    canoe) ;;
    *) ui_print "! Tested only on Snapdragon SM8850 (canoe, Galaxy Z Fold8)."
       ui_print "! Other Qualcomm Galaxy devices may work; use at your own risk." ;;
esac
[ -f /sys/class/drm/card0-DP-1/status ] || ui_print "! No DisplayPort connector found (card0-DP-1); the module will not see monitors."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/display.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
mkdir -p /data/adb/fold-display/profiles
ui_print "- Open the page from KernelSU Manager > Modules > DeX Display Control."
