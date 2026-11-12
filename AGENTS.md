# AGENTS.md

Guidance for AI coding agents (and people) working on CouchMode, a
full-screen, remote-driven TV launcher for a Mac mini. Read the ground rules,
then open the page you need.

## Ground rules

These are not style preferences. Breaking one means the change should not be
merged.

1. **Never circumvent DRM.** Playback always stays in each service's own web
   player, in its own page. Do not capture, decode, re-host, record or
   proxy video or audio, and do not touch license or key requests.
2. **One site action per user action. No crawling.** A reader does exactly the
   one thing the person just did on CouchMode's screen, on the real signed-in
   site, and reads the result. No prefetching, no walking every title, no
   background sweeps, no scheduled scraping.
3. **No secrets or personal data in the repo, and fixtures are synthetic.**
   No tokens, cookies, account ids, names, emails, hostnames, signing
   identities or real viewing history, in code, tests, logs, docs or
   screenshots. Test fixtures are invented data shaped like the real thing
   (see `Tests/CouchModeCoreTests/Fixtures`). Machine settings live in
   `scripts/local.env`, which git ignores.
4. **No game content.** No ROMs, disc images, BIOS files, emulator cores,
   keys, or game box art, in the repo or in tests. CouchMode only lists and
   launches files the user provides.
5. **Pure logic goes in `CouchModeCore`, with tests first.** Parsing, focus
   rules, routing, catalogs and formatting are pure and unit-tested before
   the app target uses them. The app target (`CouchMode`) only wires things
   to the system.
6. **Every file starts with an `// Owns:` header** saying what the file is
   responsible for, in plain words. If you can't say it in a few lines, the
   file is doing too much.
7. **Everything is bounded and nothing blocks the main thread.** Time limits
   on every wait, size limits on every list and read (`StreamLimits`), no
   synchronous I/O or sleeping on the main actor, and no unbounded loops or
   caches.

Also: do not change a reader's or the normal (non-demo) behavior as a side
effect of docs, demo or tooling work; keep `scripts/check.sh` green.

## Index

| Read | When |
|---|---|
| [agents/architecture.md](agents/architecture.md) | First. How the pieces fit: Core vs app, screens, readers, handoff. |
| [agents/conventions.md](agents/conventions.md) | Before writing code: headers, naming, bounds, tests, commits. |
| [agents/build-test-deploy.md](agents/build-test-deploy.md) | Building, running the checks, deploying to a media Mac. |
| [agents/add-a-streaming-service.md](agents/add-a-streaming-service.md) | Adding a service reader (Netflix and Hulu are the worked examples). |
| [agents/debug-channel.md](agents/debug-channel.md) | Driving and inspecting the running app remotely. |
| [agents/demo-mode.md](agents/demo-mode.md) | Screenshots and trials with invented content only. |

Human-facing overview: [README.md](README.md).
