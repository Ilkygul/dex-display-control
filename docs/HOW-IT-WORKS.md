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

- **Link bandwidth is the limit.** `dp_display_validate_link_clock` rejects modes above the link's
  payload: 4 lanes x HBR2 = 17.28 Gbit/s after 8b/10b coding. Pixel clock x bits per pixel must fit,
  which is why 4K 60 Hz runs at 10-bit but 5120x2160 at 60 Hz and 4K 75 Hz run at 8-bit.
- **HBR3 is not reachable.** Qualcomm's debugfs accepts `max_bw_code` and `link_bw_code` 30 (HBR3),
  but Samsung's driver still trains `bw_code` 20 (HBR2). One re-plug with HBR3 forced fell back to
  2 lanes; the defaults (20 / 0) were restored.
- **Pixel clock:** the device tree says 675 MHz (`qcom,max-pclk-frequency-khz`, debugfs
  `max_pclk_khz` "org: 675000", can only be lowered), but the LG ran at 704 MHz: the engine handles
  two pixels per clock, so the bandwidth check is what bites.
- DSC and FEC are off. Lanes: the kernel may fall back to 2 lanes (`lane_count_down_shift`), which
  halves the bandwidth; `dp_debug` in debugfs shows `num_lanes`.
- Mode table: Samsung's secdp driver keeps a resolution table, but modes outside it (1600x1200) were
  still offered, so it does not act as a strict filter.

## Software re-plug

Samsung's `/sys/class/dp_sec/dex` accepts `ExtDispOff,1` and `ExtDispOff,0` (secdp_extdisp_off/on).
Off then on is a full re-plug in software: the link is trained again and the EDID read again. The
module uses it for the experimental timing and its repair. It marks the window with
`extdisp.off`, so if it is ever interrupted the watcher switches the output back on at its next
start. Our own re-plugs are marked with `replug.busy` so the watcher does not treat them as unplugs.
Writing `hpd` in Qualcomm's debugfs does nothing on Samsung's driver.

## Bit depth

Qualcomm's DP driver picks the deepest colour that fits the link, starting at the monitor's maximum
(at most 30 bpp, `max_bpp` in debugfs) and stepping down by 6 to 18 bpp (6-bit). That is why 4K
60 Hz runs at 10-bit, 5120x2160 at 60 Hz at 8-bit, and the extra 5120x2160 70-80 Hz rates at 6-bit.

## Experimental DSC (Display Stream Compression)

Qualcomm's DP driver supports DSC 1.2 and FEC, but on this phone both are switched off
(`dsc_feature_enable` and `fec_feature_enable` in `/sys/kernel/debug/drm_dp`, both `N`). Set to 1,
the next connect reads the monitor's DSC capabilities from its DPCD; the kernel log then shows
`secdp_show_sink_caps: DSC version: 1.2(support:1)`. Modes are then validated at 8 bits per pixel on
the link, and the pixel-clock check uses a quarter of the clock, so 5120x2160 up to 120 Hz passes.

What the phone does not check is the monitor's decoder: `peak_throughput` (Mpixel/s per slice) from
its DPCD. With 4 slices at 5120 wide, the LG's 120 Hz needs 355 per slice against a limit of 340 and
stays black. The module keeps its own extra rates within 96 % of that limit, and every experimental
mode change has to be confirmed (or it goes back by itself).

The switches are global and reset at boot. The module remembers per monitor what was decided
(`/data/adb/fold-display/dsc/<id>`: `peak=<N>` on, `off`, or `none` for no DSC) and sets the
switches on every connect, with one software re-plug (shared with the extra rates' re-plug when both
are on). With the `dsc_auto` setting, a monitor without a record is checked at its first connect;
if it supports DSC the user must keep it within 45 s, otherwise it is recorded as `off`.

The decoder limit is applied generically: a mode is too fast when its pixel clock (from the
kernel's `edid_modes` list) divided by 4 slices exceeds the monitor's limit. Such modes are refused
by `set`, and on connect the fastest mode at the same resolution that fits is used instead.

## Colour depth per mode

The page shows, per mode, what the kernel will send: from the monitor's maximum (EDID byte 20,
capped by `max_bpp` 30) down in steps of 6 bits per pixel until pixel clock x bits fits the link;
with DSC the maximum, compressed. Worked out after every connect from `edid_modes` and the live link.

## One action at a time

Commands, the confirmation timer and the watcher's connect handling all reconnect the monitor. A
lock (`/data/adb/fold-display/op.lock`, a directory, created atomically) makes them wait for each
other. Every 30 s the watcher also checks that the DSC switches, the extra rates and the mode
override match the monitor, and applies them again if a reconnect was missed.

The display chip has 8 DSC encoders; the inner screen uses 2, the monitor with DSC 2 more and 4
layer mixers (1280 pixels wide each). The DP pixel clock is lower with DSC (a quarter instead of
half the mode's clock), and the measured cost was about 0.1 W.

## Experimental extra refresh rates

Qualcomm's DP debugfs (`/sys/kernel/debug/drm_dp/edid`, debugfs mounted on demand) accepts a
replacement EDID as hex text; while one is set, the kernel uses it instead of reading the monitor.

The module picks the monitor's native timing: the largest detailed timing in its EDID, the one
closest to 60 Hz (base block, CTA and DisplayID type I timings are all looked at; the LG lists
3440x1440 first). It keeps that timing's blanking and sync and only raises the pixel clock, in steps
of 70, 75, 80, 85, 90, 100, 110, 120, 144 and 165 Hz:

- only above what the monitor already offers at that resolution,
- only up to the maximum vertical rate in the monitor's range limits,
- only if pixel clock x 18 bits fits within 98 % of the live link (link rate x lanes x 8, read from
  `dp_debug`), or, with DSC on, pixel clock x 8 bits fits and pixel clock / slices stays within 96 %
  of the monitor's decoder limit,
- only rates the EDID does not already have at that resolution.

Up to five rates go into a new DisplayID 1.2 extension block (type I timings), appended to the
monitor's own EDID (its blocks are kept as they are; the extension count and checksum are updated).
A software re-plug applies it. The DRM EDID parser reads type I timings from any DisplayID block.

The 4K 75 Hz test on the Dell (v2.0/v2.1) used a different, tighter timing in the base block (655.35
MHz, the most a base-block timing can hold). The new method can go beyond that clock because
DisplayID timings have a 24-bit clock field.

### Clearing it

- On Samsung's kernel, writing invalid hex to `edid` did **not** clear it (a Dell's custom EDID was
  later used for an LG). Writing a short valid string creates a 0-byte custom EDID - never do that.
- What works: `echo 0 > drm_dp/sim` (debug sim off, which drops the custom EDID) while the output is
  off: with nothing connected, or between `ExtDispOff,1` and `ExtDispOff,0`.
- The module remembers a checksum of the custom EDID it wrote. At every connect it compares the EDID
  the kernel read: if it is the custom one and it is not meant for this monitor, it clears it with a
  software re-plug and checks again. So a leak is repaired by itself, without unplugging.
- When the rates are removed while one of them is in use, the composer override is pointed at the
  native mode first: the LG prefers 3440x1440, so "no override" would land there.
