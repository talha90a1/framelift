# Third-party notices

Framelift as a whole is licensed under AGPL-3.0-only ([LICENSE](LICENSE)). This file lists the code it ports, links or follows, with upstream sources and licenses. License texts are in [licenses/](licenses/).

## Ported or adapted source code

Framelift first shipped its ports and modifications on November 23, 2026. Release source archives list dependency revisions in `SOURCE_REVISIONS.txt`.

| Component | Upstream | License | What we use |
| --- | --- | --- | --- |
| Veyra | https://github.com/Likely7/Veyra-NRVideo | GPL-3.0-only ([license](licenses/GPL-3.0-Veyra.txt)) | C++ Remote Play core, trigger filter, scene-cut shader, and chiaki-ng video-metadata patch. |
| PushFPS | https://github.com/DosukaSOL/PushFPS | GPL-3.0-or-later. Copyright (C) 2026 DosukaSOL and the PushFPS contributors. | Controller queue, reconnect waits, receive-buffer sizing, controller selection, and frame-pacing ideas. PushFPS is a modified version of Veyra. |
| P5M | https://github.com/beecrepaldi-afk/P5M | AGPL-3.0. The chiaki-ng patches use AGPL-3.0-only with the OpenSSL exception. | Takion transport patches and DualSense output layouts, report sequencing, and haptics pump constants. |

## Linked libraries

`scripts/build_chiaki.sh` builds these as static libraries in `build/chiaki-dist/lib`, and `Package.swift` links them into the app.

| Component | Upstream | License | What we use |
| --- | --- | --- | --- |
| chiaki-ng (libchiaki) | https://github.com/streetpea/chiaki-ng, patched with Veyra's `0002` and `scripts/patches/*.patch` | AGPL-3.0-only with an OpenSSL linking exception (`LicenseRef-AGPL-3.0-only-OpenSSL`) ([licenses/AGPL-3.0-only-OpenSSL-chiaki-ng.txt](licenses/AGPL-3.0-only-OpenSSL-chiaki-ng.txt)) | PS5 discovery, registration (pairing), session, Takion transport, FEC, audio and controller feedback. Based on Chiaki by Florian Märkl. |
| `lib/src/vl_rbsp.h` inside chiaki-ng | Part of chiaki-ng's source tree | MIT-style license, Copyright 2013 Advanced Micro Devices, Inc. (notice kept in the file) | Bitstream (RBSP) reading in libchiaki. |
| nanopb | https://github.com/nanopb/nanopb, chiaki-ng submodule | zlib license ([licenses/nanopb.txt](licenses/nanopb.txt)) | Protocol Buffers encoding and decoding for the Remote Play protocol (`libprotobuf-nanopb`). |
| Jerasure | https://github.com/streetpea/jerasure (fork of Jerasure 2.0), chiaki-ng submodule | BSD-3-Clause ([licenses/jerasure.txt](licenses/jerasure.txt)) | Reed-Solomon erasure coding for FEC. |
| GF-Complete | https://github.com/streetpea/gf-complete, chiaki-ng submodule | BSD-3-Clause ([licenses/gf-complete.txt](licenses/gf-complete.txt)) | Galois field arithmetic for Jerasure. |
| curl (libcurl) | https://github.com/curl/curl, chiaki-ng submodule (8.11.1-DEV) | curl license, an MIT/X derivative ([licenses/curl.txt](licenses/curl.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) and certificate fetching (`aia.c`) code. |
| OpenSSL 3 | https://github.com/openssl/openssl, from Homebrew `openssl@3` | Apache-2.0 ([licenses/openssl.txt](licenses/openssl.txt)) | Cryptography for registration and the Takion session (`libssl`, `libcrypto`). |
| Opus | https://opus-codec.org/, from Homebrew `opus` | BSD-3-Clause ([licenses/opus.txt](licenses/opus.txt)) | Decoding the PS5 audio stream. |
| json-c | https://github.com/json-c/json-c, from Homebrew `json-c` | MIT ([licenses/json-c.txt](licenses/json-c.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) code. |
| miniupnpc | https://github.com/miniupnp/miniupnp, from Homebrew `miniupnpc` | BSD-3-Clause ([licenses/miniupnpc.txt](licenses/miniupnpc.txt)) | Linked because libchiaki requires it. Used by chiaki-ng's internet connection (holepunch) code. |
| libevent | https://libevent.org/, from Homebrew `libevent` | BSD-3-Clause ([licenses/libevent.txt](licenses/libevent.txt)) | Linked because libchiaki requires it (`libevent`, `libevent_pthreads`). Used by chiaki-ng's internet connection (holepunch) code. |
| zlib | Provided by macOS (`/usr/lib/libz`) | zlib license | Linked as a system library; not shipped with the app. |

Framelift plays on the local network only and does not start chiaki-ng's internet connection code, but the libraries are still linked. The Homebrew versions are whatever `brew install` provides when you build. The license files in `licenses/` were copied from the installed Homebrew packages and the pinned chiaki-ng submodules.

## Code that follows other projects

These projects are references for report layouts and device handling. Their license notices follow.

| Component | Upstream | License | Where |
| --- | --- | --- | --- |
| ps5-mac-companion | https://github.com/cestercian/ps5-mac-companion | MIT, Copyright (c) 2026 Cestercian | DualSense HID matching, non-exclusive open, transport detection (`DualSenseHID.swift`) and USB report 0x02 framing (`DualSenseReports.swift`). |
| dsfm | https://github.com/brc-xyz/dsfm | MIT, Copyright (c) 2026 Alexandru Bracau | Bluetooth 0x05 activation read in `DualSenseHID.swift`. |
| TriggerEffectGenerator | [ExtendInput](https://github.com/Nielk1/ExtendInput), `Controller/Sony/TriggerEffectGenerator.cs` | MIT, Copyright (c) 2021–2022 John "Nielk1" Klein | DualSense trigger effect layouts in `TriggerEffects.swift`. |
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

The app uses Apple system frameworks that ship with macOS: VideoToolbox (decoding and `VTLowLatencyFrameInterpolation`), Metal, MetalFX and QuartzCore (presentation), GameController and IOKit HID (controllers), AVFoundation, AudioToolbox and Core Audio (audio), Core Haptics, AppKit, SwiftUI and WebKit. They are not redistributed.

## Not used

chiaki-ng's GUI, CLI, FFmpeg decoder, Setsu, Steam Deck and Steam shortcut code, and its other submodules (munit, oboe, borealis, cpp-steam-tools) are not built or linked. SoundTouch is not used.
