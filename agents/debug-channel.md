# The debug channel

A small HTTP server for developing and testing CouchMode without someone at
the screen. It is **opt-in** and **localhost-only**.

## Turning it on

```
defaults write local.brad.htpcshell DebugControl -bool true
```

Then relaunch CouchMode. It listens on **127.0.0.1:47800 only**, never on a
network interface. Reach it with ssh:

```
ssh user@mac-mini.local 'curl -s http://127.0.0.1:47800/state'
```

Requests are bounded: at most 256 KB each, 20 seconds each, HTTP/1.0, one
request per connection. When it is on, the app asks once at startup for
Screen Recording permission, which only `/screen` uses. Turn it off with
`defaults delete local.brad.htpcshell DebugControl`.

Source: `Sources/CouchMode/DebugServer.swift` (routes), the parser in
`Sources/CouchModeCore/HTTPRequest.swift` (tested), and the coordinator
methods the routes call (`debug*` in `AppCoordinator.swift`).

## Routes

All `GET` unless noted. Replies are JSON of strings unless noted.

| Route | Does |
|---|---|
| `/state` | Current screen and its facts: `screen` (`home`, `console`, `allConsoles`, `detail`, `plexDetail`, `settings`, `bluetooth`, `streamHome`, `streamDetail`, `streamSearch`, `service`), focus, counts, loading. Poll this to wait for something. |
| `/intent?i=up\|down\|left\|right\|select\|back\|home\|info` | The same as a remote press. Replies with `/state`. |
| `/homehold?source=remote\|controller\|menu` | Home as the remote or Command-Delete (default), a controller's Home button, or a held Menu button. |
| `/open?service=<id>` | Open a service as the Home tile would (its stream screens if it has a reader). |
| `/stream?service=<id>&sample=1` | Open a service's stream screens on the built-in `SampleStreamSource` data, with no site involved. `sample=1` is required. |
| `/play?console=<id>&game=<file>` | Start (or resume) a game, as Play does. Starts a real game. |
| `/screen` | PNG of the real screen (any app in front). Needs Screen Recording permission. |
| `/snapshot` | PNG of what CouchMode itself is drawing (or the open service's page). |
| `/screensaver` | Start the screensaver now. |
| `/eval` (POST) | Run a JS function body (use `return`) in the **open** service page; JSON result. |
| `/peek?service=<id>` (POST) | Run a JS function body in that service's page *even behind a stream screen*. This is how readers are built. |
| `/media?service=<id>[&suspend=1\|0]` | WebKit's media state for a service's page (`none`, `playing`, `paused`, `suspended`); optionally suspend or resume it first. |
| `/plexlink?id=plex://...` | Open a title in a running Plex HTPC by its Plex id and fix its window. |
| `/inject?key=up\|down\|left\|right\|return\|esc\|space` | Type a key into the app in front, as the remote would. |
| `/accessibility` | Show macOS's Accessibility prompt; says whether it is granted. |
| `/ax?bundle=<bundle id>` | Another app's interface as Accessibility sees it (bounded text listing), to learn its layout. |
| `/bt?do=scan\|open\|menu\|hover[&name=...]` | The shell's view of the Bluetooth pane (`menu` and `hover` only read; nothing is pressed). |
| `/hid` | Raw HID gamepads and their last presses, to check a layout. |

Unknown routes are 404. A bad parameter is 400 or 404 with a short text reply.

## Recipes

Wait for a stream home to load:

```
ssh $HOST 'curl -s "http://127.0.0.1:47800/open?service=netflix" >/dev/null
until curl -s http://127.0.0.1:47800/state | grep -q "\"loading\":\"false\""; do sleep 1; done'
```

Walk and screenshot:

```
ssh $HOST 'curl -s "http://127.0.0.1:47800/intent?i=down"'
ssh $HOST 'curl -s http://127.0.0.1:47800/screen -o /tmp/shot.png' && scp $HOST:/tmp/shot.png .
```

Learn a page's data shape while building a reader:

```
ssh $HOST 'curl -s -X POST "http://127.0.0.1:47800/peek?service=netflix" \
  --data "return Object.keys(window.netflix.reactContext.models.graphql.data).length"'
```

Type into the on-screen keyboard: its keys are a grid of six columns
(a-f, g-l, m-r, s-x, y z 0-3, 4-9, then Space/Delete/Clear). Move with
`intent` and press with `select`; `back` clears the text.

## Safety

- It can start games and apps (`/play`, `/open` on Plex, `/inject`) and read a
  signed-in site's page (`/eval`, `/peek`). Leave it **off** except while
  developing, on a machine you control.
- Never put what `/peek` or `/eval` return into the repo, a fixture, a log or
  a screenshot. Print key names and counts, not contents.
- Don't play titles while testing on someone's real accounts.
- For published screenshots use [demo mode](demo-mode.md).
