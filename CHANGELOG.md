# Changelog

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
