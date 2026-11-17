# Test results

All tests on 2026-11-17 on one phone. Methods: the module's own `status` output, SurfaceFlinger and
DisplayManager dumps, the kernel's DisplayPort log line at mode set, and testufo.com in Samsung
Internet on DeX.

## Hardware and software

| | |
|---|---|
| Phone | Samsung Galaxy Z Fold8, SM-F971B |
| Chip | Qualcomm Snapdragon SM8850 (`canoe`), Adreno 840 |
| Software | Android 17, One UI 9.0, build F971BXXU3AZI5 (security patch 2026-09-05), kernel 6.12.58 GKI |
| Root | KernelSU samsung-v2.2, temporary root loaded after boot by DFRoot 4.7 |
| DisplayPort | Qualcomm DP with Samsung secdp driver; max pixel clock 675 MHz, link capped at HBR2 x4 by default, DSC/FEC off |
| Monitor 1 | XREAL One Pro AR glasses (EDID modes 1920x1080 at 60/90/120 Hz, preferred 90 Hz) |
| Monitor 2 | Dell U3225QE 31.5" 4K 120 Hz, connected by USB-C into its Thunderbolt/USB-C input (DisplayPort Alt Mode) |

## Results

| Test | Monitor | Result |
|---|---|---|
| Default connection | XREAL One Pro | Starts at the EDID's preferred 1080p 90 Hz |
| Choose 1080p 120 Hz | XREAL One Pro | Works: kernel `1920x1080@120fps 24bpp 297000Khz`, SurfaceFlinger 120 Hz, picture OK |
| Apps' frame rate at 120 Hz without the module's pacesetter fix | XREAL One Pro | testufo.com showed 60 fps (inner screen is the frame clock, DeX caps it at 60 Hz) |
| Same with the fix | XREAL One Pro | testufo.com 120 fps |
| Switch 120 -> 60 -> 120 Hz from the page | XREAL One Pro | Works, about 10-15 s per switch, no crash |
| 4K 60 Hz | Dell U3225QE | Works: `533250Khz 30bpp`, 4 x HBR2 (93% link use), DeX 3840x2160 |
| 1440p 120 Hz | Dell U3225QE | Works: `497750Khz 30bpp`, 4 x HBR2 (86%), DeX 2560x1440 |
| Switch 4K 60 -> 1440p 120 before the DeX fix | Dell U3225QE | DeX stayed 3840x2160 on a 2560x1440 signal (zoomed): DisplayManager kept DeX's preferred mode |
| Same with the fix | Dell U3225QE | DeX follows: 3840x2160 / 2560x1440, about 6 s per switch |
| Monitor name after swapping monitors | XREAL -> Dell | Correct ("DELL U3225QE") after replacing a stale Samsung sysfs source |
| Experimental 4K 75 Hz (custom EDID timing) | Dell U3225QE | Works: `3840x2160@75fps 24bpp 655350Khz`, 4 x HBR2, picture clean, testufo.com 75 fps |
| 4K 90 / 100 Hz (DisplayID timings + HBR3) | Dell U3225QE | Not possible: needs 811 / 906 MHz pixel clock, limit 675 MHz can only be lowered |
| 4K 120 Hz | Dell U3225QE | Not possible: ~1098 MHz pixel clock and more bandwidth than HBR3 without DSC |
| Phone screen refresh 30 Hz during DeX | Dell U3225QE | Works: SurfaceFlinger inner render 30 Hz; previous 120/120 restored on "Don't change" |
| Keep phone screen off: unwanted wake | Dell U3225QE | `cmd power wakeup` while guarded: turned off again within 0.5 s |
| Keep phone screen off: wake on purpose (`phone on`, Termux button) | Dell U3225QE | Stays on; guarded again after `phone off` |
| Keep phone screen off: switch off | Dell U3225QE | Phone screen wakes |
| Sleep only the phone's display group | Dell U3225QE | DeX keeps running, no lock screen, monitor stays the frame clock |
| Soft reboot (KernelSU) with a monitor | Dell / XREAL | Before the fix: monitors not detected until a full reboot. With the composer restart in the soft-reboot window: monitor detected, Vector active |

## Cost on the phone (measured)

| Part | Memory | CPU | When |
|---|---|---|---|
| Watcher | 3.7 MB | 0.01 s per 30 s | always (one sysfs read every 3 s) |
| Phone-screen guard | ~2 MB | one sysfs read every 0.5 s | only with the switch on and a monitor connected |
| Status page | - | ~50 ms per refresh, once a second | only while the page is open and visible |

## Not yet tested

- The side key with "Keep phone screen off" on.
- Clearing the experimental custom EDID on unplug (Samsung's kernel may differ from Qualcomm's
  public source). Until verified: reboot before plugging in a different monitor after using 4K 75 Hz.
- XREAL "ultrawide" mode (a monitor that changes its own EDID without unplugging): handled in code
  (EDID checksum watch, per-variant profiles), not yet tried.
- The soft-reboot composer restart as part of the module (it was tested as a stand-alone
  `/data/adb/post-fs-data.d` script with the same code).
- Any other phone, chip, One UI version, or Magisk instead of KernelSU.
