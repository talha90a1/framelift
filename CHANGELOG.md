# Changelog

## Unreleased

### Added

- 1080p and 720p presets at 30 or 60 fps.
- 10-bit HDR on compatible displays.
- Apple MetalFX upscaling.
- Press a button to select the controller when several are connected.

### Fixed

- Native 60 fps streams stay at 60 fps on 120 Hz displays.
- HDR recordings use the HEVC format.

### Removed

- Keyboard and mouse gameplay input.

## 1.0.1 - 2026-11-24

### Added

- Sharpness control for upscaled video.
- Optional update checks at launch and **Framelift › Check for Updates…**.

### Changed

- Raised the maximum bitrate to 100 Mbps.
- Reconnect waits for the PS5 to close the previous session and retries up to three times.
- Increased the requested receive buffer to 4 MiB, with a 1 MiB fallback.

## 1.0.0 - 2026-11-23

First public version.

### Added

- Native macOS PS5 Remote Play client for Apple Silicon, built on chiaki-ng's C library and a C++20 Remote Play core ported from Veyra.
- Console discovery on the local network, wake from rest mode, and pairing with a PIN and Sign in with PlayStation. Remote Play keys are stored in an owner-only file on the Mac.
- Hardware H.264 and HEVC decoding with VideoToolbox. The stream keeps decoding through packet loss instead of freezing until the next keyframe.
- 1080p at 30 fps, interpolated to 60 fps with Apple’s VideoToolbox.
- A static-overlay guard that keeps subtitles and HUD sharp in generated frames.
- A 50/50 blend of the two real frames when a generated frame is late.
- Optional interpolation warm-up between frames.
- A shot-change test that avoids generating frames across scene cuts.
- Metal presentation paced per display, with a choice of 3 (default) or 2 display buffers, and color handling taken from the stream's tags.
- Fullscreen play on a chosen display, including a TV over HDMI.
- DualSense support through GameController and raw HID: buttons, touchpad (click only or touch and click), motion, rumble, haptics and the PS5's exact adaptive trigger effects.
- Controller press and release edges are kept in order, and L2/R2 jitter is filtered.
- chiaki-ng patches for Takion v20, socket QoS and a larger receive buffer, FEC early skip, and user-interactive thread priority.
- A compact performance overlay (⇧⌘O) and a latency probe (⇧⌘L).
- Optional debug logs per stream in `~/Library/Logs/Framelift/`, off by default, with redaction of chiaki-ng log lines that could contain keys.
- Settings for display, bitrate (30 Mbps default, 50 suggested on a cable), frame generation, touchpad and debugging.
- A short "Weak connection" notice when more than 3% of packets drop for a few seconds.
- A tip and a guide for the best setup: a direct Ethernet cable to the Mac, with Internet Sharing for the PS5.
