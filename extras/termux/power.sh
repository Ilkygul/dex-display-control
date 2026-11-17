#!/system/bin/sh
# Average whole-phone power over N seconds (default 30), from the battery fuel gauge's system
# current (power_now, mA) and system voltage (voltage_sys, mV). Works on battery and on external
# power. Run as root:  su -c "sh power.sh 30"
# Keep the screen still while measuring if you compare display settings.
N=${1:-30}
P=/sys/class/power_supply/battery
[ -r $P/power_now ] && [ -r $P/voltage_sys ] || { echo "power_now / voltage_sys not available on this phone"; exit 1; }
s=0; i=0
while [ "$i" -lt "$N" ]; do
    read -r ma < $P/power_now; read -r mv < $P/voltage_sys
    s=$((s + ma * mv / 1000)); i=$((i + 1))
    sleep 1
done
mw=$((s / N))
echo "average over $N s: $((mw / 1000)).$(printf '%03d' $((mw % 1000))) W"
