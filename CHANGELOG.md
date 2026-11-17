# Changelog

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
