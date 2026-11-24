# Settings and debug logs

## Settings

Open Settings with ⌘,. The defaults are the recommended values.

- **Display:** the screen to play on (for example a TV over HDMI), and Fullscreen (on by default). Fullscreen also lets macOS turn on Game Mode.
- **Stream:** bitrate, from 2 to 100 Mbps. The default, 30 Mbps, suits most Wi-Fi; on Ethernet or a direct cable, use 50 to 100 Mbps for the sharpest picture. It's a maximum: the PS5 lowers it by itself when packets drop. If more than 3% of packets drop for a few seconds, Framelift shows a short "Weak connection" notice on the stream.
- **Picture:** Sharpness, 0 to 1.5 (default 0.5). Sharpens the 1080p stream on screens larger than 1080p; 0 turns it off.
- **Frame generation:** Apple ML interpolation, 30 to 60 fps. The options are:
  - Keep Apple ML warm (on): runs a spare request between frames so the model stays fast. It saves about 4 to 5 ms per generated frame.
  - Keep subtitles and HUD sharp (on): the static-overlay guard.
  - Blend a stand-in frame when Apple ML is late (on): the 50/50 blend fallback.
  - Display buffers: 3 (default, lower lag) or 2 (fewer dropped frames on slow Macs).
- **Controller:** Touchpad. Click only (default) sends just the touchpad press. Touch + click also sends touches and swipes, for games that need them.
- **Updates:** Check for updates when Framelift opens (on). Framelift asks GitHub once for the latest release; nothing about you or your PS5 is sent and nothing is downloaded. When a newer version is out, a bar in the main window links to its release page. Check Now, or Framelift › Check for Updates…, checks by hand.
- **Debug:**
  - Show performance overlay (⇧⌘O): live timings in the stream window.
  - Debug logs (off by default): writes event logs, frame timings, and up to five minutes of video to `~/Library/Logs/Framelift/`. It takes effect from the next stream. Export Logs… includes the text logs and timings only.
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
