# Demo mode

Demo mode makes CouchMode show **only invented content with original,
generated artwork**. It exists so screenshots, trials and bug reports contain
no one's real rows, viewing history, profiles or game library, and no
service's, studio's or game publisher's artwork.

## Turning it on and off

```
defaults write local.brad.htpcshell DemoMode -bool true     # then relaunch
defaults delete local.brad.htpcshell DemoMode               # back to normal
```

It is read once at launch (`DemoMode.isOn`), so a running screen can't change
under you. It is off by default and has no effect when off.

## What it shows

- **Home:** Plex "Continue Watching" with five invented titles; "Jump Back In"
  with invented games; every service tile; consoles that have sample games.
- **Netflix, Hulu and every other web service:** CouchMode's own stream
  screens (home with a hero and rows, details with seasons and episodes,
  search with the keyboard, profile picker) on invented titles, via
  `DemoStreamSource`. Profiles are Alex, Sam and Kids.
- **Consoles:** a Switch library of eight invented games with details (genres,
  publisher, blurb) and retro libraries for NES, SNES, Game Boy and Genesis.
- **Settings:** values that would name this Mac's own devices (sound output,
  controllers, storage) are replaced with fixed sample text.
- **Art:** every picture is drawn at runtime by `DemoArtRenderer` from the
  invented title: a gradient, one soft motif (sunrise, waves, hills, rings,
  lattice, beams, orbit, crescent), and the title as text. No photos, no
  recognizable characters, no files. The console tile art on Home is the
  project's own bundled original artwork (`packaging/art`).

## What it never does

Demo mode **starts nothing**. A card that would open another app, a real
website or a player (Plex, a service with no sample screens, Play on a title
or a game) does nothing but show a short notice. No real web page is put on
screen (`setBackstage` is skipped), Plex is not contacted, the games folder is
not read, and no game is launched (`GameLauncher.launch` returns early).

## How it works

Pure parts, in `Sources/CouchModeCore`, tested in
`Tests/CouchModeCoreTests/DemoTests.swift`:

- `DemoArtSpec`: a kind (`tile`, `hero`, `square`) and a title. From the
  title it derives a stable seed (FNV-1a, same on every run), a motif, a
  palette, a deterministic sequence of numbers to place shapes, pixel sizes,
  and a `couchmode-demo://art/<kind>?title=...` address (and parses it back).
- `DemoCatalog`: the invented titles, rows, profiles, show details and
  episodes, search, Plex samples, and games per console (plus how long ago
  each was "played").

App parts, in `Sources/CouchMode`:

- `DemoMode`: the switch, and the small helpers that adapt the catalog to the
  app's types (sample games, Plex entries, catalog entries, settings values).
- `DemoArtRenderer`: draws a `DemoArtSpec` with CoreGraphics into an
  `NSImage`, with a bounded cache.
- `DemoStreamSource`: a `StreamSource` whose answers come from `DemoCatalog`.

Hooks into normal code are small and each starts with `DemoMode.isOn`:

| Where | Hook |
|---|---|
| `RemoteImage.swift` | Addresses with the `couchmode-demo` scheme are drawn, never fetched. |
| `GameLauncher` | `games(for:)` and `lastPlayed(for:)` return samples; `launch` refuses. |
| `GameArt` (`ConsoleView.swift`) | `info`, `card`, `banner` return the sample game's data and art. |
| `AppCoordinator` | Continue Watching is the sample; `open` blocks anything that starts outside the shell; `playStream` does nothing; settings values; no backstage page; Jump Back In art for retro games. |
| `main.swift` | Registers a `DemoStreamSource` for every web service. |

## Taking screenshots

1. Build and deploy ([build-test-deploy.md](build-test-deploy.md)), enable
   the [debug channel](debug-channel.md) and demo mode on the device, relaunch.
2. Drive with `/intent`, capture with `/screen`, copy back with `scp`, resize
   to about 1600 px wide with `sips --resampleWidth 1600`.
3. **Look at every picture** before committing it. If anything real or
   third-party shows (a name, a device, a still, a logo, a game's art), fix
   demo mode and retake.
4. Turn demo mode **off** again on the device when you are done.

Screenshots live in `docs/screenshots/`.

## Adding or changing sample content

Add titles and games to `DemoCatalog` (keep everything invented, keep
synopses short so they fit one line under the hero, avoid names of real
works) and extend `DemoTests`. Add motifs in `DemoArtRenderer` and
`DemoMotif`. Never add image files, and never fetch anything: demo mode must
work offline.
