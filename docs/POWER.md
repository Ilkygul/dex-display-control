# Power use

What the display modes cost on the phone, how it was measured, and how the live reading on the
status page works. Galaxy Z Fold8 (SM8850), LG UltraFine 40U990A at 5120x2160, 2026-11-17.

## Results

Whole phone, DeX showing a still screen, about 50 seconds per state:

| State | Colour | Whole phone | vs 60 Hz |
|---|---|---|---|
| 5120x2160 at 60 Hz, no DSC | 8-bit | 2.03 W | - |
| 5120x2160 at 60 Hz, DSC | 10-bit | 2.15 W | +0.12 W |
| 5120x2160 at 80 Hz, no DSC (extra rate) | 6-bit | 2.37 W | +0.34 W |
| 5120x2160 at 110 Hz, DSC (extra rate) | 10-bit | 3.04 W | +1.01 W |

- **DSC itself costs about 0.1 W.** Compression runs in fixed-function blocks of the display chip;
  the CPU and GPU do nothing for it. The DisplayPort pixel clock is even lower with DSC (a quarter
  of the mode's clock instead of half), and the link runs at HBR2 either way.
- **The refresh rate is what costs: about 17 mW per Hz** (60 to 80 Hz: +0.34 W; 60 to 110 Hz with
  DSC: +0.89 W). Every refresh the display engine reads the whole frame from memory (5120x2160x4
  bytes; compressed in memory with UBWC) and sends it out.
- **Moving content costs more.** With motion, apps and DeX also draw more frames per second, so the
  GPU works harder in proportion (110 vs 80 Hz: about 37 % more frames).
- These are single runs; differences of about 0.1 W are within the noise.

What it means in practice: when the monitor powers the phone over USB-C (the battery shows "Not
charging" or "Charging"), the extra power comes from the monitor, not the battery, and adds a
little heat. On battery, 60 Hz is the most economical.

## Under load

WebGL Aquarium (5000 fish) on DeX at 5120x2160 110 Hz with DSC: 6-9 W with the temperature
override on (GPU and CPU at full speed), 4.6-5.2 W with Samsung's limits (GPU down to 160 MHz, fast
cores to 0.88 GHz, about half the frames). Details in [TESTING.md](TESTING.md).

## How it was measured

The LG powers the phone over USB-C, so the battery current is about zero and says nothing. For the
table, Samsung's slate mode (`/sys/class/power_supply/battery/batt_slate_mode` = 1) paused the
charging input so the battery supplied everything; the battery current
(`batt_current_ua_now`, sampled every 2 s for 50 s, after 20 s to settle) times the battery voltage
gave the whole phone's power. Slate mode was switched off again afterwards.

## Live reading (status page)

The battery's fuel gauge (MAX77775) also measures the **system current** (ISYS): everything the
phone draws, whether it runs on its battery or on external power. Samsung's battery driver reports
it as `power_now` (instant) and `power_avg` (averaged by the fuel gauge), in mA; `voltage_sys` is the
system voltage in mV. Phone power = `power_now` x `voltage_sys`.

Checked against the slate-mode results: 110 Hz with DSC 700 mA x 4.53 V = 3.17 W (slate mode:
3.04 W); 60 Hz with DSC 519 mA x 4.53 V = 2.35 W (2.15 W). It reads a little higher than the
battery-side measurement (it includes the conversion from the input), but it follows every change.

The page reads these two values once a second **only while it is open and visible**, and keeps a
30-second average in its own memory. Closed or hidden, nothing is read or stored. Reading them
costs two small sysfs reads inside the status call the page makes anyway.

From a shell, [extras/termux/power.sh](../extras/termux/power.sh) averages the same reading over a
chosen time, to compare two settings yourself.
