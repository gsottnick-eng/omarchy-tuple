# Tuple for Omarchy

An [Omarchy](https://omarchy.org/) Quattro bar widget for
[Tuple](https://tuple.app/), the pair-programming app.

Tuple's Linux client is command-line only — no tray icon, no window. This
plugin installs that client for you and gives it the dropdown it does not ship
with: who is online, one-click calling, saved rooms, call controls, and the
client's own settings, all from the bar.

## Features

- **Bar** — a Tuple glyph that reflects the current state, optionally with a
  label reading `Sign in`, `In call`, or `Sharing`.
- **Contacts** — your Tuple contacts with online status and favourites. Click
  one to call.
- **Rooms** — save room URLs and rejoin them in one click. The Linux client has
  no room list of its own, so the plugin remembers them for you.
- **Call controls** — mute and screen sharing while you are in a call, plus
  right-click the bar icon to toggle mute without opening the panel.
- **Client settings** — every setting the Tuple client exposes, each rendered
  with the control its allowed values imply: a switch for on/off settings, a
  cycle button for enumerated ones, a text field for the rest. Settings sit
  directly below the header, since they are the first thing wanted after
  installing.
- **Audio devices** — pick the output and microphone without leaving the
  panel. Tuple's Linux client has no audio settings of its own, so this
  changes PipeWire's default device, via `pactl`. The section hides itself if
  `pactl` is not installed.
- **Call alerts** — a desktop notification and a sound when a call starts or
  ends. The Linux client is silent about both, which makes it easy to miss
  that a call connected. Turn it off in the plugin's settings.
- **Sign in and out** — the device-code login flow, without the terminal.

### Keyboard

With the panel open:

| Key | Action |
| --- | --- |
| `n` | Start a new call |
| `m` | Toggle mute (in a call) |
| `s` | Toggle screen sharing (in a call) |
| `e` | End the call |
| `a` | Add a room |
| `o` | Switch audio output |
| `i` | Switch microphone |
| `r` | Refresh |
| `,` | Open settings |
| `Esc` | Close the panel |
| `Tab` / `Shift-Tab` | Move to the neighbouring panel |

Arrow keys move the selection and `Enter` activates it. Letter keys are
suspended while a text field has focus, so typing a room URL or an auth code
does what you expect.

## Requirements

- Omarchy with the **Quattro** shell.
- `curl`, and either `sha256sum` or `shasum` — both standard on Omarchy.
- Optional: `pactl` (PipeWire) for audio device selection, and `notify-send`
  for call alerts. Both ship with Omarchy; without them those features simply
  do not appear.
- A Tuple account. Tuple is a paid product and its Linux client is in alpha.
- No manual Tuple install: the plugin installs the official client for you, as
  described below.

## Install

```bash
omarchy plugin add https://github.com/gsottnick-eng/omarchy-tuple.git --enable
```

The widget lands on the right of the bar. Move it with:

```bash
omarchy bar move io.github.gsottnick-eng.tuple --section left
```

Open the dropdown. If the Tuple client is not present, the panel offers to
install it. Then sign in — the panel shows a code to enter at Tuple's site, the
same flow as `tuple login` in a terminal.

## How the client gets installed

Tuple's own documented install command downloads the binary straight onto your
`PATH`. This plugin does not do that. `bin/tuple-install` instead:

1. resolves the current version from Tuple's release endpoint,
2. refuses to download from any host other than Tuple's own,
3. downloads to a temporary directory,
4. verifies the SHA-256 that Tuple publishes with the release, and
5. only then `install -m 755`s it into place.

Nothing runs as root, and the downloaded binary is never executed as part of
installing it. Run it yourself if you would rather not use the button:

```bash
./bin/tuple-install                 # installs to ~/.local/bin
./bin/tuple-install --check         # report the latest version, install nothing
./bin/tuple-install --dest ~/bin    # somewhere else
```

## Settings

Configure these through Omarchy's plugin settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| Refresh interval (seconds) | `20` | How often the panel re-reads client state. 5–600. |
| Install directory for the Tuple binary | `~/.local/bin` | Where `bin/tuple-install` puts the client. |
| Show status text next to the bar icon | off | Adds the text label beside the glyph. |
| Notify and play a sound when a call starts or ends | on | Desktop notification plus a sound, since the client signals neither. |

Saved rooms live alongside these, in Omarchy's `shell.json`.

## Remove

```bash
omarchy plugin remove io.github.gsottnick-eng.tuple
```

That disables the widget and deletes the checkout from
`~/.config/omarchy/plugins/`. Saved rooms and the settings above go with it.

Removing the plugin deliberately leaves the Tuple client itself in place, since
you may still want it in a terminal. To remove that too:

```bash
rm -f ~/.local/bin/tuple          # or wherever you pointed installDir
rm -rf ~/.local/share/tuple       # your Tuple session and client settings
```

## Notes and limitations

- **Tuple's Linux client is alpha.** It has no room list, and it reports far
  less about call state than the macOS and Windows apps do — the plugin infers
  what it can from the client's own output. Expect rough edges that belong to
  the client, not the plugin.
- **Joining a room accepts only Tuple's own URLs** — `https://tuple.app/c/…`
  and `https://production.tuple.app/c/…`. The client rejects anything else, so
  the panel says so rather than forwarding it.
- **Screen sharing can fail with `DbusScreenCast failed with
  UnsupportedVersion`.** This comes from Tuple's client, not the plugin: it
  asks for an `org.freedesktop.portal.ScreenCast` version that current
  portals no longer offer. If you hit it, switch the client's `capture`
  setting from `auto` to `x11` in the panel's settings section — that path
  goes through XWayland and sidesteps the portal.
- This project is not affiliated with, endorsed by, or supported by Tuple.
  "Tuple" is the trademark of its owner.

## Development

Parser tests need only Node:

```bash
node --test tests/model.test.mjs
```

The end-to-end panel tests load the real plugin against Omarchy's real
`Ui`/`Commons` components under a PySide6 stand-in for Quickshell, and drive it
the way a click would:

```bash
python3 -m venv .venv-harness
.venv-harness/bin/pip install PySide6
OMARCHY_SHELL=/usr/share/omarchy/shell \
  .venv-harness/bin/python -m unittest discover -s tests -p 'panel_test.py'
```

`OMARCHY_SHELL` points at an Omarchy shell tree; it defaults to
`/tmp/omarchy/shell`, so on a machine without Omarchy installed, clone one:

```bash
git clone -b quattro https://github.com/basecamp/omarchy.git /tmp/omarchy
```

A full run takes about four minutes, since every test boots a QML engine and
waits on real subprocesses. Tests needing a Tuple account run against
`tests/fake-tuple`, a scripted client reproducing the real one's output; the
two marked "real client" run against the official binary and skip if it is
absent.

To look at the panel rather than assert on it:

```bash
.venv-harness/bin/python tests/harness/main.py --shot panel.png --theme tokyo-night
```

Screenshots need a Nerd Font aliased to `monospace`, or every glyph renders as
a box.

## License

[MIT](LICENSE)
