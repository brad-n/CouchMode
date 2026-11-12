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
  A stream app's `reader` (`builtin`, the default, or `package`) chooses its
  Swift reader or its script package (`apps/<id>/`, see
  [add-a-streaming-service.md](add-a-streaming-service.md)); anything else
  means `builtin`, and a missing or unusable package falls back to it. It is
  read when the app starts.
- An id the catalog does not know is ignored but kept when the file is saved.
  An app whose `requires` is not met is hidden (one log line each), not removed.
  A repeated id counts once (the first).

## Lifecycle (`AppConfigStore`, `ConfigFile`)

1. No file: written from the catalog defaults (every default app, catalog
   order, each console's default folder), plus values migrated from older
   preferences (the `netflix51` default).
2. A file that cannot be read as a config (bad JSON, unsupported value types,
   over 256 KB) is renamed to `config.json.bad-<UTC timestamp>`, a fresh default
   is written, and one error line is logged. Nothing is deleted.
3. If the disk can't be written, defaults are used for that run only.
4. Writes are atomic (temporary file, then replace). Demo mode never reads or
   writes the file.

The log category is `config` (`local.brad.htpcshell` subsystem).
