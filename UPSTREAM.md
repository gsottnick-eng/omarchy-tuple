# Upstream problems

Bugs outside Tuplet that we are waiting on. One row per problem; drafts for
each upstream follow the table. File links land here once reports are filed.

| Problem | What the user sees | Who must fix it | Status | Tuplet's workaround |
| --- | --- | --- | --- | --- |
| Xwayland segfaults (null deref) when remote control starts on a shared screen | Every X11 app closes at once; the session and Wayland apps survive | X.org/Xwayland (freedesktop GitLab), and Tuple's Linux client for what it sends | draft below | none — Native Wayland apps are unaffected |
| Hyprland never restarts Xwayland after it dies | After any Xwayland crash, every X11 app hangs on connect until you log out and back in; `hyprctl` toggling `xwayland.enabled` does not recover it | hyprwm/Hyprland | filing to hyprwm/Hyprland (link lands here) | Tuplet refuses to share when a core dump says Xwayland died this session, and says why |
| Tuple daemon blocks completely while the portal screen picker is open | Every `tuple` command and follow stream stalls until a screen is picked or the picker closes | Tuple | draft below | Tuplet closes the panel before sharing, explains the wait, and refuses other commands while the picker is up |
| Tuple daemon hangs connecting to a dead Xwayland and never recovers | After an Xwayland crash the daemon must be killed; it never recovers on its own | Tuple | draft below | none |
| The overlay's sharing border can't be thinner or rounded | A thick square border around the shared screen; no setting changes it | Tuple | draft below | none |
| Annotation colors aren't per person like on macOS | Everyone draws in the same color, so you can't tell who drew what | Tuple | draft below | none |
| GIFs and typed text from viewers don't render on the Linux host | Viewer annotations arrive as strokes only; GIF stamps and text boxes are missing | Tuple | draft below | none |
| The viewer's red remote cursor overlaps their pencil | You can't see what the pencil points at while controlling | Tuple | draft below | none |
| Remote control drives the host's real pointer instead of a separate one, and host movement steals it back | The person sharing fights their own pointer; moving the mouse hijacks control back | Tuple (may also need compositor support) | draft below | none |
| The remote cursor is oversized and doesn't scale with resolution | A huge pointer on high-DPI screens | Tuple | draft below | none |
| No annotation toolbar for the person sharing | You can't pick tools or undo what viewers drew while sharing | Tuple | draft below | none |
| `share` and `unshare` are deprecated with no replacement | Screen sharing hangs on deprecated verbs; a future client could drop them with nothing to take their place | Tuple | draft below | Tuplet hides Share if `tuple --help` stops listing the verbs |
| The client records no "favorited at" time, so favorites can't sort by recency | Favorites can only sort alphabetically | Tuple | draft below | Tuplet sorts favorites A to Z |

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
   What happened: Xwayland segfaulted. It kept listening on
   `/tmp/.X11-unix/X0` but never accepted connections again, so every new X11
   client hung on connect — and the Tuple daemon hung too, blocking
   permanently. It had to be killed. Logging out and back in was the only
   recovery.
   Expected: the daemon should time out, report the failure, and recover.
   Reproduce: crash Xwayland (see the Xwayland draft), then run any `tuple`
   command.

3. **The overlay's sharing border can't be styled.** The full-screen annotation
   layer (namespace `tuple-overlay`) draws a thick square border around the
   shared screen. There is no setting for width, rounding, or color.

4. **Annotation colors aren't per person.** On macOS Tuple picks a color per
   viewer; the Linux host draws everyone in one color.

5. **GIF stamps and typed text from viewers don't render on the host.** Only
   freehand strokes arrive.

6. **The viewer's red remote cursor overlaps their pencil**, so you can't tell
   what the pencil points at.

7. **Remote control moves the host's real pointer** instead of driving a
   separate virtual pointer, and any pointer movement by the person sharing
   takes control back mid-stroke. (May also need compositor support for a
   separate pointer.)

8. **The remote cursor is oversized** and doesn't scale with screen resolution.

9. **No annotation toolbar for the person sharing** — no way to pick tools or
   undo while sharing.

10. **`share` and `unshare` are deprecated with no replacement.** The panel
    still needs some supported way to start and stop a screen share.

11. **`rooms` records no "favorited at" time**, so a client can't offer
    most-recently-favorited sorting.

## Draft: report to hyprwm/Hyprland

Filed on hyprwm/Hyprland (link lands here once open).

Title: **Xwayland is not restarted after it crashes; every later X11 client
hangs on connect until re-login**

What happened: Xwayland segfaulted twice in one session (once the moment a
screen share started, once while idle). Hyprland did not restart it. The dead
Xwayland kept its socket `/tmp/.X11-unix/X0` listening but never accepted
again, so every subsequent X11 client hung on connect — including non-graphical
daemons. Toggling `xwayland.enabled` off and on with `hyprctl eval` did not
recover it. Logging out and back in was the only fix.

Expected: Hyprland respawns a crashed Xwayland (or at least closes the stale
socket so clients fail fast instead of hanging).

Steps to reproduce: kill Xwayland (`pkill -SEGV Xwayland`); try to start any
X11 app — it hangs; `ls /tmp/.X11-unix/X0` still exists; restart Hyprland or
re-login to recover.

Versions: Hyprland 0.56.2, Xwayland 24.1.14, NVIDIA RTX 5080, two monitors,
Arch Linux.

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
