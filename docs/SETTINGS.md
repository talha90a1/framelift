# Settings

Open **Framelift › Settings…** (⌘,).

- **Display** selects the screen and fullscreen mode.
- **Stream** sets the resolution and frame rate. The default is 1080p at 30 fps. Bitrate is capped at the value you set, from 2 to 100 Mbps. Start at 30 Mbps. If the connection drops frames, lower the bitrate or use Ethernet.
- **HDR** requires an HDR display and HDR enabled on the PS5. HDR streams use the source frame rate. Reconnect after changing Stream settings.
- **Picture** selects the Framelift or Apple MetalFX upscaler. Sharpness applies to the Framelift upscaler. Set it to 0 to turn sharpening off.
- **Frame Generation** controls subtitle and HUD protection and late-frame blending. Keeping the interpolation model warm can reduce processing time. Reconnect after changing this option.
- **Controller** sets whether the touchpad sends clicks only or also sends touches and swipes. If several gamepads are connected, press a button on the one you want to use.
- **Updates** checks GitHub for the latest release. Disable the launch check in Settings or run **Framelift › Check for Updates…**.
- **Debug** includes the performance overlay (⇧⌘O) and a latency probe (⇧⌘L, then press Options).

## Report a bug

1. Enable **Settings › Debug › Debug logs**.
2. Start a stream and reproduce the problem.
3. Select **Export Logs…**, review the zip, and attach it to a [bug report](https://github.com/talha90a1/framelift/issues/new?template=bug_report.yml).

Debug logs can save up to five minutes of video under `~/Library/Logs/Framelift/`. The export includes redacted event logs, frame timings, and a system report. Video stays on your Mac.

For security issues, use [private vulnerability reporting](../SECURITY.md).
