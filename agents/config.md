# Apps: the catalog and a Mac's config

Two files decide what Home shows.

- **`apps/catalog.json`** (in the repo, bundled as `Contents/Resources/catalog.json`):
  every app CouchMode knows and its defaults. One source: services and
  consoles are made from it (`ServiceCatalog.make`, `ConsoleCatalog.make`).
- **`config.json`** (per Mac, `~/Library/Application Support/<bundle id>/`, beside
  the icon cache): the apps this Mac has added, in order, with their settings.

Secrets never go in either file (tokens stay in the Keychain). Global UI
preferences (interface sounds, screensaver minutes) stay in `Prefs`
(UserDefaults); only things that belong to one app are in the config.

## Catalog entry

| Field | Meaning |
|---|---|
| `id`, `name` | Stable id (readers register by it) and the tile's name. |
| `kind` | `stream` (a site, with or without a reader), `native` (a Mac app), `console` (a game launcher), `system` (Settings). |
| `site` | `url`, `userAgent` (`safari`, `smartTV` or a literal string), optional `tvInterface`, `navigationSkip`. Streams need it; a native app may have it as the fallback. |
| `native` | `bundleId` and/or `appPath`. |
| `console` | `emulator` (`retroarch` with a `core`, or `app` when each game is its own Mac app), `extensions`, `defaultFolder`. |
| `requires` | Conditions to show the app: `{label, bundleId?, appPaths?}`. Met when the bundle id is installed or any path exists. |
| `defaultEnabled` | Added to a fresh config (default true). |

Plex has no `requires`: it opens its website when Plex HTPC is not installed.
Retro consoles require RetroArch; Switch does not.

## Config

```json
{
  "apps" : [
    { "id" : "netflix", "settings" : { "netflix51" : "auto" } },
    { "id" : "youtube", "settings" : { } },
    { "id" : "settings", "settings" : { } },
    { "id" : "nes", "settings" : { "gamesFolder" : "~/Games/nes" } },
    { "id" : "some-future-app", "settings" : { "key" : "value" } }
  ],
  "version" : 1
}
```

- `apps` is ordered. Home's Apps row shows the stream, native and system
  entries in that order; the Play row shows the consoles that have games, in
  that order.
- Settings are plain strings, numbers or booleans. Known ones: a console's
  `gamesFolder` (`~` allowed), Netflix's `netflix51` (`auto`, `on`, `off`).
  A stream app always uses its script package (`apps/<id>/`, bundled or downloaded; see
  [add-a-streaming-service.md](add-a-streaming-service.md)) when it has one, else it opens its website. The old
  `reader` setting (`builtin` or `package`) and the catalog's old `reader` field are **ignored**: configs and
  catalogs that still contain them load, keep them when saved, and behave as if they were absent. The package is
  chosen when the app starts, and again for a service when its package is updated or the app is added.
- `packageRef` (top level, optional): the branch, tag or commit in the GitHub repo that app packages are fetched
  from; `main` when absent. Letters, digits and `. _ - /` only; anything else is ignored.
- An id the catalog does not know is ignored but kept when the file is saved.
  An app whose `requires` is not met is hidden (one log line each), not removed.
  A repeated id counts once (the first).

## Settings > Apps

Home's Settings has an **Apps** row. It lists the added apps in order; selecting one offers **Move up**,
**Move down** and **Remove** (a second press confirms; Settings itself can't be removed). **Add an app...**
lists the catalog apps not yet added with their requirement status ("Ready" or "needs RetroArch"); adding appends
to the config with the app's defaults. **Check for app updates** shows the package versions in use and fetches
newer ones. Every change is saved to `config.json` (atomically) and Home updates at once. Removing a stream app
keeps its website data and sign-in. An app whose requirement is unmet can be added; it appears on Home once the
requirement is met. `GET /state` on the debug channel describes the screen (`pane`, `selected`, `order`).

## First-run setup

Shown when there is no `config.json`, and from Settings > **Run setup again** (which starts from the current
choices). Pure logic is `FirstRunSetup` in Core (steps, defaults, the written order); `SetupScreen` draws it.
Steps: Welcome; Choose your apps (streaming services and native apps, check marks; an app with an unmet
requirement is shown off with the reason); Games (consoles whose emulator is installed, each with its folder and
whether it was found; on only if the folder has games); Sign in (opens the service's own site in the shell's web
view for the person to sign in, once; Back returns, and the package's own `home` ready check fills in "Signed in",
"Not yet", or "Opened" when the service has no package); Done. Steps with nothing to show are skipped. Back goes to
the previous step. Defaults: streaming services on, Plex on when Plex HTPC is installed. The config is written at
Done in this order: streaming services, native apps, games, Settings (a second run keeps the existing order and
settings, and leaves alone anything it did not offer).

## Package updates

`apps/index.json` lists every package (`apps/<id>/manifest.json` + `reader.js`): id, package `version`, `readerAPI`
and each file's sha256. `scripts/package-index.sh` regenerates it and `check.sh` fails when it is stale.
`PackageUpdater` fetches `https://raw.githubusercontent.com/brad-n/CouchMode/<ref>/apps/index.json`, then each
package whose `readerAPI` this app supports and whose version is newer than the bundled or downloaded copy. It
checks every file's hash against the index (any mismatch installs nothing) and swaps the package in atomically
at `~/Library/Application Support/<bundle id>/apps/<id>/`, with a `verified.json` record that is re-checked on
every load. A verified download is preferred over the bundled copy unless the bundled one is newer. Offline or
failing, it logs one line and changes nothing. It runs at most once a day on its own, and on demand from
Settings > Apps > Check for app updates (an index not published yet reads "No app updates are published yet.").

## Lifecycle (`AppConfigStore`, `ConfigFile`)

1. No file: **first-run setup** shows instead of Home (below). Until it
   reaches Done nothing is written; the catalog defaults (plus values
   migrated from older preferences, the `netflix51` default) serve that run
   in memory. Demo mode skips setup.
2. A file that cannot be read as a config (bad JSON, unsupported value types,
   over 256 KB) is renamed to `config.json.bad-<UTC timestamp>`, a fresh default
   is written, and one error line is logged. Nothing is deleted.
3. If the disk can't be written, defaults are used for that run only.
4. Writes are atomic (temporary file, then replace). Demo mode never reads or
   writes the file.

The log category is `config` (`local.brad.htpcshell` subsystem).
