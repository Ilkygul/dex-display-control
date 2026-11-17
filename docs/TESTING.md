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
| DisplayPort | Qualcomm DP with Samsung secdp driver; link HBR2 x4 (17.28 Gbit/s of pixel data), HBR3 not available, DSC/FEC off |
| Monitor 1 | XREAL One Pro AR glasses (EDID modes 1920x1080 at 60/90/120 Hz, preferred 90 Hz) |
| Monitor 2 | Dell U3225QE 31.5" 4K 120 Hz, connected by USB-C into its Thunderbolt/USB-C input (DisplayPort Alt Mode) |
| Monitor 3 | LG UltraFine 40U990A 40" 5120x2160 (5K2K) 120 Hz, connected by USB-C into its Thunderbolt 5 input (DisplayPort Alt Mode) |

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
| 4K 90 / 100 Hz (DisplayID timings) | Dell U3225QE | Not possible: 19.5 / 21.7 Gbit/s at 8-bit, the link carries 17.28 (HBR2 x4); HBR3 could not be enabled |
| 4K 120 Hz | Dell U3225QE | Not possible: about 26 Gbit/s at 8-bit |
| Default connection | LG 40U990A | 5120x2160 at 60 Hz offered and used; modes up to 5120x2160 at 60, 3440x1440 at 60, 1920x1080 at 120 |
| 5120x2160 at 60 Hz | LG 40U990A | Works: `5120x2160@60fps 24bpp 704180Khz`, 4 x HBR2 (98% link use), DeX 5120x2160, pacesetter on the monitor |
| 5120x2160 above 60 Hz (85/100/120 Hz in the EDID) | LG 40U990A | Not offered: over the link's 17.28 Gbit/s. Forcing HBR3 in debugfs (`max_bw_code`/`link_bw_code` 30) was accepted but the link still trained HBR2 |
| 4K 120 Hz 4:2:0 (in the LG's EDID) | LG 40U990A | Not offered by the phone |
| Pixel clock above the device tree's 675 MHz | LG 40U990A | Works at 704 MHz, so 675 MHz is not the real limit (the DP engine runs two pixels per clock) |
| Link after a re-plug through a USB hub | LG 40U990A | Fell back to 2 lanes once (half the bandwidth); a direct re-plug restored 4 lanes |
| Software re-plug (`ExtDispOff,1` / `,0` on `/sys/class/dp_sec/dex`) | LG 40U990A | Link retrained, EDID read again, picture back in about 10 s; used by the module instead of a physical re-plug |
| Custom EDID left from another monitor (Dell's 4K 75 Hz EDID shown on the LG) | LG 40U990A | Seen before v2.1.0 (clearing by writing invalid hex does not work on Samsung's kernel). v2.1.0: detected at connect and repaired automatically in 8 s (simulated with a marked EDID), 4 lanes and 5120x2160 at 60 kept |
| Custom EDID active, then the monitor disconnects | LG 40U990A | Cleared while disconnected and verified at the next connect: monitor read with its own EDID |
| LG's own 85/100/120 Hz timings (DisplayID) | LG 40U990A | Not offered: 1009/1196/1420 MHz need 18.2/21.5/25.6 Gbit/s even at 6-bit; the link carries 17.28 |
| Extra rates: LG's 60 Hz timing (htotal 5280, vtotal 2222) at a faster clock | LG 40U990A | 70/75/80 Hz offered; 80 Hz runs `938570Khz`, 18 bpp (6-bit), 4 x HBR2 at 98 %; DeX, apps (pacesetter) and the measured frame rate at 80 Hz; picture clean (checked on the monitor) |
| Extra rates: turn on from the module | LG 40U990A | 8 s, rates worked out from the live link and the EDID's range limits (120 Hz max) |
| Extra rates: monitor reconnects | LG 40U990A | Re-applied by itself, saved 80 Hz back after about 20 s |
| DSC on (`dsc_feature_enable`, `fec_feature_enable` in debugfs + software re-plug) | LG 40U990A | Kernel: "DSC version: 1.2(support:1)", FEC on; 2 more DSC encoders in use (8 in the chip, the inner screen uses 2); 5120x2160 at 85/100/120 Hz and 3840x2160 at 120 Hz now offered; 60 Hz runs 10-bit |
| DSC: the LG's own 120 Hz (1420 MHz) | LG 40U990A | **Black screen**, also after re-plugging (the mode was saved). HDCP fell back to 1.x and failed; the driver reset the link once. The LG's decoder limit is 340 Mpixel/s per slice, 4 slices = 355: over it |
| DSC: 100 Hz (LG's timing) and 110 Hz (60 Hz timing at 1290.5 MHz) | LG 40U990A | Picture OK (checked on the monitor), 10-bit, HDCP 2.2 authenticated |
| DSC in the module: `dsc on` | LG 40U990A | Detects support and the 340 limit from the kernel log; extra rates rebuilt with DSC: 75/80/90/105/110 Hz (115 left out: 99 % of the limit) |
| Confirm or go back: 110 Hz confirmed, then 120 Hz not confirmed | LG 40U990A | 120 Hz black, back to 110 Hz by itself after about 40 s |
| Reconnect with the DSC switches off (as after a reboot) | LG 40U990A | DSC switched on, extra rates added, 110 Hz back, in one extra reconnect |
| Automatic check of an unchecked monitor (LG with its DSC record removed) | LG 40U990A | Checked at connect, DSC found (limit 340), keep-bar shown; not kept, so off again after 45 s and the extra rates rebuilt without DSC |
| DSC on from the page, kept; 110 Hz kept; 120 Hz chosen | LG 40U990A | 120 Hz refused: "Too fast for this monitor's DSC decoder"; the list shows it crossed out |
| Colour depth per mode | LG 40U990A | Without DSC: 60 Hz 8-bit, 70-80 Hz 6-bit, 30 Hz 10-bit; with DSC: 10-bit for all (matches the kernel's `bpp` for the modes used) |
| Reconnect missed by the watcher (while it was busy starting) | LG 40U990A | Found within 30 s by the new consistency check (DSC switches, extra rates, mode override) and applied again |
| Two actions reconnecting at once (confirmation timer and watcher) | LG 40U990A | Confused each other before the lock; with the lock they run one after the other |
| Power (whole phone on battery via slate mode, still DeX screen, 50 s average) | LG 40U990A | 60 Hz 2.03 W; 60 Hz DSC 2.15 W; 80 Hz 6-bit 2.37 W; 110 Hz DSC 3.04 W |
| Extra rates: remove while at 80 Hz | LG 40U990A | Back to 5120x2160 at 60 Hz, 8-bit, in one reconnect (the LG's preferred timing is 3440x1440, so the module sets the native mode instead of "no override") |
| Phone screen refresh 30 Hz during DeX | Dell U3225QE | Works: SurfaceFlinger inner render 30 Hz; previous 120/120 restored on "Don't change" |
| Keep phone screen off: unwanted wake | Dell U3225QE | `cmd power wakeup` while guarded: turned off again within 0.5 s |
| Keep phone screen off: wake on purpose (`phone on`, Termux button) | Dell U3225QE | Stays on; guarded again after `phone off` |
| Keep phone screen off: switch off | Dell U3225QE | Phone screen wakes |
| Keep phone screen off: side key | Dell U3225QE | Side key wakes the phone screen; after it turns off again it is kept off |
| Termux / DeX screen buttons with the switch on | Dell U3225QE | Work (they call `display.sh phone on/off`) |
| Sleep only the phone's display group | Dell U3225QE | DeX keeps running, no lock screen, monitor stays the frame clock |
| Soft reboot (KernelSU) with a monitor | Dell / XREAL | Before the fix: monitors not detected until a full reboot. With the composer restart in the soft-reboot window: monitor detected, Vector active |

## Cost on the phone (measured)

| Part | Memory | CPU | When |
|---|---|---|---|
| Watcher | 3.7 MB | 0.01 s per 30 s | always (one sysfs read every 3 s) |
| Phone-screen guard | ~2 MB | one sysfs read every 0.5 s | only with the switch on and a monitor connected |
| Status page | - | ~50 ms per refresh, once a second | only while the page is open and visible |

## Not yet tested

- DSC with other monitors (the automatic check is generic, but only the LG was tried), and 115 Hz on
  the LG. The 4-slice assumption (two DSC encoders, two slices each) comes from the LG at 5120 wide.
- The extra rates on the Dell U3225QE and the XREAL glasses (the XREAL already offers its 120 Hz
  maximum, so nothing would be added).
- XREAL "ultrawide" mode (a monitor that changes its own EDID without unplugging): handled in code
  (EDID checksum watch, per-variant profiles), not yet tried.
- The soft-reboot composer restart as part of the module (it was tested as a stand-alone
  `/data/adb/post-fs-data.d` script with the same code).
- Any other phone, chip, One UI version, or Magisk instead of KernelSU.
