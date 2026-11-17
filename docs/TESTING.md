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
| Full reboot with the LG connected (root loaded by DFRoot, no soft reboot this time) | LG 40U990A | v2.5.0: DSC switched on by itself, but the extra rates were judged "not accepted" 7 s after the re-plug (Android was still adding the display), the LG came up at its own 120 Hz (black with DSC) and fell back to 100 Hz; the 30 s consistency check restored 110 Hz about 70 s after boot |
| Same, simulated (DSC switches off, custom EDID cleared, override empty, module start-up) with v2.5.1 | LG 40U990A | 110 Hz with DSC in one re-plug, 8 s after the watcher started; never via 120 Hz; DeX and apps at 110 Hz |
| Second full reboot with the LG connected, v2.5.1 | LG 40U990A | Module started when root was loaded; DSC on and extra rates in one re-plug; the modes appeared after 15 s (the old 7 s check would have failed); 5120x2160 at 110 Hz, 10-bit DSC, 4 lanes, DeX and apps at 110 Hz; no pass through 120 Hz |
| Apps on the LG at 110 Hz after the reboot | LG 40U990A | About 50 fps although DeX ran at 110 Hz: the phone was hot (skin 44.7 °C, thermal status critical) and Samsung's thermal service held the GPU at 646 of 1300 MHz (kgsl thermal_pwrlevel 8) and the big CPU cores at 3.86 of 4.74 GHz, while charging and with the phone screen also on |
| 60 Hz while hot (simulated thermal status 4) | LG 40U990A | After two hot checks 110 -> 60 Hz at the same resolution, saved profile kept; no return while the GPU was still held back (level 4); return step: back to 110 Hz |
| Temperature override: who limits what | - | GPU: kgsl `thermal_pwrlevel` (root-only file); CPU: `scaling_max_freq` of both policies, changed by Samsung every 1-4 s (4.74 -> 4.65 -> 4.61 GHz, down to 1.98 GHz when hot); CPU boost stays on |
| Temperature override running | LG 40U990A | GPU limit 0 (1300 MHz), fast cores max 4.74 GHz and reaching it under load; Samsung lowered the limits about once per 1.2 s and the override put them back each time (130 times in 2.5 min) |
| Temperature override battery valve (limit set to 30 °C, battery 33 °C) | LG 40U990A | Samsung's limits back within 11 s; limit back to 41 °C: full speed again within 5 s |
| Load test: WebGL Aquarium (5000 fish) in Samsung Internet on DeX, 5120x2160 110 Hz DSC, highest override limits (battery 50, board 100, skin ignored) | LG 40U990A | Override on (5 min): GPU limit 1300 MHz, fast cores 4.74 GHz throughout; skin estimate up to 59.3 °C, board 71 °C, battery 40.9 °C (+1.5 °C/min); 6-9 W; 30-99 frames/s to the LG. Override off: within seconds GPU 160 MHz (the minimum), fast cores 3.65 then 0.88 GHz, 15-17 frames/s plus 12-13 missed per second, 4.6-5.2 W |
| Samsung's own CPU and GPU limit drivers | - | `/sys/devices/system/cpu/cpufreq_limit/cpufreq_max_limit` (virtual frequency, 1267200 held the fast cores at 2.88 GHz; -1 releases) and `/sys/kernel/gpu/gpu_max_clock` (held the GPU at 422 MHz with Qualcomm's level already at 0); both now released and locked by the override |
| DeX after a quick reconnect | LG 40U990A | Once, Samsung's DeX judged the re-added monitor "desktop ineligible" and left it in mirroring (looked like a DeX crash); a second reconnect brought DeX back. v2.8.0 does that by itself (switchable) |
| Dell U3225QE with DSC (automatic check) | Dell U3225QE | DSC found (limit 340); its own 4K 120 Hz flickered and was reverted by the 30 s check (remembered as not working); extra rates 70-115 Hz at 4K added automatically; own rate 4K 100 Hz added from the page |
| EDID size limit | Dell U3225QE | The kernel keeps only the first 512 bytes (4 blocks) of a custom EDID; a fifth block read as zeros. Extra rates now fit within 4 blocks (5 rates when the monitor already has 2 extension blocks) |
| CPU load per core group in the live panel | - | From /proc/stat per policy's related_cpus, two readings |
| XREAL ultrawide on/off from the glasses' menu | XREAL One Pro | The glasses disconnect for about 3 s and come back with a new EDID (ultrawide 3840x1080 at 60 Hz); handled as a mode switch: settings kept, DeX resized to 3840x1080, saved 1080p 120 Hz not forced on it; back to normal: 1080p 120 Hz restored by itself |
| Phone screen 30 Hz via Android's global peak/min_refresh_rate | XREAL One Pro | Apps on the XREAL (testufo) dropped to 60 fps: those settings are global votes. Replaced by a preferred mode on display 0 only: phone screen 60 Hz, testufo on the XREAL 120 fps |
| `settings` calls from the watcher | - | Failed ("Failed transaction") because the watcher's stderr was a file under /data/adb, which system_server may not receive; the error text was even saved as the user's value. Now through /dev/null and checked |
| Unplug after the fixes | XREAL One Pro | "monitor unplugged" 8 s later; temperature override handed back, pacesetter back to the phone, phone screen preferred mode cleared, global refresh untouched |
| Status call with heat, phone-screen fps and power | - | 0.09 s (dumpsys thermalservice takes about 10 ms) |
| Power (whole phone on battery via slate mode, still DeX screen, 50 s average) | LG 40U990A | 60 Hz 2.03 W; 60 Hz DSC 2.15 W; 80 Hz 6-bit 2.37 W; 110 Hz DSC 3.04 W |
| Live power from the fuel gauge (system current `power_now` x `voltage_sys`, 20 s average) | LG 40U990A | 110 Hz DSC 700 mA x 4.53 V = 3.17 W, 60 Hz DSC 519 mA = 2.35 W, back to 110 Hz 698 mA: follows the change, about 5-10 % above the battery-side result |
| Status call with the power reading | - | 0.15 s for the whole status call; the reading itself is 4 small sysfs reads, only while the page is visible |
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
| Watcher | 4.4 MB | under 0.01 s per minute without a monitor (measured: no measurable CPU time in 60 s); was 0.32 s per minute before v2.11.1, 85 % of it starting `sleep` every 3 s | always (one sysfs read every 3 s, waiting in the kernel in between) |
| Phone-screen guard | ~2 MB | one sysfs read every 0.5 s | only with the switch on and a monitor connected |
| Status page | - | ~50 ms per refresh, once a second | only while the page is open and visible |

## Not yet tested

- DSC with other monitors (the automatic check is generic, but only the LG was tried), and 115 Hz on
  the LG. The 4-slice assumption (two DSC encoders, two slices each) comes from the LG at 5120 wide.
- The extra rates on the Dell U3225QE and the XREAL glasses (the XREAL already offers its 120 Hz
  maximum, so nothing would be added).
- The soft-reboot composer restart as part of the module (it was tested as a stand-alone
  `/data/adb/post-fs-data.d` script with the same code).
- Any other phone, chip, One UI version, or Magisk instead of KernelSU.
