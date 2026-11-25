# Contributing to Framelift

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Use the [security policy](SECURITY.md) to report vulnerabilities privately.

## Development setup

You need:

- A Mac with Apple Silicon running macOS 27.
- Xcode. The project is developed and tested with the macOS 27 SDK.
- Homebrew, CMake and Python 3.
- A PS5 on your local network, to test streaming. Unit tests do not need one.

Build the chiaki-ng library once, then the app:

```bash
scripts/build_chiaki.sh            # pinned chiaki-ng and Veyra into third_party/, patches applied, libchiaki built
scripts/bundle_app.sh              # release build, dist/Framelift.app
scripts/bundle_app.sh --debug      # debug build
scripts/bundle_app.sh --install    # also replace /Applications/Framelift.app
```

Run `scripts/build_chiaki.sh` again after you change a file in `scripts/patches/` or the pins in that script.

The scripts use `/Applications/Xcode.app` unless you set `DEVELOPER_DIR`. Set it for plain `swift` commands too if your default toolchain is not that Xcode:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Code layout

See `Sources/` for the modules and their interfaces.

## Tests

```bash
swift build
swift test
```

The C and C++ core has extra test scripts in `Tests/`:

- `Tests/core_smoke.sh`: builds the core from source and runs a smoke test.
- `Tests/core_sanitize.sh asan|tsan`: runs the loopback session test and the inbox stress test under a sanitizer.
- `Tests/core_fuzz.sh [seconds]`: libFuzzer target for the core. Needs Homebrew LLVM.

## Shaders

The Metal shaders live in `Sources/Framelift/Render/Shaders/*.metal` and are compiled at run time. `Sources/Framelift/Render/ShaderSources.swift` holds an inline copy that the app uses when the shader folder is missing. After you edit a `.metal` file, regenerate it:

```bash
scripts/gen_inline_shaders.sh
```

Commit the `.metal` change and the regenerated `ShaderSources.swift` together. Do not edit `ShaderSources.swift` by hand.

## CI and releases

Pull requests to `main` build and run Swift tests on an Apple Silicon runner. Swift formatting is advisory. Docs-only pushes to `main` skip the build.

To release, set the app version in `Resources/Info.plist`, date the matching section in `CHANGELOG.md`, and tag a commit on `main` as `vMAJOR.MINOR.PATCH`. GitHub Actions builds and tests the app, publishes its ZIP and corresponding source, and attests both downloads. Manual runs keep the build as an Actions artifact.

The source archive includes the pinned chiaki-ng and Sparkle sources and the upstream archives and formulae for the Homebrew libraries shipped in that release. `SOURCE_REVISIONS.txt` lists the versions. The normal build uses Homebrew binaries. To reproduce the dependency versions, use the included recipes and source archives.

For GitHub maintainers, protect `main` with pull requests and the `build-and-test` check. Restrict force pushes and deletion. Enable private vulnerability reporting, Dependabot alerts and security updates, secret scanning and push protection, and immutable releases.

## Coding style

- Swift: follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). Four spaces, no tabs.
- C and C++: match the surrounding file. Four spaces, no tabs, C++20.
- `.editorconfig` sets indentation and line endings. Use an editor that reads it.
- Start new source files with an SPDX line:

  ```swift
  // SPDX-License-Identifier: AGPL-3.0-only
  ```

  New files use `AGPL-3.0-only`. Files ported from another project keep their original SPDX line and copyright notice, and name the source and commit.
- Keep comments short. Write them only for constraints that the code cannot show, such as a hardware quirk, a protocol detail or a measured threshold. Do not narrate history in comments; that belongs in the commit message.
- Do not add new environment variables or hidden flags to change behavior. Add a setting if users need the choice, or pick one behavior.
- Never log keys, PINs, account IDs, tokens or other personal data. Keep log redaction working.

## Proposing changes

- For a large change (a new feature, a new dependency, a change to the frame generation or pacing design), open an issue first so we can agree on the approach.
- Keep pull requests small and focused on one change. Separate refactors from behavior changes.
- Add or update tests in `Tests/FrameliftTests` for changes to logic such as pacing, settings, report building or parsing.
- For performance changes, include before and after numbers. Turn on Settings › Debug › Debug logs, run the same scene for at least a minute with and without the change, and report the lag and timing lines from `events.log`. Name the Mac, the display and its refresh rate, and the network (Wi-Fi or Ethernet).
- Describe how you tested: which tests you ran and whether you streamed from a real PS5.
- Write commit messages in the imperative mood, with a short summary line.

## Patches to chiaki-ng

Changes to chiaki-ng go in `scripts/patches/` as numbered patch files against the pinned commit. Start each patch with a short header that says what it changes and why, and where it came from if it is ported. If a change is useful upstream, consider sending it to [chiaki-ng](https://github.com/streetpea/chiaki-ng) too.

## License of contributions

Framelift is licensed under AGPL-3.0-only. By submitting a contribution, you agree that it is licensed under AGPL-3.0-only, or under the license in the SPDX header of the file you change if that file has a different one. You must have the right to submit the code. Do not submit code copied from projects with incompatible licenses.
