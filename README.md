# Macflix Rebuild

![Macflix — a focused Netflix app for macOS](docs/macflix-hero.png)

Macflix is an independent macOS app for Netflix, developed by Suhas Chandrasekara. This rebuild provides a fresh app shell with persistent sign-in, playback keyboard controls, fullscreen support, sleep/wake recovery, and experimental audio controls and diagnostics. Subtitle history and its overlay are not included.

The app uses a separate persistent WebKit profile, so sign in to Netflix again the first time you use this build. It does not change or replace the existing Macflix or Netflix apps in this repository or on your Mac. Macflix is not affiliated with Netflix, Inc.

## Features

- A native macOS window with Netflix playback and navigation.
- Persistent sign-in in a separate Macflix WebKit profile.
- Space and K playback controls, plus Netflix and menu fullscreen controls.
- An experimental Atmos request and native audio bridge, with Audio Status diagnostics. Native audio may fall back to WebKit; diagnostics do not verify Atmos output.
- A single first-play recovery refresh if the first Netflix watch route remains unready for 45 seconds. It skips paused, ended, errored, or actively edited pages and does not clear sign-in data.

## Requirements

- Apple silicon Mac running macOS 14 or later
- Xcode Command Line Tools, including `swiftc`, `xcrun`, `codesign`, and `hdiutil`
- Node.js for the JavaScript checks

## Check, build, and launch

From this directory:

```sh
bash bin/run_tests.sh
bash bin/build_and_bundle.sh
open build/Macflix.app
```

To build the installer DMG (this also runs the checks and builds the app):

```sh
bash bin/package_dmg.sh
```

The installer and source archive are written to `dist/Macflix-<version>-Rebuild-AppleSilicon.dmg` and `dist/Macflix-<version>-Rebuild-Source.zip`. By default the app is ad hoc signed and the DMG is not notarized; macOS may require you to approve opening it. Set `MACFLIX_SIGNING_IDENTITY` to a local signing identity to use that signature for the app bundle. The parser fixture check is skipped when the Apple reference fixtures are absent.

## Manual check

- Sign in, quit Macflix, reopen it, and confirm the separate profile keeps the sign-in.
- Play a title, pause and resume with Space and K in windowed and fullscreen modes; confirm playback keys do not change fullscreen and that spaces and K still type in Netflix fields.
- Try fullscreen and window resizing.
- On first playback, note whether the picture buffers before it starts and whether audio briefly falls back or goes silent; open **Audio Status…** to check which audio route is active. Diagnostics do not prove Atmos output.
- In **Audio**, toggle the experimental Atmos request and native audio bridge; confirm settings take effect after reload.
- After seeking during native playback, check Audio Status again; a timestamp discontinuity can switch this stream back to WebKit audio until reload.
- Test sleep/wake from both paused and playing states; confirm paused playback stays paused and active playback recovers as intended.
- Confirm no subtitle-history overlay appears.

Native Atmos is experimental and may fall back to WebKit audio. Some retained audio code is covered by a third-party MIT license; see [LICENSE](LICENSE) for the required copyright and license notices.

## GitHub releases

Push a `vMAJOR.MINOR.PATCH` tag matching `CFBundleShortVersionString` in `Resources/Info.plist`. GitHub Actions runs the checks, builds the Apple silicon installer and source archive, calculates SHA-256 checksums, and creates a draft release for review. See [RELEASE.md](RELEASE.md) for the release steps.

Inspired by [Matthew Daniel Murphy](https://github.com/mattdanielmurphy/netflix-native).
