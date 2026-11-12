# Architecture

CouchMode is a Swift package (macOS 14+, Swift 5.9 tools): SwiftUI screens
hosted in an AppKit full-screen window. Two targets:

- **`CouchModeCore`** (`Sources/CouchModeCore`): pure logic. No AppKit, no
  WebKit, no disk, no network. Unit-tested in `Tests/CouchModeCoreTests`.
- **`CouchMode`** (`Sources/CouchMode`): the app. Windows, SwiftUI, WebKit,
  controllers, processes. Wires Core to the system. Not unit-tested; it is
  verified on a device (see [debug-channel.md](debug-channel.md)).

If something can be written as "input in, value out", it belongs in Core.

## What lives where

**Core (pure):**

| Area | Files |
|---|---|
| Input vocabulary and routing | `Intent`, `PlayerInput`, `PlayerBackKey`, `HomeRouting`, `RemotePassthrough`, `HIDPadLayout`, `ConfirmGate` |
| Focus and layout rules | `FocusGrid`, `RowSlide`, `DetailFocus`, `StreamFocus`, `StreamKeyboard`, `Cycle` |
| Catalogs and config | `AppCatalog` (parses `apps/catalog.json`), `AppConfig` + `ConfigFile` (a Mac's `config.json`), `Service` and `Consoles` (made from the catalog), `SwitchCatalog`, `BluetoothPane` |
| Shared streaming vocabulary | `StreamCatalog` (`StreamHome`, `StreamRow`, `StreamTitle`, `StreamTitleDetails`, ..., `StreamLimits`), `StreamJSON` (careful JSON readers, script quoting) |
| Reader packages | `PackageManifest` (a package's manifest), `PackageDecoder` (a package's JSON -> the shared vocabulary, with all the id/address/size checks), `PackageIndex` (the published package list). There are no per-service parsers in Core: each service's parsing lives in its package (`apps/<id>/reader.js`). |
| Page scripts | `Netflix51` (the app-installed Netflix 5.1 page script, not a reader), `ProfileSwitch` / `UnfinishedSwitch` |
| Player handoff | `PlayerExit`, `PlayNudge`, `ImageRetry` |
| Plex | `Plex` (JSON parsing, URLs), `PlexInspector`, `PlexHTPCLog` |
| Debug channel | `HTTPRequest` (bounded parser) |
| App tiles | `TVArt` (tvOS app art from Apple's public catalog: lookup, host and landscape checks), `SiteIcons` (a site's own icon, the fallback), `EdgeColor`, `TileLayout` (tile size, corner, logo fit, tilt) |
| Demo mode | `DemoArtSpec`, `DemoCatalog` (see [demo-mode.md](demo-mode.md)) |

**App (wiring):**

| Area | Files |
|---|---|
| Composition root | `main.swift` builds everything once |
| Which screen shows, what each input does | `AppCoordinator` (the single entry point for all input) |
| Home and games screens | `HomeView`, `AppTileView` (the Apps row tile), `ConsoleView`, `AllConsolesView`, `GameDetailView`, `PlexDetailView`, `SettingsView`, `ScreensaverView`, `IntroView`, `Overlays`, `DesignSystem` |
| Shared streaming screens | `StreamHomeView/Model`, `StreamDetailView/Model`, `StreamSearchView`, `StreamParts` |
| Readers | `StreamSource` (the protocol), `PageDriver`, `PageScripts` |
| Script packages | `ScriptReader` (the generic reader that runs `apps/<id>/reader.js`; the only reader), `PackageStore` / `PackageUpdater` (find and update packages) |
| Web | `WebPlayer` (one WKWebView per service), `WebPage` |
| Other apps and games | `GameLauncher` (RetroArch and Switch apps), `AppLauncher`, `PlexHTPC`, `PlexClient`, `PlexInspectorClient` |
| Apps and config | `AppConfigStore` (loads the catalog and config, hides unmet requirements, saves per-app settings), `AppServices` |
| System | `SystemSettings` (audio, login item), `SystemActions`, `SystemInput`, `BluetoothSettings`, `AccessibilityTree`, `ScreenCapture`, `UISound`, `InputSources`, `HIDGamepads` |
| Debug | `DebugServer` |
| Demo mode | `DemoMode`, `DemoArtRenderer`, `DemoStreamSource` |

## The flow of one input

1. A device (keyboard, controller, Siri Remote, HID pad) becomes a
   `ShellIntent` in `InputSources` / `HIDGamepads`. Nothing downstream knows
   which device it was.
2. `AppCoordinator.handle(_:)` looks at the current `Screen` (home, a console,
   a stream home, details, search, settings, a service's web page, ...) and
   decides what the intent does there. Focus rules come from Core.
3. Views are driven by small observable models (`HomeModel`,
   `StreamHomeModel`, ...). No ScrollViews: positions are computed from
   `FocusGrid` and `RowSlide` so focus can never drift off screen.

## The streaming stack

```
 StreamHomeView / StreamDetailView / StreamSearchView   (shared, service-neutral)
                    |  StreamHome, StreamTitle, ...   (Core: StreamCatalog)
              StreamSource   <- ScriptReader + the service's package (apps/<id>/)
                    |  one action at a time
               PageDriver      (open, wait, read; bounded; newest action wins)
                    |
         the service's own page in its WKWebView ("backstage")
```

- Each reader action is **one action on the real site, read back** (the proxy
  rule). Nothing is crawled or fetched ahead.
- The service's page is kept alive *behind* the CouchMode screen
  (`AppCoordinator.setBackstage`). That keeps the login and gives the reader
  a page to act on.
- **Playback** is `AppCoordinator.playStream`: the title's own play address is
  loaded in that same page, which is brought to the front full screen.
  `watchPlayerExit` / `PlayerExit` detect leaving the player (the site's back
  arrow, the end of an episode) and `endStreamPlayback` returns to the screen
  you came from. `PlayerBackKey` makes Escape and Delete mean "back" while a
  handed-off title is showing. A source call never plays anything.
- A service without a package opens its website (`showWeb`) with remote
  navigation, or a native app (`nativeAppBundleID`, e.g. Plex HTPC).

## Plex

`PlexClient` reads Continue Watching from the user's Plex servers using a
token it reads from Plex Web's own storage (inside CouchMode's web view) and
keeps in the Keychain. `Plex.swift` (Core) parses the JSON.
`PlexHTPC` opens a title in the Plex HTPC app by its own navigation (asked
through the app's inspector, see `PlexInspector`).

## Games and Home

App tiles show each service's own art, fetched at runtime and never committed: first its tvOS icon
(`appStoreId` in the catalog, looked up on Apple's public catalog), else its site's icon as a logo on a
full-bleed background, else a system-style tile. `ServiceIcons` caches each for a week.

`GameLauncher` is the only code that knows the games folder, RetroArch's
install and command line, and the NX2Apple front-end contract. `HomeRouting`
(Core) decides what Home does for the app in front: a streaming app closes, a
retro game saves its state and quits, a Switch game is paused (SIGSTOP) and
resumed by Play.

## Threading

Everything UI and I/O in the app is `@MainActor`, asynchronous, and bounded.
Page reads are `async` with time limits; process launches don't wait; the
debug server uses `Network.framework` on the main queue and never blocks.

## Adding things

- A new screen: a model + a view + a case in `AppCoordinator.Screen`, with the
  focus rules in Core.
- A new service reader (a script package): [add-a-streaming-service.md](add-a-streaming-service.md).
- A new console: one entry in `apps/catalog.json` (see [config.md](config.md)) and a test.
