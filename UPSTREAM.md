# Upstream problems

Bugs outside Omatuple that we are waiting on. One row per problem; drafts for
each upstream follow the table. File links land here once reports are filed.

| Problem | What the user sees | Who must fix it | Status | Omatuple's workaround |
| --- | --- | --- | --- | --- |
| Xwayland segfaults (null deref) the moment Tuple starts a screen share | Every X11 app closes at once; the session and Wayland apps survive. Verified: both shares started on Hyprland on 2026-10-29 crashed Xwayland in the same second; it also crashed once with Tuple idle | X.org/Xwayland (freedesktop GitLab), and Tuple's Linux client for what it sends | draft below | Omatuple warns before every share, with a "Why does sharing break my desktop?" help section. **Remove when fixed:** delete everything tagged `XWAYLAND-SHARE-WORKAROUND` in the code and tests, and the `warnBeforeSharing` setting in `manifest.json` |
| Tuple's screen viewer is an X11 window | Viewing someone's screen works (tested 2026-10-29 with a macOS sharer: drawing and control both work, Xwayland survived), but it needs Xwayland, so after a share has crashed Xwayland you can't view until you log back in | Tuple (a native Wayland viewer would avoid it) | not reported | documented in README |
| Hyprland never restarts Xwayland after it dies | After any Xwayland crash, every X11 app hangs on connect until you log out and back in; `hyprctl` toggling `xwayland.enabled` does not recover it | hyprwm/Hyprland | not reported: Hyprland only accepts reports written by a person (see below) | Omatuple refuses to share when a core dump says Xwayland died this session, and says why |
| Tuple daemon blocks completely while the portal screen picker is open | Every `tuple` command and follow stream stalls until a screen is picked or the picker closes | Tuple | draft below | Omatuple closes the panel before sharing, explains the wait, and refuses other commands while the picker is up |
| Tuple daemon hangs connecting to a dead Xwayland and never recovers | After an Xwayland crash the daemon must be killed; it never recovers on its own | Tuple | draft below | none |
| The overlay's sharing border can't be thinner or rounded | Square purple corner brackets, about 12 px thick on a 4K screen, drawn by Tuple's own `tuple-overlay` layer (verified 2026-10-29); no setting changes them | Tuple | draft below | none |
| Annotation colors aren't per person like on macOS | Everyone draws in the same color, so you can't tell who drew what | Tuple | draft below | none |
| Viewer annotations don't render on the Linux host at all | Verified 2026-10-29 from a macOS viewer: pencil strokes, GIFs and text never appear on the sharer's screen, though the client logs the viewer switching to the pencil and the overlay layer exists | Tuple | draft below | none |
| The viewer's red remote cursor overlaps their pencil | You can't see what the pencil points at while controlling | Tuple | draft below | none |
| Remote control drives the host's real pointer instead of a separate one, and host movement steals it back | The person sharing fights their own pointer; moving the mouse hijacks control back. Verified 2026-10-29; the client injects input through Wayland (it kept working after Xwayland died), into the one system pointer | Tuple (may also need compositor support) | draft below | none |
| The remote cursor is oversized and doesn't scale with resolution | A huge pointer on high-DPI screens | Tuple | not reproduced: the size looked fine in the 2026-10-29 test; reopen if it comes back | none |
| No annotation toolbar for the person sharing | You can't pick tools or undo what viewers drew while sharing | Tuple | draft below | none |
| `share` and `unshare` are deprecated with no replacement | Screen sharing hangs on deprecated verbs; a future client could drop them with nothing to take their place | Tuple | draft below | Omatuple hides Share if `tuple --help` stops listing the verbs |
| The client records no "favorited at" time, so favorites can't sort by recency | Favorites can only sort alphabetically | Tuple | draft below | Omatuple sorts favorites A to Z |

## Draft: report to Tuple support

Sends to Tuple support (no public issue tracker). Versions: Tuple Linux client
v2026_10_23.0, Hyprland 0.56.2, xdg-desktop-portal-hyprland 1.4.1,
hyprland-preview-share-picker 0.2.1, NVIDIA RTX 5080, two monitors, Arch Linux.

1. **The daemon blocks completely while the portal picker is open.**
   What happened: `tuple share` prints "screen share initiated" at once, then
   the daemon asks the desktop portal and Hyprland's share picker opens. While
   the picker is up, the daemon's main thread is blocked: every other `tuple`
   command, and the `state`/`contacts`/`rooms` follow streams, stall until a
   screen is picked or the picker closes.
   Expected: the daemon keeps serving commands while its UI waits for the
   picker.
   Reproduce: start `tuple state follow --format json` in one terminal, run
   `tuple share` in another, and watch the stream stall until the picker
   closes.

2. **The daemon hangs forever connecting to a dead Xwayland.**
   What happened: Xwayland segfaulted and Hyprland did not restart it. Hyprland
   kept `/tmp/.X11-unix/X0` listening but nothing accepted connections, so every
   new X11 client hung on connect — and the Tuple daemon hung too, blocking
   permanently. It had to be killed. Logging out and back in was the only
   recovery.
   Expected: the daemon should time out, report the failure, and recover.
   Reproduce: crash Xwayland (see the Xwayland draft), then run any `tuple`
   command.

3. **The overlay's sharing border can't be styled.** The full-screen annotation
   layer (namespace `tuple-overlay`) draws square purple corner brackets, about
   12 px thick on a 4K screen. There is no setting for width, rounding, or color.

4. **Viewer annotations don't render on the Linux host at all.** Verified on
   2026-10-29 with a macOS viewer: pencil strokes, GIFs and text never appeared
   on the sharer's screen. The client logs the viewer switching to the pencil
   (`controls update cursor Mouse > Paint`), and the `tuple-overlay` layer is
   created at full resolution, but nothing is drawn on it.

5. **Annotation colors should be per person, as on macOS.** Can't be checked on
   Linux until annotations render (item 4).

5a. **Starting a share crashes Xwayland.** Both shares started on Hyprland on
   2026-10-29 crashed Xwayland in the same second the client logged
   `remoteinput: controlling output 'DP-1'` and created its overlay (Xwayland:
   "Caught signal 11 (Segmentation fault). Server aborting"; recorded as
   SIGABRT). Wayland-native remote control kept working afterwards, so whatever
   the client does with X11 at share start looks like the trigger.

6. **The viewer's red remote cursor overlaps their pencil**, so you can't tell
   what the pencil points at.

7. **Remote control moves the host's real pointer** instead of driving a
   separate virtual pointer, and any pointer movement by the person sharing
   takes control back mid-stroke. Verified 2026-10-29. Input goes through
   Wayland (it kept working after Xwayland died). (May also need compositor
   support for a separate pointer.)

8. **The remote cursor is oversized** and doesn't scale with screen resolution.
   Not reproduced on 2026-10-29 (the size looked fine); keep only if it returns.

9. **No annotation toolbar for the person sharing** — no way to pick tools or
   undo while sharing.

10. **`share` and `unshare` are deprecated with no replacement.** The panel
    still needs some supported way to start and stop a screen share.

11. **`rooms` records no "favorited at" time**, so a client can't offer
    most-recently-favorited sorting.

## Not reported: hyprwm/Hyprland

Hyprland only accepts bug reports written by a person in their own words, so no
agent should file this one. Whoever reports it should write it themselves through
the Bugs → Other discussion form. The facts below are a reference, not text to
paste.

Title: **Xwayland is not restarted after it crashes; every later X11 client
hangs on connect until re-login**

What happened: In a Hyprland session, Xwayland crashed (its log: "Caught
signal 11 (Segmentation fault). Server aborting"; coredumpctl records it as
SIGABRT). Hyprland never started a new Xwayland. From then on, every X11
client hung on connect, including xdg-desktop-portal-hyprland's share picker,
and only logging out and back in fixed it.

The X11 socket stayed listening, but not because of the dead Xwayland:
`ss -xlp` shows `/tmp/.X11-unix/X0` owned by the Hyprland process, with
connections queued and never accepted. Toggling `xwayland.enabled` off and on
with `hyprctl eval` did not recover it.

Expected: Hyprland respawns a crashed Xwayland, or at least stops accepting on
the stale socket so clients fail fast instead of hanging.

Seen once so far. The same Xwayland crash (identical stack) happened in an
earlier session when a screen share started; I didn't check X11 clients after
that one.

Versions: Hyprland 0.56.2 built from branch v0.56.2 at commit
efb50993780079460b0cbed1363e2166a2de1d9f clean; xorg-xwayland 24.1.14-1;
xdg-desktop-portal-hyprland 1.4.1; NVIDIA RTX 5080, two monitors, Arch Linux
(Omarchy).

## Draft: report to freedesktop GitLab (Xwayland)

Title: **Xwayland segfaults when a client starts remote control over a shared
screen**

What happened: while a screen was being shared through a Wayland-native client
(via xdg-desktop-portal + PipeWire), starting remote control crashed Xwayland
with a null-deref segfault. Every X11 application closed. It has also crashed
once with no client doing anything unusual. Crash dumps land in
`coredumpctl` as `/usr/bin/Xwayland`.

Expected: no input a compositor or client forwards should crash Xwayland.

Steps to reproduce: share a screen through the Hyprland portal picker
(xdg-desktop-portal-hyprland 1.4.1, hyprland-preview-share-picker 0.2.1), then
have the other side request remote control. Xwayland segfaults at the moment
control starts.

Versions: Xwayland 24.1.14, Hyprland 0.56.2, NVIDIA RTX 5080, two monitors,
Arch Linux.
