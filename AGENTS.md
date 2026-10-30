# Notes for agents working on Tuplet

Tuplet is an Omarchy bar widget for Tuple, the pair-programming app. It installs
Tuple's Linux client and drives it from a dropdown: rooms, people, and call
controls. Many people run it on their own machines, so every change has to work
on any Omarchy install, with any Tuple account.

Diagnosing a user's problem? Start with `agents/diagnose/SKILL.md`.

## Layout

| File | Role |
| --- | --- |
| `manifest.json` | Plugin id, version, the two user settings |
| `qmldir` | Declares `TupleStore` a singleton |
| `TupleStore.qml` | Every Tuple process, all state, every command |
| `Panel.qml` | The bar button and dropdown; view only |
| `Model.js` | Pure parsing of the client's JSON; no QML imports |
| `TupleIcon.qml` | The bar glyph |
| `bin/tuple-install` | Downloads Tuple, verifies its SHA-256, installs it |
| `agents/diagnose/SKILL.md` | How a user's agent diagnoses and reports problems |

## Rules every change keeps

1. **Nothing hardcoded about the user or the machine.** No usernames, emails,
   room links, contact names, or home paths in code, settings, or fixtures. The
   binary is found on `PATH`, then in `$XDG_BIN_HOME` or `$HOME/.local/bin`, read
   from the environment. Who is signed in, and every room and person, comes from
   the client at run time. The only fixed addresses are Tuple's release endpoint
   and download hosts in `bin/tuple-install`, which form a security allowlist.
2. **The plugin stores nothing about the account.** No saved rooms, no personal
   link, no sign-in code. The authorization code goes to `tuple auth` as a
   single argument and is never kept, logged, or shown, even in an error.
3. **Commands are argument lists, never shell strings.** The single `sh -c`
   (finding the binary) takes no user input.
4. **No polling.** The client pushes complete snapshots on `tuple state follow`,
   `tuple contacts follow` and `tuple rooms follow`. Screen sharing only appears
   in `tuple state follow --raw`, so that stream runs only during a call.
5. **One set of processes per machine.** Omarchy builds a bar widget once per
   monitor; `TupleStore` is a singleton so the streams are not duplicated.
6. **Every `tuple` command starts the daemon** if it is down, the follow streams
   included. Stop closes the streams before stopping the daemon, and nothing
   restarts them until Start.
7. **No dependencies beyond a stock Omarchy:** the `tuple` binary at run time,
   `curl` and `sha256sum` to install, `wl-copy` to copy a link, `notify-send` for
   call alerts.
8. **User-controlled text renders as plain text.** Contact and room names are
   chosen by other people; every `Text` showing them sets
   `textFormat: Text.PlainText`.

## The Tuple client

Tuple for Linux v2026_10_23.0 and later; older clients lack the JSON commands
this plugin is built on. Behaviour that is not obvious from `tuple --help`:

- `--format json` works everywhere. Errors arrive on stderr as
  `{"error": "..."}`. The older verbs (`login`, `auth`, `logout`, `start`,
  `stop`, `share`, `unshare`) print plain text and reject `--help`.
- A signed-out `state` reports `user.id` as `0`, not a null user.
- `call start <person>` blocks until the other side answers (exit 0) or the call
  ends (exit 2), so it runs outside the shared command queue.
- People are identified by email or full name. The numeric id does not resolve.
- `share` and `unshare` are deprecated with no replacement. The panel offers
  Share only while `tuple --help` still lists them.
- The daemon re-executes the binary and keeps its parent's arguments, so it
  appears in `ps` as a second `tuple state follow`.
- In `rooms list` / `rooms follow` output, `members` is who is in the room
  right now, not the room's membership; it is `[]` when the room is empty.
- `active_call` is not occupancy. It can be `false` on an occupied room, and
  its real meaning is unknown, so the plugin never relies on it.
- **`tuple share` blocks the daemon**: after "screen share initiated", the
  daemon's main thread waits on the desktop portal picker, and every other
  `tuple` command (and the follow streams) stalls until a screen is picked or
  the picker closes.
- **A dead Xwayland hangs the daemon too**: after Xwayland crashes, it keeps
  listening on `/tmp/.X11-unix/X0` but never accepts again, so `tuple share`
  blocks forever; only a re-login recovers. Hyprland never restarts Xwayland.

## Testing

Parser tests, Node only:

```bash
node --test 'tests/*.test.mjs'
```

Panel tests load the real plugin with Omarchy's real `Commons` and `Ui`
components, offscreen, against a fake client:

```bash
python3 -m venv .venv-harness
.venv-harness/bin/pip install 'PySide6>=6.10,<6.12'
cd tests && ../.venv-harness/bin/python -m unittest panel_test
```

PySide6 stays below 6.12: Qt 6.12's QtQuick exports its own `Color` singleton,
which shadows Omarchy's in this harness. Quickshell itself is not affected.
`OMARCHY_SHELL` points the harness at a shell other than
`/usr/share/omarchy/shell`.

- `tests/fake-tuple/tuple` serves `tests/fixtures/` and appends every command
  it receives to `$FAKE_TUPLE_STATE/argv`. Assert on that file to check what
  the plugin ran.
- `tests/fixtures/` is real client output with every identity replaced by fake
  ones (`Ada Lovelace`, `@example.com`, `tuple.example`). New fixtures get the
  same treatment before they are committed.
- **Do not test against a real account in a loop.** Every real command has
  visible effects for the account owner: the daemon starts, calls ring, browser
  tabs open. Use the fake client for anything repeated.
- `omarchy plugin validate` rejects symlinks, and `.venv-harness/` and
  `tests/harness/.qsroot/` contain some. Validate a fresh clone, not a working
  tree that has run the panel tests.
- Loading the plugin into a live shell: Quickshell caches QML files, so
  `TupleStore.qml` and `Model.js` changes need `omarchy-restart-shell`, not just
  a copy. Open the panel over IPC only with a timeout.

## Pull requests and issues

- Keep diffs small and focused on one problem. Add a test that fails without the
  change.
- Run both test suites; both must pass. GitHub Actions (`.github/workflows/tests.yml`)
  runs them on every PR, and `main` only accepts PRs whose Node and Panel checks pass.
- Do not change the plugin id in `manifest.json` once the plugin is listed in the
  marketplace, where ids are permanent. It changed once before listing, from
  `io.github.gsottnick-eng.tuple`, when the GitHub account was renamed.
- Bump `version` in `manifest.json` for any change users will receive.
- Issues labelled `tuple-release` are opened by
  `.github/workflows/tuple-release-watch.yml` when Tuple ships a new Linux
  client. Work through their checklist in a PR.
- Machine-authored pull requests and issues end with
  `Filed by <model name> via <agent harness>.`
- Bugs in Tuple's client, Hyprland, or Omarchy itself belong upstream.
  [`UPSTREAM.md`](UPSTREAM.md) tracks each one, who must fix it, and the drafts
  waiting to be sent.
