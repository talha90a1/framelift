# Third-party notices

Framelift as a whole is licensed under AGPL-3.0-only ([LICENSE](LICENSE)). This file lists the code it ports, links or follows, with upstream sources and licenses. License texts are in [licenses/](licenses/).

Upstream URLs and licenses were checked against the upstream repositories (via the GitHub API) on 2026-11-23. Items marked **unverified** could not be checked.

## Ported or adapted source code

| Component | Upstream | License | What we use |
| --- | --- | --- | --- |
| Veyra | https://github.com/Likely7/Veyra-NRVideo, pinned at `0dac67a0153a0a9881b8b022200d8888dd782107` in `scripts/build_chiaki.sh` | GPL-3.0-only ([licenses/GPL-3.0-Veyra.txt](licenses/GPL-3.0-Veyra.txt)) | The C++20 Remote Play core in `Sources/VeyraCore/veyra/` (session backend, registration, discovery, video ingress, timeline, validation), the trigger filter (`Sources/Framelift/Input/TriggerFilter.swift` and its tests), the shot-change shader (`SceneCut.metal`, from `VfgShotChange.hlsl`), and the chiaki-ng video-metadata patch `0002-chiaki-video-metadata.patch`, which `build_chiaki.sh` applies from the Veyra checkout. Files keep their `GPL-3.0-only` SPDX headers. `Sources/VeyraCore/Bridge.cpp` and `Sources/VeyraCore/LogRedaction.*` are Framelift code that also carries `GPL-3.0-only` headers. |
| PushFPS | https://github.com/DosukaSOL/PushFPS, commit `cea4552` | GPL-3.0-or-later. Copyright (C) 2026 DosukaSOL and the PushFPS contributors. | `Sources/VeyraCore/veyra/include/veyra/remoteplay/ControllerQueue.h`: controller state ordering (stick and motion coalescing, ordered button edges, bounded queue), used by `ControllerOutbox.h`. PushFPS is a modified version of Veyra. |
| P5M | https://github.com/beecrepaldi-afk/P5M, commit `d61c8e6` for the DualSense code | AGPL-3.0 (patches: AGPL-3.0-only with the chiaki-ng OpenSSL exception) | chiaki-ng patches `scripts/patches/0110-takion-socket-qos.patch`, `0111-takion-v20.patch` and `0112-takion-fec-early-skip.patch` (Takion v20, socket QoS and receive buffer, FEC early skip). `Sources/Framelift/Input/DualSenseReports.swift` (DualSense output reports, ported) and the haptics pump constants and report sequencing in `DualSenseOutput.swift` and `DualSenseHID.swift`. P5M is built on chiaki-ng and Chiaki by Florian Märkl. |

## Linked libraries

`scripts/build_chiaki.sh` builds these as static libraries in `build/chiaki-dist/lib`, and `Package.swift` links them into the app.

| Component | Upstream | License | What we use |
| --- | --- | --- | --- |
| chiaki-ng (libchiaki) | https://github.com/streetpea/chiaki-ng, pinned at `43728af2e639fecb8a7af1cd68c29820a40de973`, patched with Veyra's `0002` and `scripts/patches/*.patch` | AGPL-3.0-only with an OpenSSL linking exception (`LicenseRef-AGPL-3.0-only-OpenSSL`) ([licenses/AGPL-3.0-only-OpenSSL-chiaki-ng.txt](licenses/AGPL-3.0-only-OpenSSL-chiaki-ng.txt)) | PS5 discovery, registration (pairing), session, Takion transport, FEC, audio and controller feedback. Based on Chiaki by Florian Märkl. |
| `lib/src/vl_rbsp.h` inside chiaki-ng | Part of chiaki-ng's source tree | MIT-style license, Copyright 2013 Advanced Micro Devices, Inc. (notice kept in the file) | Bitstream (RBSP) reading in libchiaki. |
| nanopb | https://github.com/nanopb/nanopb, chiaki-ng submodule at `160d4f09e5fabb2b66aa2dea32d4f38ace2c4b3f` | zlib license ([licenses/nanopb.txt](licenses/nanopb.txt)) | Protocol Buffers encoding and decoding for the Remote Play protocol (`libprotobuf-nanopb`). |
| Jerasure | https://github.com/streetpea/jerasure (fork of Jerasure 2.0), chiaki-ng submodule at `505ccb4bc69eee8d7ea40a6089a056b99671134f` | BSD-3-Clause ([licenses/jerasure.txt](licenses/jerasure.txt)) | Reed-Solomon erasure coding for FEC. |
| GF-Complete | https://github.com/streetpea/gf-complete, chiaki-ng submodule at `fa54a4670a5705c84abf6c24b92b0cd479625478` | BSD-3-Clause ([licenses/gf-complete.txt](licenses/gf-complete.txt)) | Galois field arithmetic for Jerasure. |
| curl (libcurl) | https://github.com/curl/curl, chiaki-ng submodule at `75a2079d5c28debb2eaa848ca9430f1fe0d7844c` (8.11.1-DEV) | curl license, an MIT/X derivative ([licenses/curl.txt](licenses/curl.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) and certificate fetching (`aia.c`) code. |
| OpenSSL 3 | https://github.com/openssl/openssl, from Homebrew `openssl@3` (version not pinned) | Apache-2.0 ([licenses/openssl.txt](licenses/openssl.txt)) | Cryptography for registration and the Takion session (`libssl`, `libcrypto`). |
| Opus | https://opus-codec.org/, from Homebrew `opus` (version not pinned) | BSD-3-Clause ([licenses/opus.txt](licenses/opus.txt)) | Decoding the PS5 audio stream. |
| json-c | https://github.com/json-c/json-c, from Homebrew `json-c` (version not pinned) | MIT ([licenses/json-c.txt](licenses/json-c.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) code. |
| miniupnpc | https://github.com/miniupnp/miniupnp, from Homebrew `miniupnpc` (version not pinned) | BSD-3-Clause ([licenses/miniupnpc.txt](licenses/miniupnpc.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) code. |
| libevent | https://libevent.org/, from Homebrew `libevent` (version not pinned) | BSD-3-Clause ([licenses/libevent.txt](licenses/libevent.txt)) | Linked because libchiaki requires it (`libevent`, `libevent_pthreads`). Used by chiaki-ng's internet connection (holepunch) code. |
| zlib | Provided by macOS (`/usr/lib/libz`) | zlib license | Linked as a system library; not shipped with the app. |

Framelift plays on the local network only and does not start chiaki-ng's internet connection code, but the libraries are still linked. The Homebrew versions are whatever `brew install` provides when you build. The license files in `licenses/` were copied from the installed Homebrew packages and the pinned chiaki-ng submodules.

## Code that follows other projects

These projects are referenced in source comments as the basis for byte layouts, constants or device handling. **Unverified:** whether any code was copied from them, rather than reimplemented from their documentation or behavior, has not been checked line by line. Their notices are reproduced below to be safe.

| Component | Upstream | License | Where |
| --- | --- | --- | --- |
| ps5-mac-companion | https://github.com/cestercian/ps5-mac-companion | MIT, Copyright (c) 2026 Cestercian | DualSense HID matching, non-exclusive open, transport detection (`DualSenseHID.swift`) and USB report 0x02 framing (`DualSenseReports.swift`). |
| dsfm | https://github.com/brc-xyz/dsfm | MIT, Copyright (c) 2026 Alexandru Bracau | Bluetooth 0x05 activation read in `DualSenseHID.swift`. |
| TriggerEffectGenerator | By Nielk1: https://gist.github.com/Nielk1/6d54cc2c00d2201ccb8c2720ad7538db, also in https://github.com/Nielk1/ExtendInput. **Unverified:** which of the two the comment refers to. | MIT (ExtendInput's license; the gist's license is **unverified**) | Adaptive trigger effect byte layout in `TriggerEffects.swift`. |
| Linux `hid-playstation.c` | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c | GPL-2.0 | Reference only for DualSense report offsets in `DualSenseReports.swift`. No code copied. |

### MIT License

The MIT notices above use this text, with the copyright line given in the table:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Remote Play sign-in

`Sources/Framelift/App/PSNSignIn.swift` uses the public Remote Play OAuth client ID and redirect that chiaki-ng also uses, to read the PSN account ID needed for pairing.

## Apple frameworks

The app uses Apple system frameworks that ship with macOS: VideoToolbox (decoding and `VTLowLatencyFrameInterpolation`), Metal and QuartzCore (presentation), GameController and IOKit HID (controllers), AVFoundation, AudioToolbox and Core Audio (audio), Core Haptics, AppKit, SwiftUI and WebKit. They are not redistributed.

## Not used

chiaki-ng's GUI, CLI, FFmpeg decoder, Setsu, Steam Deck and Steam shortcut code, and its other submodules (munit, oboe, borealis, cpp-steam-tools) are not built or linked. SoundTouch is not used.
