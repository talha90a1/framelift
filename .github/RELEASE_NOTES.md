## Install

Apple Silicon (M1 or newer). macOS 26 or later. Use macOS 27 for 1080p frame generation.

1. Download the macOS ARM64 ZIP, unzip it, and move Framelift.app to Applications.
2. Open Framelift. If macOS blocks the first launch, approve it under **System Settings › Privacy & Security › Open Anyway**.
3. Turn on **Settings › System › Remote Play** on the PS5. Pair it with Framelift on the same network.

## Verify or build from source

Run `shasum -a 256 -c Framelift-*-macOS-arm64.zip.sha256` with the ZIP and checksum in the same directory. For GitHub build provenance, run `gh attestation verify Framelift-*-macOS-arm64.zip --repo talha90a1/framelift`.

The `Framelift-*-source.tar.gz` asset contains this release’s source, dependency sources, patch files, and build instructions. See `CONTRIBUTING.md` inside the archive.
