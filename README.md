# Seperate

A macOS workbench for running coding agents (Claude Code, Codex) and shells side by side across projects and git worktrees, built on [libghostty](https://github.com/ghostty-org/ghostty).

## Install

1. Download `Seperate-<version>.dmg` from the [latest release](https://github.com/BarrySong97/seperate/releases/latest).
2. Drag **Seperate** into **Applications**.
3. The app is not notarized yet, so the first launch is blocked by Gatekeeper. Right-click the app and choose **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Seperate.app
   ```

Requires macOS 14 or later on Apple Silicon.

## Updates

Seperate updates itself through [Sparkle](https://sparkle-project.org). You can choose how updates arrive from the **Seperate** menu:

| Menu item | What it does |
| --- | --- |
| 检查更新… | Checks right away and shows the update dialog. |
| 自动检查更新 | Checks once a day in the background (on by default). When a new version is found, a **新版本 x.y.z** button appears in the top bar. Click it to review and install. |
| 自动下载并安装更新 | Downloads new versions in the background and installs them the next time you quit. |

Every update is verified with an EdDSA signature before it is installed.

## Build from source

Requirements: Xcode 26, Rust (`rustup`), Apple Silicon.

```sh
scripts/setup-ghostty.sh         # once: builds GhosttyKit into Vendor/ (downloads Zig)
scripts/build-app.sh debug --open
swift test
scripts/package-dmg.sh           # build/Seperate-<version>.dmg and .zip
```

## Releasing

Releases are built by GitHub Actions ([`release.yml`](.github/workflows/release.yml)).

```sh
scripts/release.sh 0.2.0         # tags v0.2.0 and pushes it
gh run watch
```

The workflow builds the app, packages the DMG and the update zip, signs the zip with the Sparkle key, writes `appcast.xml`, and publishes the GitHub Release. Installed apps read the feed from `releases/latest/download/appcast.xml`.

One-time setup, already done for this repo: `scripts/sparkle-keys.sh` creates the Sparkle key pair in the login Keychain and stores the private key as the `SPARKLE_PRIVATE_KEY` secret. The public key is in `scripts/build-app.sh`.

To sign with a Developer ID and notarize, add these repository secrets: `MACOS_CERT_P12` (base64 .p12), `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.
