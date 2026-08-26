# Handoff: Tuple plugin for Omarchy

This is a working, tested Omarchy Quattro bar widget that installs the Tuple for
Linux client and gives it the dropdown UI it does not ship with. Everything
described here is committed and green. What remains is publishing.

## Where things stand

Working and covered by tests:

- The bar widget, the dropdown panel, the client adapter, and the installer.
- 28 parser tests (`tests/model.test.mjs`) against output captured from the real
  Tuple client.
- 20 end-to-end panel tests (`tests/panel_test.py`) that load the real plugin
  against real Omarchy `Ui`/`Commons` components and drive it like a click
  would: install, sign-in, contacts, calling, mute/share, rooms, every setting
  control, sign-out.

Not done:

- **No `preview.png`.** Optional, but a listing without one looks unfinished.
- **Not submitted.** The repo now lives at
  `https://github.com/gsottnick-eng/omarchy-tuple` but is still private; it has
  to be public before the marketplace will take it.
- **Never run under real Quickshell.** See the caveat below. Still true.

Done since the first handoff:

- `README.md` at the repo root, with install *and* removal sections, written
  against the tree rather than against this document.
- `LICENSE` (MIT), matching `manifest.json`.
- The plugin id is now `io.github.gsottnick-eng.tuple`, matching the GitHub
  account that owns the repo.
- Fixed a status-message race; see "Traps" below.

The one caveat worth taking seriously: **the plugin has never run under real
Quickshell.** The test harness is PySide6 with hand-written stand-ins for the
Quickshell types (`tests/harness/qsmock/`). It loads Omarchy's genuine QML
components and executes real subprocesses, so the logic and the layout are
exercised for real, but layer-shell behaviour (focus grabs, popout handoff,
multi-monitor) is mocked. Install it on an actual Omarchy Quattro box and click
through it once before submitting.

## Layout

| File | Role |
| --- | --- |
| `manifest.json` | Plugin id `io.github.gsottnick-eng.tuple`, kind `bar-widget`, entry `Panel.qml`, settings schema |
| `Panel.qml` | Everything visual: bar button, dropdown, contacts, rooms, settings, install flow |
| `Service.qml` | Owns the client: polls status, runs commands, holds state |
| `Model.js` | Pure parsing and normalisation, no QML types, unit-testable in Node |
| `TupleIcon.qml` | Vector bar glyph |
| `bin/tuple-install` | POSIX sh installer: resolve version, download, verify SHA-256, install |

The split matters for the tests: `Model.js` is loaded straight into Node, and
`Service.qml` is found by the harness by its API rather than by `id`.

## What you need to know about the Tuple Linux client

This is the part that took the longest to work out, and none of it is
documented upstream. The client is CLI-only, alpha, and its full surface is:

```
tuple login | auth AUTH_CODE | logout
tuple call | join CALL_URL | new | end
tuple ls | favorite USER_ID | unfavorite USER_ID
tuple share/unshare | mute/unmute
tuple on | off | ui
tuple settings | set NAME VALUE
```

The non-obvious behaviours the plugin is built around:

1. **There is no room list.** The macOS and Windows apps show rooms; the Linux
   client has no equivalent command. Saved rooms are therefore plugin state,
   persisted into `shell.json` through `updateEntryInline`, not read back from
   the client.

2. **`tuple new` starts a call as a side effect.** It is the only way to learn
   your personal room URL, which makes it a trap: an earlier version called it
   during panel refresh to discover the URL and silently placed the user in a
   call every time they opened the dropdown. The URL is now captured only when
   the user explicitly starts a new call, then remembered in settings.
   `test_opening_the_panel_never_starts_a_call` guards this. Do not undo it.

3. **Calling takes two phases.** `tuple call` with no argument prints an
   interactive numbered picker and waits on stdin. The numbers are positional
   and do not match anything in `tuple ls`. So the plugin runs `tuple call` once
   with empty stdin to read the picker, maps the chosen contact to its number
   with `Model.pickerNumberFor`, then runs it again piping that number in. Two
   different row formats exist and both are parsed (`LIST_ROW` for `ls`, which
   yields the user id needed by `favorite`; `PICKER_ROW` for the picker).

4. **The daemon interleaves its log into command output.** When the daemon is
   not running, the CLI revives it and prints startup lines onto the same
   stream as the answer:

   ```
   17:00:28.608|8245|8245|info|connect failed with ConnectionRefused
   ```

   Those are pipe-delimited exactly like `tuple settings` output, so
   `Model.stripDaemonLog` has to run before anything else looks at the text.

5. **`join` is picky about URLs.** Only `https://tuple.app/c/<id>` and
   `https://production.tuple.app/c/<id>` are accepted. Anything else is
   rejected by the client, so the panel explains it rather than forwarding it.

6. **Call state is inferred, not reported.** There is no status command. The
   plugin derives in-call, muted, and sharing state from markers in the daemon
   log, and probes daemon liveness by looking for the abstract socket
   `@tuple-daemon` in `/proc/net/unix`.

7. **Settings are `name | value | description (allowed|values)` triples**, e.g.

   ```
   overlay | 1 | Show "overlay" annotation window when sharing screen (0|1)
   capture | auto | Screen capture mechanism (auto|x11|portal)
   ```

   The panel picks a control per setting from the parenthesised values: a
   toggle for `0|1`, a cycle for enums, a text field otherwise. Values live in
   `~/.local/share/tuple/0/`.

## Running the tests

Parser tests need nothing but Node:

```bash
node --test tests/model.test.mjs
```

The end-to-end tests need Omarchy's QML components and a Qt runtime:

```bash
git clone -b quattro https://github.com/basecamp/omarchy.git /tmp/omarchy
python3 -m venv .venv-harness
.venv-harness/bin/pip install PySide6
.venv-harness/bin/python -m unittest discover -s tests -p 'panel_test.py'
```

`OMARCHY_SHELL` overrides the default `/tmp/omarchy/shell`. The full run takes
about four minutes because each test boots a real QML engine and waits on real
subprocesses. Tests that need a Tuple account run against `tests/fake-tuple`, a
scripted client reproducing the real one's exact output; the two marked "real
client" run against the official binary and skip if it is absent.

To look at the panel rather than assert on it:

```bash
.venv-harness/bin/python tests/harness/main.py --shot panel.png --theme tokyo-night
```

Screenshots need a Nerd Font aliased to `monospace` or every glyph renders as a
box.

## What to do next

1. **Write the README.** Root-level, with install and removal instructions —
   the marketplace validator requires both explicitly. Cover
   `omarchy plugin add <git-url> --enable`, what the widget does, that it
   downloads the official Tuple client on first use, and how to remove it.

2. **Add a `LICENSE`** file, MIT, matching `manifest.json`.

3. **Validate locally** on an Omarchy machine:

   ```bash
   omarchy plugin validate .
   omarchy plugin add <git-url> --enable
   ```

   Then actually click through it: sign in, call someone, join a room, toggle
   settings. This is the step the mock harness cannot do for you.

4. **Take a `preview.png`** of the open dropdown.

5. **Make the GitHub repo public.** It exists at
   `https://github.com/gsottnick-eng/omarchy-tuple` and the id already matches
   the account. Ids are permanent and cannot be reused once listed, so do not
   change it again after the listing goes up.

6. **Submit.** The full procedure is in the marketplace repo's `SUBMISSION.md`
   (`HANCORE-linux/omarchy-plugin-marketplace`). It is a GitHub issue titled
   `[Plugin]: Tuple` with six headings in a fixed order. Suggested metadata:
   category `Developer Tools`, tags `bar`, `quickshell`. **Do not open the issue
   without the owner's explicit approval** — the submission guide requires the
   owner to confirm the ownership checklist personally.

### About the security baseline

An automated scanner checks the exact submitted commit. It flags direct
download-to-shell execution, which is why `bin/tuple-install` exists: Tuple's
own published command is `curl -L … -o ~/bin/tuple && chmod +x`, and piping a
download into a shell would be a blocking finding. The installer instead
resolves the version from Tuple's release endpoint, downloads to a temp dir,
verifies the SHA-256 that Tuple publishes with the release, refuses any host
outside Tuple's two known domains, and only then `install -m 755`s it. Nothing
runs as root and the payload is never executed during installation.

Expect a `review-required` disposition anyway, because the plugin declares an
installer capability. That is not a failure — a maintainer accepts the reported
capability. Do not try to hide it.

## Traps

- `Service.qml` is located by the harness through its API, not its `id`. Don't
  rename its public properties casually.
- `Model.js` must stay free of QML imports and of `instanceof Array` — settings
  arriving from QML are `QVariantList`, so use `Array.isArray` and the `toArray`
  helper.
- Set `PanelKeyCatcher.blocked` whenever a `TextField` has focus, or typing in
  the room or auth field triggers panel shortcuts. `Panel.qml` tracks this with
  an `editorsFocused` counter.
- Always guard `process.running` before assigning a new command; Quickshell
  ignores command changes while a process runs.
- On a multi-monitor machine the shell logs "QML IpcHandler ... Handler was
  registered but will not be used because another handler is registered for
  target io.github.gsottnick-eng.tuple" at every start. This is expected and
  is not worth fixing. Omarchy instantiates a bar widget once per monitor, so
  the IpcHandler is constructed once per monitor and only the first registers.
  Omarchy's own omarchy.agents, omarchy.audio, omarchy.indicators and
  omarchy.system-update log exactly the same line, as does Ui/Panel.qml
  itself. The plugin follows the first-party pattern (`manageIpc: false` plus
  its own handler, copied from omarchy.agents); deviating from it to silence
  the warning would be worse than the warning.
- Plugin settings do not always arrive as the type the manifest declares.
  `omarchy bar set <id> <key> <value>` writes the value as a string unless
  `--json` is passed, so a boolean the user turned on reaches the plugin as
  "true". Comparing with `=== true` therefore turns the setting off at the
  moment it was asked for -- `showLabel` shipped that way and never worked
  from the CLI. Read booleans through `Model.toBool`, never `=== true`.
- Audio device selection is PipeWire's default device, not a per-call route.
  Tuple's client exposes no audio settings at all, so there is nothing to
  route per call; changing the device changes it system-wide. Say so in any
  UI copy rather than implying Tuple knows about it.
- The real daemon log carries a source location the captured fixtures do not
  (`…|info|Engine.cpp:589|cli: ls` versus `…|info|connect failed …`). Anything
  parsing log lines positionally must tolerate both shapes.
- **The test harness used to leak Tuple daemons, and that is destructive.**
  Tuple's daemon is a singleton keyed on the abstract socket `@tuple-daemon`
  and outlives the CLI that revived it. A `fake=False` test that deleted its
  sandbox left a daemon holding the socket with its data directory gone
  underneath it; every later client attached to that daemon, so the
  developer's own sign-in went nowhere and `~/.local/share/tuple/0/log.txt`
  was never written — which silently disables all call-state inference.
  `Harness.stop_sandbox_processes` now kills processes whose executable lives
  inside the sandbox. Do not "simplify" it to `tuple off`: that stops
  whichever daemon holds the socket, quite possibly the developer's.
- Running the panel suite launches real browser windows, because
  `openLoginUrl` runs for real against the fixture's login URL. Expect stray
  tabs pointing at `production.tuple.app/start?code_challenge=fake0000`.
- Never assign `actionStatus` directly. `statusTimer` is armed by `note()` and
  clears `actionStatus` 3.2s later — it does not check whether the text it is
  about to erase is the text that armed it. Four call sites used to set
  `actionStatus =` directly, so a `note()` fired moments earlier would wipe a
  freshly-set message. "Finish signing in in your browser" was the worst
  casualty. Use `note()` for a toast that should expire, `progress()` for an
  in-flight status that should stay until its operation clears it.
- `omarchy plugin validate .` fails on a tree that has run the panel tests:
  the harness builds `tests/harness/.qsroot/qs/{Commons,Ui}` as symlinks into
  the Omarchy shell, and the validator rejects symlinks anywhere in a plugin
  folder. They are gitignored and never committed, so a fresh clone validates
  fine. `rm -rf tests/harness/.qsroot` before validating.
- Do not "modernise" `Service.qml`'s clipboard copy to `Util.execArgv`. That
  helper exists on the `quattro` branch but NOT in shipped Omarchy 4.0.0, so
  using it would break the plugin on installed systems. The current
  `bash -c` + `Util.shellQuote` form is correctly quoted and works on both.
