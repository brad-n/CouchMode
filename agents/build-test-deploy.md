# Build, test, deploy

## Requirements

macOS 14+ on Apple Silicon, with Xcode or a Swift 5.9+ toolchain. There are
no dependencies beyond the system frameworks.

## The check

```
scripts/check.sh
```

Runs `swift build -c release` and then `swift test`. It must pass before
every commit. Use `swift test --filter <TestClass>` while working, and run the
full check before you finish.

## Build the app

```
scripts/build-app.sh
```

Builds `dist/CouchMode.app` (arm64) from the current commit:

- copies the release binary and `packaging/Info.plist` (the short commit hash
  becomes the build number shown in Settings > Version),
- copies the card artwork in `packaging/art` into the app's Resources,
- signs with `HTPC_SIGN_IDENTITY`, or ad hoc if that is unset.

## Machine settings

Copy `scripts/local.env.example` to `scripts/local.env`. It is ignored by git
(never commit it). Both scripts read it.

| Variable | Used by | Meaning |
|---|---|---|
| `HTPC_HOST` | `deploy.sh` | ssh destination of the Mac that runs CouchMode (`user@mac-mini.local`). Key-based ssh must work. |
| `HTPC_SIGN_IDENTITY` | `build-app.sh` | A code-signing identity name from `security find-identity -v -p codesigning`. A stable identity keeps macOS permission grants (Accessibility, Screen Recording) and Keychain access across rebuilds; ad hoc signing makes macOS ask again after every build. |

## Deploy

```
scripts/deploy.sh
```

Zips `dist/CouchMode.app`, copies it to the host, stops the old CouchMode,
installs into `~/Applications`, and relaunches (retrying a failed launch a
few times). It stops with a usage message if `HTPC_HOST` is not set. Run
`build-app.sh` first.

The usual loop on a device:

```
set -o pipefail
./scripts/check.sh && ./scripts/build-app.sh && ./scripts/deploy.sh
```

## Verify on the device

Turn on the [debug channel](debug-channel.md) once on the target Mac
(`defaults write local.brad.htpcshell DebugControl -bool true`), then
drive the app with `curl` over ssh and take screenshots with `/screen`.
Use [demo mode](demo-mode.md) when screenshots will be published.

## Defaults keys (UserDefaults, domain `local.brad.htpcshell`)

| Key | Meaning |
|---|---|
| `DebugControl` | Enable the localhost debug channel. |
| `DemoMode` | Show only invented sample content; start nothing. |
| `uiSounds`, `screensaverMinutes` | Settings, changed from the Settings screen. |

## Things that are device-only

Window and full-screen behavior, WebKit page reading, controllers and the
Siri Remote, Plex HTPC and game launching cannot be unit-tested. Check them on
a Mac with the debug channel. Pure logic must still have unit tests.
