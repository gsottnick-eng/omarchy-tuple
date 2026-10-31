# Omatuple

Tuple, the pair-programming app, in the Omarchy bar. Omatuple installs Tuple's
Linux client for you and gives it the dropdown it doesn't ship with: your
rooms, your people, and call controls, one click from the bar.

![The Omatuple dropdown](preview.png)

> [!WARNING]
> **Sharing your screen crashes Xwayland**, a bug in Tuple's Linux client and
> Xwayland, not Omatuple. Every X11 app you have open closes (Steam, Zoom,
> games), and they won't start again until you log out and back in. Calls
> work, and so does watching someone else's screen until you share. Omatuple
> warns you before each share.
> Details in [Known issues](#known-issues).

## Features

- **Rooms**: one scrolling list with your room first, then favorites A to Z,
  then rooms in use and everything else. Rooms people are in show who is there
  on a second line. One click to join.
- **People**: everyone, with favorites and anyone online or in a call at the
  top. Click to call them, or to join the call they're in.
- **Search**: one field finds any room or person. Paste a call link into it
  and press Enter to join.
- **Calls**: mute, share your screen, leave, and answer incoming calls. The bar
  icon shows when you're in a call and muted.
- **Viewing others' screens**: when someone shares, Tuple opens its own viewer
  window, with buttons to draw on their screen or take control. Tested with a
  macOS sharer: both work.
- **Install and update**: downloads the official client and checks it against
  Tuple's published checksum. Offers updates when Tuple releases one.
- **Diagnose with my agent**: the bug button in the panel hands a problem to
  your default coding agent, which can find the cause and, with your approval,
  open a pull request or issue here. See [Getting help](#getting-help).

| In a call | Signing in |
| --- | --- |
| ![In a call, muted and sharing](screenshots/in-call.png) | ![Pasting the authorization code](screenshots/sign-in.png) |

Nothing is polled: Tuple's client pushes every change, so the widget costs
nothing while nothing happens. It runs once for all your monitors.

### Keyboard

With the dropdown open:

| Key | Action |
| --- | --- |
| Arrows, Enter | Move through rooms and people, join or call |
| `/` | Search |
| `m` | Mute or unmute |
| `s` | Share or stop sharing your screen |
| `l` | Leave the call |
| `a` | Answer an incoming call |
| Esc | Close |

Right-click the bar icon during a call to mute.

### Bind keys to calls

```bash
omarchy-shell io.github.gsottnick.omatuple mute
omarchy-shell io.github.gsottnick.omatuple leave
omarchy-shell io.github.gsottnick.omatuple toggle
```

Also `share`, `accept`, `join <link>`, `status`, `open`, `close`, and `diagnose`.

## Requirements

- Omarchy with the Quickshell bar.
- x86_64 or arm64.
- `curl` and `sha256sum` to install the client, both part of Omarchy.
- A Tuple account.

## Install

Omatuple is listed in the
[Omarchy plugin marketplace](https://plugins.omarchy.org/plugin.html?id=io.github.gsottnick.omatuple).
Install it from there, or from the terminal:

```bash
omarchy plugin add https://github.com/gsottnick/omatuple.git --enable
```

The widget lands on the right of the bar. Move it with:

```bash
omarchy bar move io.github.gsottnick.omatuple --section left
```

Installed it before it was called Omatuple, under the id
`io.github.gsottnick.tuple` or `io.github.gsottnick-eng.tuple`? Remove it
under that id and add it again; your Tuple sign-in is unaffected:

```bash
omarchy plugin remove io.github.gsottnick.tuple   # or io.github.gsottnick-eng.tuple
omarchy plugin add https://github.com/gsottnick/omatuple.git --enable
```

Then update any keybindings that call `omarchy-shell` with the old id.

Open the dropdown. If Tuple isn't installed, it offers to install it. Then
**Sign in**: your browser opens Tuple's sign-in page, and you paste the
authorization code it gives you back into the panel. Omatuple hands the code
straight to Tuple's background service over a private socket. It never stores
the code, and never puts it on a command line where other accounts on the
machine could read it.

### How the client gets installed

Tuple's own install command downloads the binary straight onto your `PATH`.
`bin/tuple-install` is more careful. It:

1. asks Tuple's release service for the current version,
2. refuses to download from any host other than Tuple's own,
3. downloads to a temporary directory,
4. checks the SHA-256 Tuple publishes with the release, and
5. only then puts it in `$XDG_BIN_HOME`, or `~/.local/bin` if that isn't set.

Nothing runs as root, and the download is never executed while installing.
Run it yourself if you'd rather:

```bash
./bin/tuple-install                 # install or update
./bin/tuple-install --check         # print the latest version, install nothing
./bin/tuple-install --dest ~/bin    # somewhere else
```

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Show status text next to the bar icon | off | "In call", "Muted" or "Sharing" beside the icon |
| Notify when a call starts or ends | on | A desktop notification, since the client shows none |

From the command line:

```bash
omarchy bar set io.github.gsottnick.omatuple showLabel true
omarchy bar set io.github.gsottnick.omatuple callAlerts false
```

Omatuple stores nothing about your account. Your rooms, people, and who you're
signed in as come from Tuple every time.

## Remove

```bash
omarchy plugin remove io.github.gsottnick.omatuple
```

That removes the widget and its settings. The Tuple client stays, since you
may still want it in a terminal, and its background daemon keeps running until
you log out; `tuple stop` stops it now. To remove the client too:

```bash
tuple stop
rm -f "$(command -v tuple)"
rm -rf ~/.local/share/tuple       # your Tuple session and client settings
```

## Known issues

These are bugs outside Omatuple — see [`UPSTREAM.md`](UPSTREAM.md) for the full
list, who has to fix each one, and what we're waiting on. The big ones:

- **Starting a screen share crashes Xwayland**, closing every X11 app you have
  open (Steam, Zoom, games). It happened every time in testing, the moment
  Tuple's client started the share. Hyprland does not restart Xwayland, so X11
  apps hang until you log out and back in. Omatuple warns you before each share
  (you can turn that off), and refuses to share again after a crash until you
  log back in. Seen with Tuple v2026_10_23.0 and Xwayland 24.1.14.
- **After you share your own screen, you can't watch anyone else's until you
  log out and back in.** Tuple's viewer window is an X11 app, and sharing has
  crashed Xwayland. Viewing works fine before you share. Logging out closes
  your open apps, so share when that's acceptable.
- **Screen sharing needs the client's `capture` setting on `auto`**, Tuple's
  default. The `x11` setting fails under Hyprland with
  `X11GetImage failed with UnexpectedX11Event`. If you changed it, set it back:
  `tuple set capture auto`.
- **`share` and `unshare` are deprecated** in Tuple's client, with no
  replacement yet. Omatuple hides the share button if a future client drops
  them. To be resolved by **Tuple**.

## Getting help

Click the bug button in the panel, or run
`omarchy-shell io.github.gsottnick.omatuple diagnose`. Omarchy opens your default
coding agent with what Omatuple knows about the problem and a guide for
diagnosing it ([`agents/diagnose/SKILL.md`](agents/diagnose/SKILL.md)). The
agent works out whether it's Omatuple's bug, Tuple's, or Omarchy's. If it's
Omatuple's and it can fix it, it prepares a pull request here. Nothing is posted
without your approval, and your contacts and rooms are kept out of anything it
writes.

Set a default agent first if you haven't: `omarchy default agent <name>`.

You can also [open an issue](https://github.com/gsottnick/omatuple/issues).

## Development

Contributions are welcome: open a pull request. Both test suites run
automatically on every PR and must pass before it can merge;
[`CONTRIBUTING.md`](CONTRIBUTING.md) says exactly what they check and how to
run them yourself.

[`AGENTS.md`](AGENTS.md) has the layout, the rules every change keeps, and how
to run the tests. It is written for coding agents and works for people too.

```bash
node --test 'tests/*.test.mjs'
```

## License

MIT. This project is not affiliated with, endorsed by, or supported by Tuple.
"Tuple" is the trademark of its owner.
