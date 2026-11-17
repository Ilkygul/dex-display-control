# How it works

Everything below was found on a Galaxy Z Fold8 (SM8850, One UI 9 / Android 17). Other Qualcomm
Galaxy phones probably behave the same; that is not verified.

## The display path

```
Monitor --DP Alt Mode-- Samsung secdp / Qualcomm DP driver (kernel)
        -- Qualcomm display composer (vendor.qti.hardware.display.composer)
        -- SurfaceFlinger -- DisplayManager -- DeX / apps
```

## Choosing the output mode

- The **composer** picks the mode once, when the display connects: the EDID's preferred mode,
  unless the property `vendor.display.hdmi_cfg_idx` holds `width:height:fps:format` (parsed by
  `HWTVDRM::GetConfigIndex` in `libsdmdal.so`). Any other value - for example a plain index - makes
  that parser overflow and the composer abort on every connect, so the module validates the value.
  A monitor that does not offer the exact mode falls back to its first mode.
- **SurfaceFlinger** never changes an external display's mode after it connects:
  `setDesiredMode` checks the connection type and returns for External displays ("Attempted to set
  desired mode for external display"). Android's own `set-user-preferred-display-mode` therefore
  does nothing for the cable.
- So a change = set the property, then reconnect: `echo off`, then `echo detect` to
  `/sys/class/drm/card0-DP-1/status`. The composer rebuilds the display with the new mode.

## Keeping DeX in step

DisplayManager stores a **user preferred mode** per display (DeX writes one on first connect) and
sizes the DeX desktop from it. If it differs from the cable's mode, DeX is zoomed or cropped. The
module sets it to the same mode (`cmd display set-user-preferred-display-mode W H HZ <id>`) before
reconnecting; DisplayManager reads it again when the display is added back.

## The apps' frame clock (why apps drew 60 fps on a 120 Hz monitor)

Apps get vsync from SurfaceFlinger's **pacesetter** display. In DeX that stayed the phone's inner
panel, which DeX limits to 60 Hz. `ISurfaceComposer.forcePacesetter` (`service call
SurfaceFlingerAIDL 84 i64 <display id>`; 85 resets) makes the monitor the pacesetter. SurfaceFlinger
drops it whenever it re-adds a display, so the module re-checks every 30 s while connected.

## Phone screen

The phone's displays are in power group 0, the monitor in its own group. `cmd power sleep
--display-id 0` turns off only the phone; DeX keeps running and no lock screen appears. The guard
watches `/sys/class/drm/card0-DSI-1/dpms` and `DSI-2/dpms` and reads the side key
(`/dev/input/event4`, `pmic_pwrkey`) with `getevent` without grabbing it, so the key keeps all its
normal functions.

## Soft reboot

A KernelSU soft reboot stops SurfaceFlinger and zygote but leaves the composer running, and a
composer that outlives its SurfaceFlinger ignores new hotplugs. The module's `post-fs-data.sh` runs
in ksud's soft-reboot window (after "stop", before "start") and restarts the composer there. A bare
`setprop ctl.restart` of the composer also restarts SurfaceFlinger and zygote, but skips ksud's
module stages, so Vector/Zygisk modules would not come up.

Note: many framework restarts in a short time trip Android's RescueParty (a full reboot), and with
RescueParty disabled the next observer rolled back the Google Play system update. Space tests out.

## Sources that are not live

`/sys/class/dp_sec/dp_error_info` (Samsung) kept the previous monitor's name, mode and link after a
different monitor was plugged in. The module reads names and EDIDs from the DRM connector, modes from
SurfaceFlinger, and the link from the kernel's `dp_panel_resolution_info` line, captured right after
each connect (the kernel log ring buffer only holds about 90 seconds on this phone).

## Limits of the DisplayPort output

- Pixel clock: 675 MHz (`qcom,max-pclk-frequency-khz`). Qualcomm's debugfs `max_pclk_khz` accepts
  only lower values ("org: 675000").
- Link: HBR2 x4 by default (`max_bw_code` 20); HBR3 can be enabled in debugfs, but without a higher
  pixel clock it gains nothing. DSC and FEC are off.
- Mode table: Samsung's secdp driver keeps a resolution table, but modes outside it (1600x1200) were
  still offered, so it does not act as a strict filter.

## Experimental 4K 75 Hz

Qualcomm's DP debugfs (`/sys/kernel/debug/drm_dp/edid`, debugfs mounted on demand) accepts a
replacement EDID as hex text and uses it at the next real hotplug. The module copies the monitor's
EDID and replaces its serial-number (or dummy/text) descriptor with a 3840x2160 timing at 655.35 MHz
(the most a standard timing descriptor can hold): htotal 3920, vtotal 2229, 75.0 Hz. It only does
this for monitors that offer 4K 60 Hz and whose range limits allow 75 Hz and at least 656 MHz.

- Writing invalid hex makes the kernel handler pass NULL, which clears the custom EDID (per
  Qualcomm's public `dp_debug.c`). Writing a short valid string instead creates a 0-byte custom EDID
  that the next hotplug would parse - never do that.
- Writing to `hpd` (simulated hotplug) did not reconnect on Samsung's driver, so a real re-plug is
  needed after arming.
- The custom EDID would apply to any monitor plugged in next, so it is armed only for 60 seconds
  for a re-plug of the same monitor, and cleared on every disconnect.
