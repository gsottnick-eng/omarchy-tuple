---
name: tuplet-diagnose
description: Diagnose a problem with Tuplet, the Tuple bar widget for Omarchy, and, if it is Tuplet's bug and the user agrees, fix it with a pull request or report it upstream. Use when Tuplet's "Diagnose with my agent" button sends you here, or when a user says Tuplet, the Tuple bar widget, or Tuple on Omarchy misbehaves.
---

# Diagnosing Tuplet

Work from evidence. The goal is an honest account of what went wrong and who
can fix it, not a plausible story. Read `AGENTS.md` at the root of the plugin
folder first: it explains how the plugin is built and the rules any change must
keep.

## Where things are

- **The plugin folder** is the directory two levels above this file. Tuplet
  installed with `omarchy plugin add` is a git clone, so
  `git -C <plugin folder> remote get-url origin` names the repository to report
  to. Never assume a repository: if there is no remote, there is nowhere to
  send a pull request, so hand the user the finished text instead.
- **The version** is `version` in the plugin's `manifest.json`.
- **The Tuple client** is whatever `command -v tuple` finds. `tuple version` and
  `tuple state --format json` describe it without side effects.
- **The shell's log**: `qs list --all` names the running instance, and
  `qs log -i <instance>` prints it. Look for lines naming the plugin id from
  `manifest.json`.

## Rules while investigating

- **The user's Tuple account is real.** Every `tuple` command acts on it, and any
  command starts the Tuple daemon if it is down. Read state with
  `tuple state --format json`, `tuple contacts list --format json`, and
  `tuple rooms list --format json`. Do not start, join, or leave calls, share the
  screen, sign in or out, or stop the daemon unless the user asks you to, and
  never in a loop.
- **Reproduce with the fake client**, not the real one: `tests/fake-tuple/tuple`
  serves recorded output and records every command it gets. See "Testing" in
  `AGENTS.md`.
- **Never open the panel over IPC without a timeout.** If the compositor is
  wedged, an IPC call blocks forever.
- **Keep the user's data out of anything you write.** Contact names, emails,
  room names and URLs, and user ids from their account must not appear in an
  issue, a pull request, a fixture, or a commit. Replace them with the fake
  identities the fixtures use.

## Whose bug is it?

Be strict here. Tuplet is a thin layer over Tuple's command-line client and
Omarchy's shell, so most failures belong to one of those.

- **Tuplet**: the panel shows the wrong state, sends the wrong command, ignores
  an error, breaks the layout, or does not follow a rule in `AGENTS.md`.
- **Tuple's client** (report to Tuple, not here): `tuple` itself crashes, hangs,
  or answers wrongly when run by hand in a terminal with the same arguments.
- **Omarchy or Hyprland**: the bar, the shell, or the compositor fails the same
  way with Tuplet disabled (`omarchy plugin disable <id>`).

The "Known issues" section of `README.md` lists failures already traced to Tuple
or Hyprland. Check it before anything else.

If it is not Tuplet's bug, say whose it is, give the evidence, and stop.

## Fixing it

If it is Tuplet's bug and you can fix it:

1. Work in a clone of the repository from the remote, not in the installed
   plugin folder, so the user's working copy stays untouched.
2. Make the smallest change that fixes the cause. Add or adjust a test that
   fails without it.
3. Run the tests described in `AGENTS.md`. All must pass.
4. Show the user the diff, and the exact title and body of the pull request.

## Three conditions before anything leaves this machine

1. **It is a verified Tuplet bug**, established on evidence.
2. **The user has explicitly agreed**, after seeing exactly what will be posted.
   Never open a pull request or issue unprompted.
3. **`gh auth status` succeeds.** If `gh` is missing or signed out, do not
   install or authenticate it. Give the user the finished text to submit.

Search first, including closed items, so you do not file a duplicate:

```bash
gh search issues --repo <owner/repo> "<distinctive words>"
gh search prs --repo <owner/repo> "<distinctive words>"
```

Then either:

- **a pull request**: `gh repo fork --clone=false`, push a branch to the fork,
  and `gh pr create --repo <owner/repo>`; or
- **an issue**, when you could not fix it: `gh issue create --repo <owner/repo>`.

Include what happened, what was expected, how to reproduce it with the fake
client, the Tuplet version, `tuple version`, and `omarchy version`.

End the pull request or issue with a line naming the model and agent harness
that wrote it, so a reader knows it was machine-authored:

> Filed by \<model name\> via \<agent harness\>.

Use your actual names. If you are not certain of them, say so rather than
inventing a version string.
