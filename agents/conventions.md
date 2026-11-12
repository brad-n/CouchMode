# Conventions

## Files and headers

- Every Swift file starts with a header comment that begins `// Owns:` and
  says, in plain words, what the file is responsible for (and, if useful,
  what it deliberately is not). One responsibility per file. If you need
  "and" three times in the header, split the file.
- Split by responsibility, not by size.
- New files go in `Sources/CouchModeCore` if pure, else `Sources/CouchMode`.
  Tests go in `Tests/CouchModeCoreTests`; fixtures in `Fixtures/`.

## Core versus app

- Pure first: write the failing test in Core, then the code, then wire it in
  the app. Core imports Foundation only. No `AppKit`, `WebKit`, `SwiftUI`,
  disk, network, clocks or randomness that a test can't control (pass them
  in).
- Core types are `public` and `Sendable`; the app target imports
  `CouchModeCore`. Test with `@testable import CouchModeCore`.
- The app target adapts the outside world (web pages, processes, files,
  devices) to Core values. It does not make decisions Core could make.

## Bounds, always

- Every wait has a time limit; every list, read and cache has a size limit
  (`StreamLimits` for streaming content; see `PageDriver.Timeouts`,
  `DebugServer.Limits`). Prefer a named constant in a small `enum`.
- Nothing blocks the main thread. App code is `@MainActor` and `async`; no
  `sleep`, synchronous network or file reads of unbounded size on it.
- A newer user action supersedes an older one still in flight (latest wins);
  a superseded action is not a failure and is not logged as one.

## No silent rescue

- A failed read returns `nil` / an empty result and is logged once with the
  service, action and step. Do not paper over a violated assumption with a
  default that hides it. The caller decides the fallback (for a stream home:
  open the service's website).
- Never log tokens, cookies, addresses with credentials, or page contents.

## Style

- Swift 5.9, 4-space indent, no force unwrap/try outside tests and genuine
  constants (a literal `URL(string:)`), line length around 140.
- Names say what a thing is for the *player* (`StreamHome`, `ShellIntent`),
  not the framework. No service branding in shared code: shared screens are
  service-neutral. Service-specific names belong to that service's reader and
  parser.
- Comments say why, not what; keep them neutral and factual (no jokes, no
  stories about specific people or devices).
- Design tokens (colors, type, spacing, motion) come from `DesignSystem.swift`
  (`DS`). Screens are laid out for 1080 points tall and scaled.

## Tests

- Fixtures are **synthetic**: invented titles, ids and names shaped like the
  real data. Never paste a real response. See
  [add-a-streaming-service.md](add-a-streaming-service.md).
- Test names say the behavior (`testRowsInOrderWithKinds`). Test the
  edges: empty, oversized, malformed, wrong type.
- No network, no sleeping, no real clock in tests.

## Content rules

- No game content (ROMs, BIOS, cores, box art), no third-party artwork, no
  personal data. Screenshots are taken in [demo mode](demo-mode.md).
- Playback and DRM are off limits: see AGENTS.md rules 1 and 2.

## Commits

- Small, one reason each, message says why. Keep `scripts/check.sh` green on
  every commit. Do not commit `scripts/local.env`, `dist/`, `.build/`.
