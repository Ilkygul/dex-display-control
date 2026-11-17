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
- **Live panel** on the status page (right on a wide DeX window, on top on the phone): monitor Hz
  and measured fps, phone screen, whole-phone power with a 60-second graph, temperatures with
  coloured bars and a marker at your override limit, GPU and CPU clocks with a marker at the
  maximum allowed right now (red when heat protection holds them back), GPU load, and the heat
  control state. Only values that change; green / orange / red show at a glance what is fine.
- **Live status page** (KernelSU WebUI): monitor name, refresh rate, the rate DeX runs at, measured
  frames per second, DeX desktop size, colour depth, **whole-phone power** (live and 30 s average),
  **the phone screen's refresh rate and frames per second**, **temperatures and how far heat holds
  the GPU and CPU back**, DisplayPort link, bandwidth use and pixel clock. It only measures while it
  is open and visible.
- **Experimental temperature override** (switch): for a phone lying untouched next to a monitor. Samsung slows
  the GPU and CPU from an estimated skin temperature of about 43-45 °C, a limit meant for a phone in
  the hand. The override keeps them at full speed while a monitor is connected, with your own, higher
  limits: battery 41/45/50 °C, board near the chip 80/90/100 °C, skin estimate 56/65 °C or ignored.
  Above a limit Samsung's limits come back until it has cooled down; the kernel's own chip
  protection always stays active.
- **Bring DeX back after a reconnect** (switch, on by default): if Samsung's DeX does not take the
  monitor back after a mode change (it then stays in screen mirroring), the module reconnects once
  more. Only when DeX was running before; screen mirroring by choice is left alone.
- **60 Hz while the phone is hot** (switch). When Samsung's heat protection holds the GPU back hard,
  a fast monitor cannot get its fps anyway; the monitor then runs 60 Hz until the phone has cooled
  down, and goes back to your choice by itself.
- **Keep phone screen off while a monitor is connected** (switch). Keyboard, notifications and other
  events no longer wake the phone screen; only the side key, unplugging, a restart or an explicit
  command do. The switch is remembered and can always be turned off, also with no monitor attached.
- **Phone screen refresh rate while a monitor is connected** (60 or 120 Hz), for the phone screen
  only (a preferred mode on display 0), restored when you unplug. Android's global refresh settings
  are not used: they also held apps on the monitor at 60 fps.
- **Mode switches by reconnecting are handled:** monitors that switch mode by disconnecting for a
  moment (XREAL ultrawide, input or menu changes) keep all settings if they are back within 8 s;
  each mode is its own variant with its own saved choice.
- **Experimental: extra refresh rates.** Adds faster versions of the monitor's own native mode, as
  far as the phone's link allows (see [Limits](#limits)): for example **5120x2160 at 70, 75 and
  80 Hz** on an LG 40U990A, which offers 60 Hz at most over this phone. Rates that do not fit at
  8-bit colour run at 6-bit. Remembered per monitor and applied again on every connection; the
  monitor reconnects by itself, nothing to unplug.
- **Experimental: compression (DSC), for any monitor that supports it.** The phone's display chip
  can compress the picture (Display Stream Compression), but Samsung leaves it off. With "Check new
  monitors automatically" on, every monitor is checked once when it first connects; DSC is switched
  on where supported (you keep it with one tap). On an LG 40U990A 5120x2160 runs at **100 and
  110 Hz in 10-bit colour**. Modes too fast for a monitor's DSC decoder are refused and avoided.
- **Your own refresh rates** (Experimental): pick any resolution of the monitor and type a rate;
  the module builds it from that resolution's own timing. Extra rates come along automatically
  when DSC is on (up to the room the EDID leaves; the kernel reads at most 4 EDID blocks).
- **Nothing is blocked:** modes that may be too fast for a monitor's decoder, or that did not work
  before, are marked ⚠ but stay clickable; the 30-second "keep this mode" check protects you, and a
  mode you keep is no longer marked.
- **Colour depth per mode.** Every mode in the list shows the colour depth the phone will send
  (6-, 8- or 10-bit, and whether it is compressed), worked out the way the kernel picks it.
- **Confirm or go back.** While an experimental option is on, a new mode must be confirmed within
  30 seconds or the previous one comes back by itself, so a black monitor fixes itself.
- **Repairs itself.** If a custom timing ever ends up on a monitor it was not made for, the module
  notices at connect and has the monitor read again with its own data, without unplugging.
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
| Monitors | XREAL One Pro glasses (USB-C, normal and ultrawide); Dell U3225QE 32" 4K 120 Hz (USB-C/Thunderbolt input); LG UltraFine 40U990A 40" 5K2K (Thunderbolt 5 input). All over DisplayPort Alt Mode |

Detailed results: [docs/TESTING.md](docs/TESTING.md). How it works and what was found on the way:
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). What the modes cost in power and how it was measured:
[docs/POWER.md](docs/POWER.md).

## Install

1. Download `dex-display-control-v2.11.2.zip` from the [releases](../../releases).
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
- **Experimental > Compression (DSC):** either switch on "Check new monitors automatically" (a
  monitor not seen before is checked when it connects), or tap "Turn compression on for this
  monitor". Either way the module reads the monitor's DSC support and decoder limit (about 15 s,
  one or two reconnects), switches it on, and asks you to keep it within 45 s; otherwise it goes off
  again for that monitor. The decision is remembered per monitor (on, off, or no DSC).
- **Mode list:** "10-bit DSC", "8-bit", "6-bit" show the colour depth per mode; "+" marks a rate
  added by the module; a crossed-out mode is too fast for the monitor's DSC decoder.
- **Keep this mode?** After choosing a mode with an experimental option on, a bar asks to keep it.
  Without an answer the previous mode returns after 30 seconds (plus the reconnect time).
- **Experimental > Extra refresh rates:** tap "Add extra refresh rates for this monitor". The module
  works out what fits, the monitor reconnects once (about 10 s), and the new rates appear in the list
  marked "6-bit" (or "added" when they fit at 8-bit). Pick one. From then on they are added on every
  connection of that monitor (one extra reconnect). "Remove extra refresh rates" goes back to the
  monitor's own data and its native mode. If the monitor stays black on an added rate, pick another
  rate or remove them.

### Commands (root shell, Termux with root, adb)

```sh
M=/data/adb/modules/fold-display/display.sh
su -c "sh $M status"                 # everything the page shows, as key=value lines
su -c "sh $M set 2560:1440:120"      # choose a mode for the connected monitor
su -c "sh $M reset"                  # back to the monitor's own default
su -c "sh $M phone on"               # wake the phone screen on purpose
su -c "sh $M phone off"              # phone screen off, DeX keeps running
su -c "sh $M phone-guard off"        # turn the keep-off switch off (escape route)
su -c "sh $M inner-hz 60"            # phone screen refresh while connected: 60|120 (or: off)
su -c "sh $M extra on"               # experimental extra refresh rates for this monitor (or: off)
su -c "sh $M dsc on"                 # experimental compression (DSC) for this monitor (or: off)
su -c "sh $M dsc auto-on"            # check new monitors for DSC when they connect (or: auto-off)
su -c "sh $M extra-add 3840:2160:100" # your own refresh rate for a resolution (extra-del removes it)
su -c "sh $M forget-failed"          # forget modes that were not kept on this monitor
su -c "sh $M thermal-fallback on"    # 60 Hz while the phone is hot (or: off)
su -c "sh $M temp-override on"       # experimental temperature override (or: off)
su -c "sh $M dex-recover off"        # do not bring DeX back after a reconnect (or: on)
su -c "sh $M temp-limit bat 45"      # override limits: bat 41|45|50, ap 80|90|100, skin 56|65|off
su -c "sh $M confirm"                # keep a new experimental mode (confirm back: undo now)
```

Termux widget examples and a power meter for the shell (`power.sh`, average over N seconds):
[extras/termux](extras/termux).

### Escape routes for the phone-screen switch

The side key always wakes the phone screen; unplugging the monitor always wakes it; `phone-guard off`
from a shell turns the switch off; disabling the module in KernelSU Manager stops it entirely.

## Limits

- **The DisplayPort link carries at most 17.28 Gbit/s of pixels.** The phone trains the link at
  HBR2 with 4 lanes (5.4 Gbit/s per lane, 8b/10b coding), and the kernel rejects any mode whose
  pixel clock x bits per pixel exceeds that. Samsung's driver always trains HBR2; HBR3 (8.1 Gbit/s
  per lane) could not be enabled (debugfs accepts it but the link stays HBR2). DSC is off unless you switch it on (below).
  - 5120 x 2160 at 60 Hz fits at 8-bit colour (16.9 Gbit/s, 98 %): the most the LG 40U990A gets.
  - 4K at 60 Hz fits at 10-bit (16.0 Gbit/s); 1440p at 120 Hz at 10-bit (14.9 Gbit/s).
  - 5120 x 2160 at 80 Hz fits at 6-bit colour (16.9 Gbit/s, 98 %): the experimental extra rates.
    The kernel drops to 6-bit (18 bpp) by itself when 8-bit does not fit.
  - The LG's own 85/100/120 Hz timings need 18.2/21.5/25.6 Gbit/s even at 6-bit, so the phone hides
    them; the module adds tighter ones that fit. The 4:2:0 4K 120 Hz mode was not offered either.
  - 4K at 75 Hz fits at 8-bit with a tight timing (15.7 Gbit/s), tested on the Dell U3225QE.
  - **With DSC** (compressed to 8 bits per pixel on the link) the link is no longer the limit; the
    monitor's DSC decoder is. The LG reports 340 Mpixel/s per slice and the phone uses 4 slices at
    5120 wide: 110 Hz (323 per slice) works, the LG's own 120 Hz (355 per slice) leaves it black.
  - Power, whole phone, still DeX screen: 60 Hz 2.03 W, 60 Hz with DSC 2.15 W, 80 Hz 6-bit 2.37 W,
    110 Hz with DSC 3.04 W. DSC itself costs about 0.1 W; each extra Hz about 17 mW. Details:
    [docs/POWER.md](docs/POWER.md).
  - The device tree's 675 MHz pixel clock is not the real limit: the LG runs at 704 MHz.
- **Hubs and docks can halve it.** If the link falls back to 2 lanes (seen once with a re-plug through
  a USB hub), only 8.64 Gbit/s is left and the high modes disappear. The status page shows the lanes;
  re-plugging directly brings 4 lanes back.
- **Switching modes needs a short reconnect.** SurfaceFlinger never changes an external display's
  mode after it connects, so every change reconnects the display.
- **Experimental extra rates** keep the monitor's own native timing and only raise the pixel clock,
  up to the monitor's stated maximum refresh rate. The LG 40U990A showed a clean picture at 80 Hz;
  other monitors may not accept a given rate (then pick another, or remove them). While they are on,
  the phone uses the module's copy of the monitor's data (EDID), so a monitor that changes its own
  EDID while connected is not noticed until it reconnects. The custom EDID is written to Qualcomm's
  DisplayPort debugfs (mounted on demand).
- **Copy protection at too-fast modes:** at the LG's 120 Hz with DSC the copy-protection handshake
  failed (and the picture was black). At 60-110 Hz with DSC it worked.
- **Not yet verified:** DSC and the extra rates on other monitors than the LG (the Dell 4K 75 Hz test used an
  earlier timing), monitors that change their own EDID while connected (XREAL ultrawide), other
  phones. See [docs/TESTING.md](docs/TESTING.md).

## License

MIT, see [LICENSE](LICENSE).
