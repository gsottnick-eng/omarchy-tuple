# Contributing to Tuplet

Pull requests are welcome, from people and from coding agents. This page says
what a PR needs to merge. [`AGENTS.md`](AGENTS.md) has the full background:
how the plugin is built, the Tuple client's quirks, and the rules below in
more detail.

## What must pass

Every pull request runs two checks automatically (`.github/workflows/tests.yml`).
Both must pass before it can merge:

| Check | What it runs | What it catches |
| --- | --- | --- |
| **Node tests** | `node --test 'tests/*.test.mjs'` | Parsing of Tuple's output, plus three repo-wide guards (below) |
| **Panel tests** | The panel suite, offscreen, against a fake Tuple client | The real panel and store, driven like clicks, checking the exact commands sent to Tuple |

The Node tests include three guards worth knowing before you start:

- **Nothing hardcoded about a user or machine** (`tests/portable.test.mjs`).
  Shipped files may not contain home paths, system paths, email addresses, or
  Tuple room links.
- **The panel only uses what the store has** (`tests/wiring.test.mjs`). Every
  `TupleStore.<name>` in `Panel.qml` must exist in `TupleStore.qml`.
- **The README's commands exist.** Every `omarchy-shell io.github.gsottnick.tuple <command>`
  the README documents must exist in the panel's IPC handler.

The Panel tests job also fails if a symlink is committed, because Omarchy's
plugin validator rejects them.

First-time contributors' checks start once the maintainer approves the run.
That's GitHub's default for pull requests from forks.

## Run the checks yourself

Node tests need Node 22 or newer and nothing else:

```bash
node --test 'tests/*.test.mjs'
```

The panel tests need Python, PySide6 below 6.12, and Omarchy's shell
components. On an Omarchy machine those are already at
`/usr/share/omarchy/shell`. Elsewhere, clone Omarchy and point
`OMARCHY_SHELL` at its `shell` folder.

```bash
python3 -m venv .venv-harness
.venv-harness/bin/pip install 'PySide6>=6.10,<6.12'
cd tests && ../.venv-harness/bin/python -m unittest panel_test
# elsewhere: OMARCHY_SHELL=/path/to/omarchy/shell ../.venv-harness/bin/python -m unittest panel_test
```

The panel tests never touch a real Tuple account: they run against
`tests/fake-tuple/tuple`. Please keep it that way. Real Tuple commands have
effects other people can see.

## Also expected

- One problem per PR, with a test that fails without your change.
- Bump `version` in `manifest.json` for anything users will receive.
- Keep commands as argument lists, never shell strings, and add no polling.
  `AGENTS.md` explains why.
- Bugs in Tuple's client, Hyprland, or Omarchy itself belong upstream. See
  [`UPSTREAM.md`](UPSTREAM.md). Don't post AI-written reports to projects that
  forbid them.
