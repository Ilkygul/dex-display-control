# Changelog

## v2.6.0 (2026-11-17)

- Page: phone screen refresh rate and measured fps with its setting; temperatures (skin, chip,
  battery) and Android's thermal status; how far heat holds the GPU and CPU back.
- Optional "60 Hz while the phone is hot" (`thermal-fallback on|off`): lowers a fast monitor to
  60 Hz while the GPU is held back hard, and goes back once the phone has cooled down.

## v2.5.1 (2026-11-17)

- Fix (found in a reboot test): right after boot the extra rates were checked before Android had
  added the display again, judged "not accepted" and removed; the check now waits up to 20 s.
- The last mode per monitor is remembered and requested before any re-plug at connect, so a monitor
  comes back in its mode directly (the LG no longer passes through its own 120 Hz, which is too fast
  for its decoder with DSC).

## v2.5.0 (2026-11-17)

- Live whole-phone power on the status page (fuel gauge system current x system voltage), with a
  30-second average; only read while the page is open and visible. Also shown with no monitor.
- docs/POWER.md: the measured cost of each mode, how it was measured, and how the live reading works.
- extras/termux/power.sh: average whole-phone power over N seconds from a shell.

## v2.4.0 (2026-11-17)

- DSC for any monitor: optional automatic check of monitors not seen before (`dsc auto-on`), with a
  45 s keep-or-undo; per-monitor record on / off / no DSC.
- Generic decoder limit: modes too fast for a monitor's DSC decoder are refused, avoided on connect
  and crossed out on the page.
- Colour depth per mode on the page (6/8/10-bit, DSC), and the current colour depth.
- Watcher checks every 30 s that DSC, extra rates and the mode match the monitor (missed reconnects).
- A lock keeps reconnecting actions from running at the same time.

## v2.3.0 (2026-11-17)

- Experimental compression (DSC) per monitor: `dsc on|off`. Detects support and the decoder limit,
  re-applied on every connect. LG 40U990A: 5120x2160 at 100 and 110 Hz in 10-bit colour.
- Extra rates take DSC into account (8 bits per pixel on the link, within the decoder's per-slice
  limit) and fill gaps between the monitor's own rates (LG with DSC: 75/80/90/105/110 Hz).
- Confirm or go back: with an experimental option on, a new mode must be kept within 30 s or the
  previous one returns by itself (`confirm`, `confirm back`; a bar on the page).
- Uninstall clears a custom EDID and the DSC switches the way the module does (output off first).
- Measured power: DSC about 0.1 W; each extra Hz about 17 mW.

## v2.2.0 (2026-11-17)

- Experimental extra refresh rates replace the 4K 75 Hz option: faster versions of the monitor's own
  native mode, worked out from its EDID (range limits) and the live link, in an added DisplayID
  block. Tested: LG 40U990A at 5120x2160 70/75/80 Hz (6-bit), clean picture at 80 Hz.
- Remembered per monitor and applied again on every connection. `extra on|off` (`exp75` still works).
- Removing the rates goes back to the native mode in one reconnect.
- Mode commands wait for a reconnect in progress instead of failing on it.
- Page: added rates are marked "6-bit" in the mode list.

## v2.1.0 (2026-11-17)

- Experimental 4K 75 Hz without unplugging: the module re-plugs the monitor in software (Samsung's
  `ExtDispOff`), and turning it off is immediate.
- Automatic repair: a custom EDID found on the wrong monitor is cleared at connect, and the monitor
  read again with its own EDID. Clearing now uses the debug-sim switch while the output is off,
  since writing invalid hex does not clear it on Samsung's kernel.
- Watcher ignores the module's own reconnects, and switches the output back on if a software re-plug
  was interrupted.
- Fix: the watcher and the phone-screen guard could be killed when the command that started them
  exited (they now run in their own session).
- Tested on the LG UltraFine 40U990A (5120x2160 at 60 Hz). Docs corrected: the limit is the link's
  17.28 Gbit/s (HBR2 x4), not the 675 MHz pixel clock.
- Texts no longer refer to other refresh rate apps.

## v2.0.0 (2026-11-17)

First public release.

- Resolution and refresh rate per monitor and per monitor variant, applied on every connection.
- DeX desktop size kept equal to the cable's mode.
- Apps' frame clock handed to the monitor (apps run at the monitor's refresh rate in DeX).
- Live status page: monitor, refresh rate, DeX rate, measured frames per second, DP link,
  bandwidth, pixel clock.
- Keep the phone screen off while a monitor is connected (side key, unplug, restart or command wake it).
- Phone screen refresh rate during DeX, restored on unplug.
- Experimental 4K 75 Hz custom timing.
- Composer restart during a KernelSU soft reboot (external displays work after a soft reboot).
