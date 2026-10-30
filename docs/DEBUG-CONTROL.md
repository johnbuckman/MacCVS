# MacCVS debug control channel

A token-gated local socket that lets a script drive MacCVS with no mouse: open working copies,
select files, run every command, fill and press the commit sheets, and save PNG snapshots of
MacCVS's own windows. Uses: regression tests, help-page screenshots, explainer videos. Same design
as SideStep's channel.

Code: `Sources/MacCVS/DebugControl.swift`.

## Turning it on

It is **off** unless a token exists. Either:

- set `MACCVS_DEBUG_TOKEN` in MacCVS's environment, or
- create `~/Library/Application Support/MacCVS/debug-token` containing a random string,
  `chmod 600` (a group/world-readable file is refused).

```bash
mkdir -p ~/Library/Application\ Support/MacCVS
(umask 077; openssl rand -hex 16 > ~/Library/Application\ Support/MacCVS/debug-token)
```

Then (re)start MacCVS. It listens on **127.0.0.1:51239** only. Delete the file and restart to turn
it off.

For screenshots, run a copy with another bundle id (so its projects, sort order and window sizes
don't touch your real settings), as `~/code/site-explainer/maccvs/build_demo_app.sh` does.

## Protocol

One command per line, `"<token> CMD args…"`; args are space-separated and `"double quotes"` group
words. Each command gets exactly one reply line: JSON for queries, `OK…` or `ERR…`.

| Command | What it does |
|---|---|
| `PING` | `PONG <version>` |
| `STATE` | JSON: root, directory, busy, status line, running command, selection, recents, items (name, status, revision), windows |
| `WINDOWS` | JSON list of visible windows (number, title, kind main/diff/log/sheet, key, frame) |
| `OPEN <path>` | As File ▸ Open Working Copy |
| `PROJECT <root> [dir]` | As clicking a project (and folder) in the column browser |
| `GO <dir>` | Go to a directory, relative to the working copy root |
| `ENTER <name>` | As double-clicking a row: folder → into it, file → its diff |
| `SELECT <name>…` / `SELECT none` | Select files in the list |
| `DO <action>` | `refresh`, `rescan` (local, no server), `update`, `commit` (opens the sheet), `diff`, `log`, `add`, `revert`, `up`, `clear-console`, `forget <root>`, `name-repo <root> <name>`, `check-updates` |
| `WAIT idle [seconds]` | Returns when no cvs command is running |
| `SORT name\|status\|rev [asc\|desc]` | The file list's sort |
| `VIEW hidden\|noncvs on\|off` | The View menu toggles |
| `DIFF side\|unified\|line\|word` | The diff window's toggles |
| `SPLIT <0…1>` | Where the diff window's centre divider sits |
| `SHEET message <text>` / `press` / `cancel` / `toggle <path>` | The open commit sheet (main window or diff window) |
| `TYPE message <text> [chars/s]` | The commit message, letter by letter (default 12/s), for video |
| `DIFFDO commit` / `discard <file#> <hunk#>` / `discard-all <file#>` | The frontmost diff window's Commit and Discard buttons (0-based) |
| `LOGDO diffs on\|off` | The history window's Show diffs |
| `SCROLL <window> <y\|bottom> [n]` | Scroll a window's biggest (or n-th) scroll view to y points from the top |
| `WINDOW <window> <w> <h> [x y]` | Content size in points, optional top-left |
| `CLOSE <window>` | Close a window |
| `SNAP <window> <path> [scale]` | PNG of a window drawn by the app itself (default scale 2), sheet included; see below |
| `ACTIVE on\|off` | SwiftUI draws controls as in the key window |
| `ACTIVATE` | Bring MacCVS to the front (macOS may refuse from the background) |
| `DEMO alias "<real>" "<shown>"` / `clear` / `list` | Display-only text substitution (paths in the project column, the window subtitle, the console and the running-command card) |
| `VIEWS <window>`, `SNAPVIEW <window> <class> <n> <path>` | Debugging SNAP: the title bar's view tree; one view rendered on its own |

`<window>` is `main`, `diff`, `log`, `key`, part of a title, or `#<window number>`.

## Snapshots (SNAP)

`SNAP` needs no Screen Recording permission and doesn't disturb the screen, and gives 2x images on a
1x display. Caching the whole window frame (`cacheDisplay`) leaves SwiftUI's layer-hosted content and
the macOS 26 glass toolbar blank, so the image is assembled:

1. the content view, cached on its own;
2. the toolbar's glass capsules, drawn (the Commit item's capsule in the accent colour);
3. each toolbar item cached on its own and tinted to the label colour (an inactive window greys
   them; alpha is kept, so disabled ones stay faint; Diff is drawn disabled when no file is selected);
4. the Commit button's white label, drawn when the window isn't key (macOS draws it dark grey then);
5. title and subtitle text, and the traffic lights in colour;
6. an attached sheet, dimming the window behind it.

Rendering a view with `cacheDisplay` while your own `NSGraphicsContext` is current gives wrong
results; work out anything that needs a render before setting the context.

## Gotchas

- MacCVS's own state (sort order, diff toggles) lives in `@AppStorage`, so `SORT` and `DIFF` just
  write UserDefaults.
- Commit sheets and the diff/log windows keep their own `@State`; their commands reach them as a
  `MacCVSDebug` notification that each view checks against its window.
- The history window's grey cards are `underPageBackgroundColor`, which is that dark on macOS 26.
