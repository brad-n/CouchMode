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

## The shape

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

If it isn't in `ServiceCatalog` (`Sources/CouchModeCore/Service.swift`), add
a `Service` with its id, name, home address and user agent. The id is what the
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
if let service = ServiceCatalog.all.first(where: { $0.id == <Service>Home.serviceID }) {
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
