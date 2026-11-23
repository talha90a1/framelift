Apple Silicon build (M1 or newer). macOS 27 is needed for 1080p frame generation.

## Install

1. Download `Framelift-<version>-macOS-arm64.zip` below and unzip it.
2. Move `Framelift.app` to Applications and open it.
3. The app is not notarized, so macOS blocks the first launch. Open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to Framelift, and confirm.

You only do this once per version. To check the download, compare its SHA-256 with the `.sha256` file:

```bash
shasum -a 256 Framelift-*-macOS-arm64.zip
```

## Notes

- Works on your local network. For the best experience, connect the PS5 to your Mac with an Ethernet cable and share your Mac's internet to it (see Best setup in the README). Pair the PS5 under Settings › System › Remote Play › Pair Device.
- Found a problem? Turn on Settings › Debug › Debug logs, reproduce it, then use Export Logs… and attach the zip to a bug report.
