# DeX Display Control

A KernelSU module (Magisk-compatible layout) for Samsung DeX on an external USB-C monitor. It lets you
choose the monitor's resolution and refresh rate per monitor, keeps DeX and your apps running at
that rate, and can keep the phone's own screen off while a monitor is connected.

> **Root required.** This module changes display services at runtime (composer properties,
> SurfaceFlinger, DisplayManager, power groups). It has only been tested on one phone (see
> [Tested on](#tested-on)). Use at your own risk.

## What it does

- **Resolution and refresh rate per monitor.** Pick any mode the monitor offers (for example
  1080p at 120 Hz on XREAL glasses, or 1440p at 120 Hz on a 4K monitor). The choice is remembered
  per monitor and per monitor "variant" (the same monitor with a different mode list, such as
  glasses switched to ultrawide) and applied on every connection.
- **DeX follows the monitor.** The DeX desktop size is kept equal to the mode on the cable, so
  switching from 4K to 1440p does not leave DeX zoomed in.
- **Apps run at the monitor's refresh rate.** Without this, Android keeps the phone's inner screen
  as the apps' frame clock, which DeX limits to 60 Hz: a browser on a 120 Hz monitor still drew
  60 fps. The module hands the clock to the monitor (verified with testufo.com: 60 -> 120 fps).
- **Live status page** (KernelSU WebUI): monitor name, refresh rate, the rate DeX runs at, measured
  frames per second, DeX desktop size, DisplayPort link, bandwidth use and pixel clock.
- **Keep phone screen off while a monitor is connected** (switch). Keyboard, notifications and other
  events no longer wake the phone screen; only the side key, unplugging, a restart or an explicit
  command do. The switch is remembered and can always be turned off, also with no monitor attached.
- **Phone screen refresh rate during DeX** (120, 80, 60, 48, 30 or 20 Hz), restored when you unplug.
  Your own refresh rate settings (including ones set by other apps) are saved and put back.
- **Experimental: 4K at 75 Hz** on 4K monitors that accept it, through a custom timing that stays
  within the phone's limits (see [Limits](#limits)).
- **Soft-reboot fix.** On this phone a KernelSU soft reboot left the display composer unable to see
  new monitors until a full reboot; the module restarts the composer during the soft reboot.

## Tested on

| | |
|---|---|
| Phone | Samsung Galaxy Z Fold8 (SM-F971B) |
| Chip | Qualcomm Snapdragon SM8850 (platform `canoe`) |
| Android / One UI | Android 17, One UI 9.0 (build F971BXXU3AZI5, security patch 2026-09-05) |
| Kernel | 6.12.58 GKI (android16-6.12) |
| Root | KernelSU samsung-v2.2 (temporary "jailbreak" root loaded by DFRoot 4.7), Vector/NeoZygisk present |
| Monitors | XREAL One Pro glasses (USB-C); Dell U3225QE 32" 4K 120 Hz (USB-C/Thunderbolt input, DisplayPort Alt Mode) |

Detailed results: [docs/TESTING.md](docs/TESTING.md). How it works and what was found on the way:
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Install

1. Download `dex-display-control-v2.0.0.zip` from the [releases](../../releases).
2. KernelSU Manager > Modules > Install from storage, pick the zip.
3. Reboot (or start it once with `su -c 'sh /data/adb/modules/fold-display/service.sh'`).
4. KernelSU Manager > Modules > DeX Display Control > open the WebUI.

Uninstalling through KernelSU Manager restores the phone screen refresh rate, removes the mode
override, gives the apps' frame clock back to the phone and wakes the phone screen.

## Use

- **Resolution and refresh rate:** tap a mode. The monitor reconnects (DeX returns after 10-15 s).
  "Use the monitor's default" forgets the choice for this monitor.
- **If the DeX desktop is zoomed or cropped** (for example after choosing a resolution in Samsung's
  own DeX settings), the page shows a warning and a "Match the DeX desktop to the monitor" button.
- **Phone screen switch:** turn it on, and the phone screen goes off while DeX runs on the monitor.
  Press the side key to see the phone screen; when it turns off again (side key or timeout) it is
  kept off again.
- **Experimental > 4K at 75 Hz:** turn it on for the connected 4K monitor, then unplug and plug the
  monitor back in within 60 seconds and pick 3840 x 2160 @ 75 Hz. It needs that one re-plug on every
  new connection.

### Commands (root shell, Termux with root, adb)

```sh
M=/data/adb/modules/fold-display/display.sh
su -c "sh $M status"                 # everything the page shows, as key=value lines
su -c "sh $M set 2560:1440:120"      # choose a mode for the connected monitor
su -c "sh $M reset"                  # back to the monitor's own default
su -c "sh $M phone on"               # wake the phone screen on purpose
su -c "sh $M phone off"              # phone screen off, DeX keeps running
su -c "sh $M phone-guard off"        # turn the keep-off switch off (escape route)
su -c "sh $M inner-hz 60"            # phone screen refresh while connected (or: off)
```

Termux widget examples: [extras/termux](extras/termux).

### Escape routes for the phone-screen switch

The side key always wakes the phone screen; unplugging the monitor always wakes it; `phone-guard off`
from a shell turns the switch off; disabling the module in KernelSU Manager stops it entirely.

## Limits

- **4K above 75 Hz is not possible over USB-C on this phone.** The DisplayPort output is limited to
  a 675 MHz pixel clock (device tree `qcom,max-pclk-frequency-khz`). 4K at 120 Hz needs about
  1100 MHz, 4K at 90 Hz about 800 MHz. Lower bit depth or compression does not help: they reduce
  link bandwidth, not the pixel clock, and Samsung keeps DSC off. The limit can only be lowered at
  runtime, not raised.
- **Switching modes needs a short reconnect.** SurfaceFlinger never changes an external display's
  mode after it connects, so every change reconnects the display.
- **Experimental 4K 75 Hz** uses 8-bit colour (10-bit at 4K 60 Hz) and a slightly shorter vertical
  blanking than the CVT standard (412 us). It worked cleanly on the Dell U3225QE; other monitors may
  reject it. The custom EDID is written to Qualcomm's DisplayPort debugfs (mounted on demand).
- **Not yet verified:** that clearing the custom EDID on unplug works on Samsung's kernel (until
  then, reboot before plugging in a different monitor after using 4K 75 Hz), the side key with the
  phone-screen switch, and monitors that change their own EDID (XREAL ultrawide). See
  [docs/TESTING.md](docs/TESTING.md).

## License

MIT, see [LICENSE](LICENSE).
