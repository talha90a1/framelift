# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.1 - 2026-11-23

### Changed

- Renamed to Framelift.
- The default bitrate is now 30 Mbps, which suits most Wi-Fi. Settings suggests 50 Mbps on Ethernet or a direct cable.

### Added

- A short "Weak connection" notice on the stream when more than 3% of packets drop for a few seconds.

## 1.0.0 - 2026-11-23

First public version.

### Added

- Native macOS PS5 Remote Play client for Apple Silicon, built on chiaki-ng's C library and a C++20 Remote Play core ported from Veyra.
- Console discovery on the local network, wake from rest mode, and pairing with a PIN and Sign in with PlayStation. Remote Play keys are stored in the Keychain.
- Hardware H.264 and HEVC decoding with VideoToolbox. The stream keeps decoding through packet loss instead of freezing until the next keyframe.
- 1080p at 30 fps from the PS5, shown at 60 fps with Apple's `VTLowLatencyFrameInterpolation`.
- A static-overlay guard that keeps subtitles and HUD sharp in generated frames.
- A 50/50 blend of the two real frames when a generated frame is late.
- A keep-warm option that keeps the interpolation model fast between frames.
- A shot-change test that avoids generating frames across scene cuts.
- Metal presentation paced per display, with a choice of 3 (default) or 2 display buffers, and color handling taken from the stream's tags.
- Fullscreen play on a chosen display, including a TV over HDMI.
- DualSense support through GameController and raw HID: buttons, touchpad (click only or touch and click), motion, rumble, haptics and the PS5's exact adaptive trigger effects.
- Controller press and release edges are kept in order, and L2/R2 jitter is filtered.
- chiaki-ng patches for Takion v20, socket QoS and a larger receive buffer, FEC early skip, and user-interactive thread priority.
- Performance overlay (⇧⌘O), FPS counter (⇧⌘F) and latency probe (⇧⌘L).
- Optional debug logs per stream in `~/Library/Logs/Framelift/`, off by default, with redaction of chiaki-ng log lines that could contain keys.
- Settings for display, bitrate, frame generation, touchpad and debugging.
