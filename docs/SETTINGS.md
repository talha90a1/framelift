# Settings and debug logs

## Settings

Open Settings with ⌘,. The defaults are the recommended values.

- **Display:** the screen to play on (for example a TV over HDMI), and Fullscreen (on by default). Fullscreen also lets macOS turn on Game Mode.
- **Stream:** bitrate, from 2 to 50 Mbps. The default, 30 Mbps, suits most Wi-Fi; on Ethernet or a direct cable, use 50 Mbps for the sharpest picture. It's a maximum: the PS5 lowers it by itself when packets drop. If more than 3% of packets drop for a few seconds, Framelift shows a short "Weak connection" notice on the stream.
- **Frame generation:** Apple ML interpolation, 30 to 60 fps. The options are:
  - Keep Apple ML warm (on): runs a spare request between frames so the model stays fast. It saves about 4 to 5 ms per generated frame.
  - Keep subtitles and HUD sharp (on): the static-overlay guard.
  - Blend a stand-in frame when Apple ML is late (on): the 50/50 blend fallback.
  - Display buffers: 3 (default, lower lag) or 2 (fewer dropped frames on slow Macs).
- **Controller:** Touchpad. Click only (default) sends just the touchpad press. Touch + click also sends touches and swipes, for games that need them.
- **Debug:**
  - Show performance overlay (⇧⌘O): live timings in the stream window.
  - Debug logs (off by default): writes a log folder per stream (`events.log` and per-frame timings in `frames.csv`) to `~/Library/Logs/Framelift/`. It takes effect from the next stream.
  - Latency probe (⇧⌘L): available while streaming with Debug logs on. Press Options on the controller and the overlay reports the button-to-screen time.
  - Export Logs… and Show Logs in Finder: shown when Debug logs is on. Export Logs… writes a zip of the debug logs, with personal data removed, for a bug report.

Restore Defaults at the bottom of Settings resets everything.

## Debug logs and bug reports

1. Turn on Settings › Debug › Debug logs.
2. Start a new stream and reproduce the problem.
3. Open Settings › Debug › Export Logs… and save the zip.
4. Open a new issue with the bug report template and attach the zip.

Pairing keys, PINs and sign-in tokens are not written to the logs: chiaki-ng log lines that could contain key material, credentials or hex dumps are dropped before they are written. When you export, Framelift also replaces IP and MAC addresses, email addresses, your user name and home folder path, your Mac's name, your PSN online ID and account ID, and console names and addresses with placeholders such as `<ip-1>`. The zip still contains timings, settings, and a system report (app version, macOS version, Mac model, displays, network type and controller). You can open the zip and check it before you attach it.

For security problems, do not open a public issue. See [SECURITY.md](../SECURITY.md).
