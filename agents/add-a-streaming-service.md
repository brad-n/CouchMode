# Add a streaming service (a reader)

A **reader** makes a service appear in CouchMode's own TV screens (home rows,
details, search, profile picker) instead of the plain website. It is a proxy:

> Each thing the person does on CouchMode's screen is the **same single
> action** on the real, signed-in website, read back.

Before you start, re-read the ground rules in [AGENTS.md](../AGENTS.md): no
DRM circumvention (a reader never plays anything), one site action per user
action (no crawling, no prefetching), synthetic fixtures only, everything
bounded.

Netflix and Hulu are the worked examples; keep them open while you work:

| Piece | Netflix | Hulu |
|---|---|---|
| Reader (app) | `Sources/CouchMode/NetflixSource.swift` | `Sources/CouchMode/HuluSource.swift` |
| Home parser (Core) | `NetflixHome.swift` | `HuluHome.swift` |
| Details parser | `NetflixDetails.swift` | `HuluDetails.swift` |
| Search parser | `NetflixSearch.swift` | `HuluSearch.swift` |
| Tests | `Netflix*Tests.swift` | `Hulu*Tests.swift` |
| Fixtures | `Fixtures/netflix-*.json` | `Fixtures/hulu-*.json` |

## A new service is a package

A reader is a **script package** in `apps/<id>/`, run by one generic reader
(`ScriptReader`, `Sources/CouchMode/ScriptReader.swift`). Prime Video is the
worked example (`apps/prime/`; Apple TV, `apps/appletv/`, reads from one quiet page with `reuseSitePage`; Hulu, `apps/hulu/`, shows a request made from
the title's page and a typed search; Disney+, `apps/disney/`, shows API requests
made from any signed-in page, profile forms and a restore step; Netflix, `apps/netflix/`, reads the page's own GraphQL cache and details panel, with no API additions: the "Who's watching?" gate is a home with `asksWhoIsWatching`, a season is chosen in the page's own picker by the name its option carries, and a profile switch follows the tile's or Netflix's own `/SwitchProfile?tkn=` link; Netflix 5.1 stays an app-installed page script, not part of the package); the Swift readers below (Netflix, Hulu,
Disney+, Apple TV, and Prime's `PrimeSource`) are the older way and stay until
each service is ported. A Mac chooses per service with the `reader` setting
(`builtin`, the default, or `package`; see [config.md](config.md)).

```
apps/<id>/manifest.json   id, version, reader API, hosts, time limits, the page each action opens
apps/<id>/reader.js       one script: `const reader = ...` with the functions below
```

`build-app.sh` copies each `apps/<id>/` into the app (`Resources/apps/<id>/`);
`PackageStore` loads it (a downloaded copy comes later).

### What the generic reader does (per user action)

1. Builds the action's page address from the manifest (`https` on the
   service's own `site.hosts`, or it refuses).
2. Opens it through `PageDriver` (one action at a time, latest wins, bounded).
3. Polls the page's **ready function** until it returns `true`.
4. Calls the **action function** inside the service's page and takes the
   JSON text it returns (`""` means "couldn't read").
5. Decodes that with `PackageDecoder` (Core), which drops anything that fails
   a check: ids are plain tokens, addresses are `https` on the service's
   hosts (images on `site.imageHosts`), text and numbers are bounded and
   `StreamLimits` caps every list. The script returns data; Swift validates it.

### manifest.json

```json
{ "id": "prime", "version": "1.0.0", "readerAPI": 1,
  "site": { "hosts": ["primevideo.com"], "imageHosts": ["media-amazon.com"] },
  "timeouts": { "load": 20, "ready": 10, "read": 12 },
  "pages": {
    "home":    { "open": "https://www.primevideo.com/", "ready": "homeReady" },
    "details": { "open": "{title.page}", "ready": "detailsReady" },
    "season":  { "open": "https://www.primevideo.com/detail/{season.id}", "ready": "detailsReady" },
    "search":  { "open": ".../search/?phrase={query}", "ready": "searchReady", "readyRequired": false, "readyTimeout": 8 },
    "more":    { "open": "https://www.primevideo.com/", "ready": "homeReady", "reuseIfOpen": true },
    "profile": { "open": "https://www.primevideo.com/", "ready": "homeReady", "confirmTimeout": 15 } },
  "playerShown": true }
```

- `readerAPI` must be `1` (the version of this page's contract).
- `pages.<action>.open` is an `https` address, or `{title.page}` (the title's
  own page), and may contain `{season.id}` (a plain id) and `{query}` (the
  normalized search text, percent-encoded). `ready` names a function in
  `reader.js`. `home` is required; an action with no page is unavailable
  (the screens fall back).
- `season.open` may also be `{title.page}` (Hulu): the season is a request made
  from the title's own page, not a page of its own. With `reuseIfOpen` the page
  is not reopened when it is already showing.
- `readyRequired: false` makes "never became ready" a valid empty answer
  (search with no results). `reuseIfOpen` (more) skips reopening when the
  service's page is already at that address. `confirmTimeout` (profile) is
  how long to wait for the chosen profile to show.
- `playerShown: true` says `reader.js` defines `playerShown()`.

Optional additions (reader API 1 stays version 1: a package that omits them
behaves as before):

- `pages.<action>.reuseSitePage: true` keeps the page that is already showing
  when it is a usable page of the service (on `site.hosts`, and not a player
  page, see `site.playerPaths`) and its ready function says yes within 2
  seconds; otherwise the action's page is opened. For a service whose reads
  are requests that run in any signed-in page of the site (Disney+).
- `pages.<action>.readTimeout` (seconds): the wait for that action's answer
  when it differs from `timeouts.read`.
- `site.profileForms`: first path parts of the service's own forms that only
  the person can finish (`["update-profile"]`). `site.playerPaths`: first path
  parts of its player pages.
- `pages.profile.settled`: a ready-style function, called with
  `{profileID}`, that says the switch has ended (the page is on a profile
  form, or the profile is current). Without it the reader waits for
  `profileIsCurrent`. When the settled page is one of `site.profileForms`, the
  switch is `needsPerson` (the form is left alone), else `profileIsCurrent` decides.
- `pages.restore`: the service's "who's watching" page, used after a switch
  ended on a profile form the person backed out of. `ready` says the picker
  is drawn, `settled` (called with `{profileID}`) that it closed, and
  `confirmTimeout` bounds the wait.

### reader.js: the API (version 1)

`reader` is one object. Every function runs in the service's page. Ready
functions return a boolean. Action functions return **JSON text** (use
`JSON.stringify`), `""` on any failure or when over about 900,000
characters, and never throw. Arguments arrive as one object.

| Function | Argument | Returns |
|---|---|---|
| `homeReady()`, `detailsReady()`, `searchReady()` | none | `true` when the page's data is there |
| `pageReady()` | none | (Disney+) ready for any request action; named by the manifest's `ready` |
| `home()` | none | a **home**, or `""` |
| `details({title})` | `title` is the row's title (a **title**) | a **details**, or `""` |
| `season({seasonID, title})` | the season's `id`, exactly as `details()` returned it, and the show's **title** (the season's page is open) | an array of **episodes** |
| `search({query})` | the normalized search text (the search page is open) | an array of **titles** |
| `more({cursor})` | the row's cursor, exactly as `home()` returned it | `{"titles": [title], "cursor": opaque or null}` |
| `chooseProfile({profileID})` | a profile `id` from the home | `true` when the page's own control was pressed (or already current) |
| `profileIsCurrent({profileID})` | same | `true` once that profile is current |
| `restoreProfile({profileID})` | the profile's name | `true` when the picker's tile was pressed (only with `pages.restore`) |
| `playerShown()` | none | `true` while the service's player is showing (only if `playerShown`) |

The vocabulary is `StreamCatalog.swift` as JSON; leave a missing value `null`:

- **title**: `id`, `name`, `kind` (`movie`, `show`, `episode`, `other`),
  `play` (the service's own player address), `page`, `episodeLabel`,
  `synopsis`, `year`, `rating`, `seasonsLabel`, `runtimeSeconds`,
  `resumeSeconds`, `tileArt`, `heroArt`.
- **home**: `profiles` (`id`, `name`, `avatar`, `isKids`, `isLocked`),
  `currentProfileID`, `hero` (a title), `asksWhoIsWatching`, and `rows`:
  `id`, `title`, `kind` (`continueWatching`, `ranked`, `standard`), `titles`,
  `totalCount` (set when the row holds more than it sent, so the screen asks),
  `cursor` (any JSON the script wants back in `more`, up to 8,000 characters;
  keep it free of anything but a paging position).
- **details**: `title` (the row's title filled in from the page), `seasons`
  (`id`, `name`, `episodes`: only the open season has them), `currentSeasonID`.
- **episode**: `id`, `name`, `number`, `synopsis`, `runtimeSeconds`,
  `resumeSeconds`, `play`, `art`.

Ids (title, row, episode, season) may hold dots (Apple TV's `umc.cmc.<id>`) and be up to 132
characters (a row id carrying a shelf id); only a season id may hold colons. Apple TV's `season` needs the
show's id to build its request, so API v1 now also sends `title` with `season` (additive; an older package
ignores it). Apple TV's `details` and `season` open no page of the title: they make the title's own
request from the shared quiet page.

A season `id` may also hold colons (Hulu's `<series>::<n>`); it only goes back
to the script as `seasonID`. `search` may do more than read: Hulu's types
`query` into the page's own search box, waits (bounded) for the list, and reads
it (nothing listed in time is `[]`, a box it can't type into is `""`). These
are additions to API v1 (an older package that ignores the arguments still
works), so v1 stays 1.

**What stays in Swift.** The stateful steps are in `ScriptReader`, not in the
package: the profile that was current when the last home was read
(`shownProfile`), Core's `UnfinishedSwitch` (the earlier profile, kept only
after a switch ended on a profile form), the restore on the next home read,
and the notice line ("Switched back to ..."), handed out by `takeNotice()`.
The package only supplies page checks (`profileSettled`, `pickerReady`,
`leftPicker`) and the two button presses (`chooseProfile`, `restoreProfile`).
The profile-form check itself is the manifest's `site.profileForms`, so Swift
can see the form without asking the page.

A request-based service (Disney+) keeps its API token inside its request
helper in `reader.js`: read from the page's storage there, used for the one
request, never returned. Its parity test also runs `extract.*` against a
stand-in `fetch` and asserts the token is sent but absent from the answer.

Prime's `reader.js` splits each function in two so the second half can be
tested without a page: `extract.*` reads the page into a small "read", and
`build.*` turns a read into the vocabulary (pure). Copy that split.

### Rules for a package

Same ground rules as the Swift readers, and they bind the script: it runs
only in the service's page, makes at most the one request the page itself
would make for that action (Prime's `more`; each of Disney+'s explore requests), reads and
returns no token, cookie or account data, and **never plays anything** (it
returns the title's `play` address; `AppCoordinator.playStream` hands it to
the service's player).

### Porting and testing a service

1. Learn where the page keeps its data (steps 2 and 4 below apply as they are:
   peek with the debug channel; synthetic fixtures only).
2. Write `apps/<id>/manifest.json` and `reader.js`. Port the parsing from the
   existing Swift parser rather than redesigning it.
3. **Parity test** (`PrimePackageParityTests.swift` and `DisneyPackageParityTests.swift`
   in `Tests/CouchModeCoreTests/` are the patterns): load `reader.js` in JavaScriptCore, run `reader.build.*` on
   each of the service's existing fixtures, decode with `PackageDecoder`, and
   assert it equals what the Swift parser makes from the same fixture. Add a
   test that runs `extract.*` against a small stand-in page.
4. Set `"reader": "package"` for the service in a test Mac's `config.json`
   and compare both readers on the device (step 7) before changing a default.

## The shape (the Swift reader, still used by the services not yet ported)

```
StreamSource (protocol, StreamSource.swift)
  home()                       -> StreamHome?
  details(for: StreamTitle)    -> StreamTitleDetails?
  episodes(in:of:)             -> [StreamEpisode]?
  search(_:)                   -> [StreamTitle]?
  more(in: StreamRow)          -> [StreamTitle]?     (nil is fine: not read yet)
  switchProfile(to:)           -> Bool
```

`nil` means "couldn't read": the screens fall back (home -> the website). The
shared screens never learn which service they are showing. The vocabulary
they use is in `Sources/CouchModeCore/StreamCatalog.swift`, with caps in
`StreamLimits`.

A reader holds a `PageDriver` (`PageDriver.swift`), which does one action at a
time in the service's own page: `open` an address, `waitFor` a script to say
yes, read a script's answer as `text`, or the whole `read(open:ready:script:)`.
A newer action supersedes an older one (latest wins), every step is bounded
by `PageDriver.Timeouts`, and a real failure is logged once with service,
action and step.

## Steps

### 1. Add the service

If it isn't in `apps/catalog.json` (see [config.md](config.md)), add a
`stream` entry with its id, name, home address and user agent; a Mac's
`config.json` lists the apps it shows, so add the id there too to see it
(a fresh config includes every default app). The id is what the
reader's constants use (`NetflixHome.serviceID`). Add its tile look in
`ServiceLook` (`HomeView.swift`): a generic SF Symbol and colors. Do not use a
service's logo.

### 2. Find where the page keeps its data

The goal is the **page's own data for the thing the person asked for**, with
as few requests as the page itself makes. Look, in this order:

1. **The page's own state.** Many sites hold their home in a JS object or an
   embedded JSON blob. Netflix: a normalized GraphQL cache at
   `window.netflix.reactContext.models.graphql.data` (records that point at
   each other with `{"__ref": key}`). Hulu: `__NEXT_DATA__` and a
   `window.store` for profiles.
2. **The request the page itself makes** when it loads that view. Hulu's home
   comes from one request to its discover service; the page's data names the
   address, and the reader makes that same request from the page (signed in,
   as the page does).
3. **The rendered page** (reading the DOM), only if neither exists. It is the
   most fragile.

To explore without rebuilding, use the [debug channel](debug-channel.md):

- `POST /peek?service=<id>` runs a script (a function body; use `return`) in
  that service's own page *even while a stream screen covers it*, and returns
  the result as JSON.
- Sign in once in the service's page (open the service, log in), then peek.
- Print shapes, not contents: key names, counts, types, the path to the list
  of rows. Look at one record's keys to learn what a title carries (id, name,
  year, rating, image address, progress, kind).
- Find the **ready** condition (a script that returns true once the data
  exists), the **play address** and **page address** for a title, how an
  **image address** is built, and how **profile** switching works.

Never copy a real response into the repo.

### 3. Write the pure parser in Core, test first

Create `<Service>Home.swift` (and `Details`/`Search` as needed) in
`Sources/CouchModeCore`, each starting with an `// Owns:` header. Pure: strings
and data in, `StreamHome` / `StreamTitleDetails` / `[StreamTitle]` out. No I/O.

Typical contents of `<Service>Home`:

- `serviceID`, and address builders: `playURL(...)`, `pageURL(...)`,
  `switchProfileURL(...)`, image address builders.
- `readyScript`: a JS function body returning true when the data exists.
- `extractScript`: a JS function body returning a **JSON string** of just
  what you need, `""` when absent, too long or on error. Cap its size
  (`maxCacheBytes` style) and wrap in `try/catch`. Quote any text you put
  into a script with `StreamJSON.jsString`.
- `parse(...) -> StreamHome?`: use the careful readers in `StreamJSON`
  (`object`, `objects`, `string`, `int`, `numericID`, `token`, `httpsURL`),
  which refuse odd ids and non-https addresses in one place. Build rows with
  the right `StreamRow.Kind` (`continueWatching`, `ranked`, `standard`), drop
  empty rows, and respect `StreamLimits` (`StreamHome.bounded`).

Write the tests *first* against a fixture (step 4). Assert: profiles and the
current one; row order and kinds; title facts (name, year, rating, progress
and "left" text); that bounds hold; that malformed or missing data returns
`nil` or an empty result rather than crashing; that play and page addresses
point at the service.

### 4. Make a public-safe, synthetic fixture

Put fixtures in `Tests/CouchModeCoreTests/Fixtures/`, named
`<service>-<what>.json` (see the existing ones). The rules:

- **Invented content only.** Invented titles, invented ids (`SYNTH...`,
  `70000411`-style numbers you made up), `Profile 1`..`Profile 5`, no real
  names, emails, account ids, tokens, cookies or device ids.
- Keep the **shape** of the real data (the same keys, nesting, `__ref`
  pointers, string-vs-number quirks) so the parser is tested against reality,
  but with a few small records, not hundreds.
- Include the awkward cases the real data has: a row with no titles, a
  title without art, a numeric id as a string, an unknown record type, a kids
  profile, a title that is partly watched.
- Image addresses: use `https://example.invalid/...`.
- Load with `Bundle.module.url(forResource: "Fixtures/<name>", withExtension: "json")`
  (see `NetflixHomeTests.swift`). The test target copies the folder as a
  resource.

### 5. Write the reader (app target)

Create `Sources/CouchMode/<Service>Source.swift`, `@MainActor final class
<Service>Source: StreamSource`, holding a `PageDriver(service:player:)`.
Each method is **one proxy action**:

```swift
func home() async -> StreamHome? {
    guard let json = await driver.read("home", open: Self.homeURL, ready: <Service>Home.readyScript,
                                       script: <Service>Home.extractScript) else { return nil }
    return <Service>Home.parse(json)
}
```

- `search(_:)`: open the service's search address (or type into its own
  search box), wait for results with `required: false` (no results is a valid
  answer: return `[]`, not `nil`), read the result cards.
- `details(for:)`: open the title's own page (`title.page`) and read its
  panel; for a show, include the seasons and the current one.
- `episodes(in:of:)`: choose the season the way the page's own picker does,
  then read again.
- `switchProfile(to:)`: the service's own profile-switch address or control;
  the next `home()` is that profile's.
- `more(in:)`: return `nil` unless the page itself loads more when a person
  reaches the end of a row (one action, no paging ahead).
- Use `driver.begin(...)`, and give a longer `Timeouts` only where a page
  needs it. Do not loop, retry in the background, or touch more than the one
  page the person's action needs.
- A reader never calls anything that plays. Playing is
  `AppCoordinator.playStream` handing the title's `play` address to the
  service's own player.

### 6. Register it

In `main.swift`, next to Netflix and Hulu:

```swift
if let service = AppServices.all.first(where: { $0.id == <Service>Home.serviceID }) {
    coordinator.registerStreamSource(<Service>Source(service: service, player: player))
}
```

Opening that service then shows the shared screens (`showStreamHome`), and
falls back to its website if `home()` returns `nil`.

### 7. Verify on a device

Unit tests can't see a real site. On a Mac that has the service signed in:

1. `scripts/check.sh && scripts/build-app.sh && scripts/deploy.sh`.
2. Enable the [debug channel](debug-channel.md). `GET /open?service=<id>`;
   `GET /state` until `loading` is false and `rows` is non-zero.
3. Walk it with `GET /intent?i=...` (down, right, select, back) and take
   `GET /screen` screenshots. Check: rows and hero, a title's details,
   seasons and episodes, search with the keyboard, the profile picker.
4. Check the **handoff**: Select on a title's Play loads the service's player
   in its own page; Back returns to the screen you came from. **Don't play
   titles on a shared or live setup.** If you must check handoff, stop right
   after the player page loads.
5. Check the **fallback**: break the ready script on purpose; the service
   should open its website, not a blank screen.
6. If the screens look wrong, `POST /peek?service=<id>` the page again; sites
   change.

If a screenshot will be published, use [demo mode](demo-mode.md); never
publish a screenshot of a real account.

### 8. Finish

- `scripts/check.sh` passes.
- The reader's header lists, as Netflix's does, which of the service's own
  pages each action opens and reads.
- Update README's limitations if the reader doesn't cover something (for
  example "More in a row").
