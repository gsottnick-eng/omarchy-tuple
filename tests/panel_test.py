"""End-to-end tests for the Tuple bar widget.

Each test loads the real plugin in tests/harness (real Omarchy Ui components,
real process execution) against tests/fake-tuple, drives it the way a click
would, and asserts on the state the panel reached and the exact commands it ran.

Nothing here touches a real Tuple account: the fake is first on PATH, and the
harness's --theme run points HOME at a throwaway directory, so the probe's
~/.local/bin fallback cannot find a real client either.

    .venv-harness/bin/python -m unittest discover -s tests -p 'panel_test.py'

The venv pins PySide6 below 6.12: Qt 6.12's QtQuick exports its own `Color`
singleton, which shadows Omarchy's in this harness (not in Quickshell).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HARNESS = HERE / "harness" / "main.py"
FAKE_CLIENT_DIR = HERE / "fake-tuple"
sys.path.insert(0, str(FAKE_CLIENT_DIR))
import fake_daemon  # noqa: E402
OMARCHY = Path(os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell"))

# Noise from the stand-in Quickshell types; nothing the plugin controls.
# The follow streams are meant to run until the harness exits.
IGNORED_QT_WARNINGS = (
    "propertyCache.append",
    "Unable to assign [undefined] to int",
    "QProcess: Destroyed while process",
)


def path_without_tuple() -> str:
    dirs = os.environ.get("PATH", "").split(":")
    return ":".join(d for d in dirs if d and not (Path(d) / "tuple").exists())


class Harness:
    """One run of the panel: set up a client state, drive it, read back what happened."""

    def __init__(
        self, test, *, installed=True, logged_in=False, in_call=False, flags=()
    ):
        self.test = test
        self.workdir = Path(tempfile.mkdtemp(prefix="tuple-panel-"))
        self.state = self.workdir / "state"
        self.state.mkdir()
        for flag in (
            flags
            + (("logged_in",) if logged_in else ())
            + (("in_call",) if in_call else ())
        ):
            (self.state / flag).touch()

        path = path_without_tuple()
        # A short, private runtime dir: Unix socket paths are limited to ~108 bytes.
        self.runtime = Path(tempfile.mkdtemp(prefix="tr", dir="/tmp"))
        os.chmod(self.runtime, 0o700)
        self.daemon = fake_daemon.serve(self.runtime / "tuple-0", self.state)
        self.env = dict(
            os.environ,
            QT_QPA_PLATFORM="offscreen",
            HARNESS_SCREEN="1600x1000",
            FAKE_TUPLE_STATE=str(self.state),
            XDG_BIN_HOME="",
            XDG_RUNTIME_DIR=str(self.runtime),
            HYPRLAND_INSTANCE_SIGNATURE="fake00000000_1700000000_1",
            PATH=f"{FAKE_CLIENT_DIR}:{path}" if installed else path,
        )

    def run(self, steps=(), settle=1500, step_delay=700, settings=None):
        dumps = self.workdir / "dumps"
        final = self.workdir / "final.json"
        command = [
            sys.executable,
            str(HARNESS),
            "--omarchy",
            str(OMARCHY),
            "--dump",
            str(final),
            "--dump-each",
            str(dumps),
            "--settle",
            str(settle),
            "--step-delay",
            str(step_delay),
            "--theme",
            "tokyo-night",
            "--settings",
            json.dumps(settings or {}),
            "--do",
            ",".join(steps),
        ]
        result = subprocess.run(
            command, env=self.env, capture_output=True, text=True, timeout=120
        )
        noise = [
            line
            for line in result.stderr.splitlines()
            if line.strip()
            and not any(ignored in line for ignored in IGNORED_QT_WARNINGS)
        ]
        self.test.assertEqual(result.returncode, 0, f"harness failed:\n{result.stderr}")
        self.test.assertEqual(noise, [], "the panel logged QML errors")
        self.final = json.loads(final.read_text())
        return self.final

    def after(self, index):
        """State right after the step at this position in the --do list."""
        return json.loads(
            sorted((self.workdir / "dumps").glob(f"{index:02d}-*.json"))[0].read_text()
        )

    def argv(self):
        log = self.state / "argv"
        return log.read_text().splitlines() if log.exists() else []

    def socket_requests(self):
        log = self.state / "socket"
        return log.read_text().splitlines() if log.exists() else []

    def cleanup(self):
        # The fake's follow loops end when they see `stopped`, so nothing outlives the test.
        (self.state / "stopped").touch()
        self.daemon.close()
        shutil.rmtree(self.workdir, ignore_errors=True)
        shutil.rmtree(self.runtime, ignore_errors=True)


def alerts(snapshot):
    """The text of every call alert the plugin raised."""
    return " ".join(
        p["stdin"] for p in snapshot["piped"] if p["command"][0].endswith("/bin/tuple-notify")
    )


def command_lines(snapshot):
    """Every command line the plugin ran or detached, as one string."""
    commands = snapshot["detached"] + [p["command"] for p in snapshot["piped"]]
    return " ".join(" ".join(c) for c in commands)


class PanelTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        if not OMARCHY.is_dir():
            raise unittest.SkipTest(f"Omarchy shell not found at {OMARCHY}")

    def harness(self, **kwargs):
        harness = Harness(self, **kwargs)
        self.addCleanup(harness.cleanup)
        return harness

    def test_a_missing_client_offers_to_install_and_runs_nothing(self):
        harness = self.harness(installed=False)
        state = harness.run()
        self.assertTrue(state["probed"])
        self.assertFalse(state["installed"])
        self.assertEqual(state["summary"], "Not installed")
        self.assertEqual(harness.argv(), [])

    def test_signed_out_shows_no_rooms_or_people(self):
        harness = self.harness()
        state = harness.run()
        self.assertTrue(state["daemonRunning"])
        self.assertFalse(state["loggedIn"])
        self.assertEqual(state["panel"]["rooms"], [])
        self.assertEqual(state["panel"]["people"], [])
        # Contacts and rooms need a session; they are not even attempted.
        self.assertEqual(
            sorted(harness.argv()), ["--help", "state follow --format json"]
        )

    def test_sign_in_sends_the_code_over_the_socket_never_on_a_command_line(self):
        harness = self.harness()
        harness.run(["sign-in", "code:wrong-code", "code:good-code", "wait:1500"])
        self.assertTrue(harness.after(0)["loginUrl"].startswith("https://"))
        rejected = harness.after(1)
        self.assertIn("invalid authorization code", rejected["error"])
        self.assertNotIn("wrong-code", rejected["error"], "the code is never echoed back")
        self.assertTrue(harness.final["loggedIn"])
        self.assertEqual(harness.final["loginUrl"], "")
        self.assertEqual(harness.socket_requests(), ["auth wrong-code", "auth good-code"])
        self.assertFalse(any("code" in line for line in harness.argv()),
                         "no command the plugin ran carried the code: " + repr(harness.argv()))
        self.assertGreater(len(harness.final["panel"]["rooms"]), 0)

    def test_a_blank_code_is_refused_without_running_anything(self):
        harness = self.harness()
        state = harness.run(["sign-in", "code:   "])
        self.assertNotEqual(state["error"], "")
        self.assertFalse(any(line.startswith("auth") for line in harness.argv()))
        self.assertEqual(harness.socket_requests(), [], "nothing was sent to the daemon")

    def test_signed_in_lists_everyone_and_a_search_narrows_rooms_and_people(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["wait:200", "search:Frances"])
        before = harness.after(0)
        self.assertTrue(before["panel"]["rooms"][0]["personal"])
        self.assertEqual(len(before["panel"]["people"]), 6)
        self.assertEqual(len(state["contacts"]), 6)
        self.assertEqual(
            [p["name"] for p in state["panel"]["people"]], ["Frances Allen"]
        )
        self.assertEqual(state["panel"]["rooms"], [], "the search filters rooms too")
        self.assertEqual(state["user"]["name"], "Ada")
        self.assertIn("contacts follow --format json", harness.argv())
        self.assertIn("rooms follow --format json", harness.argv())

    def test_rooms_report_occupants_and_active_means_occupied(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["wait:200"])
        rooms = state["panel"]["rooms"]
        design = next(r for r in rooms if r["name"] == "Design Review")
        self.assertEqual(
            [o["name"] for o in design["occupants"]],
            ["Katherine Johnson", "Donald Knuth"],
        )
        self.assertTrue(design["active"])
        incident = next(r for r in rooms if r["name"] == "Incident")
        self.assertFalse(
            incident["active"], "active_call alone never makes a room occupied"
        )

    def test_room_occupancy_follows_what_the_client_pushes(self):
        harness = self.harness(logged_in=True)
        harness.run(["wait:200", "flag:busy", "wait:800", "unflag:busy", "wait:800"])

        def pairing(snapshot):
            return next(r for r in snapshot["panel"]["rooms"] if r["name"] == "Pairing")

        self.assertEqual(
            pairing(harness.after(0))["occupants"],
            [],
            "the fixture starts with Pairing empty",
        )
        self.assertEqual(
            [o["name"] for o in pairing(harness.after(1))["occupants"]],
            ["Grace Hopper"],
        )
        self.assertTrue(pairing(harness.after(1))["active"])
        self.assertEqual(
            pairing(harness.after(3))["occupants"],
            [],
            "and empty again when she leaves",
        )
        self.assertFalse(pairing(harness.after(3))["active"])

    def test_a_call_announces_when_someone_joins_or_leaves(self):
        harness = self.harness(logged_in=True, in_call=True, flags=("muted",))
        harness.run(
            ["wait:200", "flag:guest", "wait:3500", "unflag:guest", "wait:3500"]
        )

        joined, left = harness.after(2), harness.after(4)
        self.assertIn("Grace Hopper joined the call", alerts(joined))
        self.assertIn("Grace Hopper left the call", alerts(left))
        self.assertNotIn("Katherine Johnson", alerts(harness.final))
        # Names reach the notifier on stdin, never on a command line.
        self.assertNotIn("Grace Hopper", command_lines(harness.final))

    def test_a_brief_disconnect_announces_nothing(self):
        # A network blip flips `connected` away and back within the debounce
        # window, so neither a leave nor a join is announced.
        harness = self.harness(logged_in=True, in_call=True, flags=("muted",))
        harness.run(["wait:200", "flag:guest", "wait:500", "unflag:guest", "wait:3500"])
        self.assertNotIn("Grace Hopper joined the call", alerts(harness.final))
        self.assertNotIn("Grace Hopper left the call", alerts(harness.final))

    def test_a_copied_link_goes_to_the_clipboard_on_stdin(self):
        harness = self.harness(logged_in=True)
        link = "https://tuple.example/r/private-room"
        harness.run(["copy:" + link, "wait:200"])
        copies = [p for p in harness.final["piped"] if p["command"] == ["wl-copy"]]
        self.assertEqual([p["stdin"] for p in copies], [link])
        self.assertNotIn(link, command_lines(harness.final))

    # Calls, joins and favorites name a person, a room or a link, so they go to
    # the daemon's API on its socket; no `tuple` command line carries them.
    def assert_no_destination_in_argv(self, harness, *values):
        for value in ("@",) + values:
            self.assertFalse(any(value in line for line in harness.argv()),
                             f"{value!r} reached a command line: {harness.argv()!r}")

    def test_calling_someone_goes_to_the_daemon_by_id_and_the_call_shows_up(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["call:Grace Hopper", "wait:1200"])
        self.assertIn('POST /call {"user_id":1003}', harness.socket_requests())
        self.assert_no_destination_in_argv(harness)
        self.assertTrue(state["inCall"])
        self.assertEqual(state["calling"], "")

    def test_a_busy_contact_in_a_joinable_call_is_joined_not_rung(self):
        harness = self.harness(logged_in=True)
        harness.run(["call:Katherine Johnson", "wait:1000"])
        self.assertIn('POST /call/join {"user_id":1004}', harness.socket_requests())
        self.assert_no_destination_in_argv(harness)

    def test_a_refused_call_shows_the_daemons_error_and_stops_calling(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["call:Edsger Dijkstra", "wait:1000"])
        self.assertEqual(state["error"], "Edsger Dijkstra declined")
        self.assertEqual(state["calling"], "")
        self.assertFalse(state["inCall"])

    def test_joining_a_room_sends_its_slug_to_the_daemon(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["join:room-16", "wait:1000"])
        self.assertIn('POST /call/join {"url":"room-16"}', harness.socket_requests())
        self.assert_no_destination_in_argv(harness, "room-16")
        self.assertTrue(state["inCall"])

    def test_a_pasted_link_joins_through_the_daemon_like_the_client_would(self):
        harness = self.harness(logged_in=True)
        harness.run(["join-url:https://tuple.example/c/room-1?from=chat", "join-url:https://tuple.example/r/other",
                     "wait:1000"])
        requests = harness.socket_requests()
        self.assertIn('POST /call/join {"url":"room-1"}', requests)
        self.assertIn('POST /call/join {"url":"https://tuple.example/r/other"}', requests)
        self.assert_no_destination_in_argv(harness, "tuple.example")

    def test_a_pasted_link_must_be_https(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["join-url:tuple.example/c/room-1"])
        self.assertNotEqual(state["error"], "")
        self.assertEqual(harness.socket_requests(), [])

    def test_favorites_go_to_the_daemon_by_id(self):
        harness = self.harness(logged_in=True)
        harness.run(["favorite:Grace Hopper", "favorite:Edsger Dijkstra",
                     "favorite-room:room-15", "wait:300", "favorite-room:room-16", "wait:600"])
        # Each request has its own connection, so they may land in any order.
        self.assertCountEqual(harness.socket_requests(), [
            "DELETE /contacts/1003/favorite",
            "POST /contacts/1012/favorite",
            "GET /rooms/room-15",
            "POST /rooms/room-id-room-15/favorite",
            "GET /rooms/room-16",
            "DELETE /rooms/room-id-room-16/favorite",
        ])
        self.assert_no_destination_in_argv(harness, "room-15", "room-16")

    def test_mute_share_and_leave_follow_what_the_client_reports(self):
        harness = self.harness(logged_in=True, in_call=True)
        harness.run(["mute", "wait:800", "share", "wait:800", "leave", "wait:800"])
        self.assertTrue(harness.after(1)["muted"])
        self.assertTrue(harness.after(3)["sharing"])
        self.assertIn("state follow --raw --format json", harness.argv())
        final = harness.final
        self.assertFalse(final["inCall"])
        self.assertFalse(final["sharing"])
        self.assertEqual(
            [l for l in harness.argv() if l in ("call mute", "share", "call leave")],
            ["call mute", "share", "call leave"],
        )

    def test_share_is_hidden_when_the_client_no_longer_offers_it(self):
        harness = self.harness(logged_in=True, in_call=True, flags=("no_share",))
        state = harness.run(["share", "wait:500"])
        self.assertFalse(state["canShare"])
        self.assertNotIn("share", harness.argv())

    def test_sharing_opens_the_picker_and_pauses_everything_else(self):
        # picker_holds: the fake client leaves the picker open, the way the
        # real daemon blocks until a screen is chosen.
        harness = self.harness(logged_in=True, in_call=True, flags=("picker_holds",))
        harness.run(["wait:300", "share", "wait:800", "mute", "wait:500",
                     "favorite:Grace Hopper", "favorite-room:room-15", "join:room-16", "wait:300"])
        held = harness.after(2)
        self.assertIn("share", harness.argv())
        self.assertTrue(held["status"].startswith("Choose a screen to share"))
        self.assertTrue(held["pickerPending"])
        # The daemon is blocked on the picker, so a mute must not run.
        self.assertNotIn("call mute", harness.argv())
        # Nor do favorites or joins, which would wait unanswered on its socket.
        self.assertEqual(harness.socket_requests(), [])
        self.assertIn("Tuple is waiting for the share picker", harness.final["status"],
                      "refused commands say why")
        # Leaving always works, picker or not.
        harness.run(["leave", "wait:500"])
        self.assertIn("call leave", harness.argv())

    def test_a_cancelled_picker_unblocks_on_the_next_snapshot(self):
        # picker_holds keeps the fake from reporting sharing; the cancelled
        # picker makes the daemon answer again without a share.
        harness = self.harness(logged_in=True, in_call=True, flags=("picker_holds", "muted"))
        state = harness.run(["wait:300", "share", "wait:1200",
                             "flag:picker_cancelled", "wait:800", "mute", "wait:800"])
        self.assertTrue(harness.after(2)["pickerPending"], "held while the picker is up")
        self.assertFalse(state["pickerPending"], "the next snapshot ends the picker wait")
        self.assertFalse(state["sharing"], "nothing was picked")
        # The cancelled-pick snapshot also un-muted the panel, so toggling
        # mutes again — the point is that a command runs immediately.
        self.assertIn("call mute", harness.argv(), "commands run again at once")

    def test_sharing_unblocks_when_the_client_reports_sharing(self):
        harness = self.harness(logged_in=True, in_call=True, flags=("picker_holds",))
        state = harness.run(
            [
                "wait:300",
                "share",
                "wait:500",
                "unflag:picker_holds",
                "flag:sharing",
                "wait:800",
            ]
        )
        self.assertTrue(state["sharing"])
        self.assertFalse(state["pickerPending"], "sharing clears the picker wait")
        self.assertNotIn("call mute", harness.argv())
        harness.run(["mute", "wait:800"])
        self.assertIn("call mute", harness.argv())

    def test_sharing_refuses_when_xwayland_died_this_session(self):
        harness = self.harness(logged_in=True, in_call=True, flags=("xwayland_dead",))
        state = harness.run(["wait:300", "share", "wait:600"])
        self.assertNotIn("share", harness.argv())
        self.assertIn("Xwayland stopped earlier", state["error"])
        self.assertFalse(state["pickerPending"])

    # XWAYLAND-SHARE-WORKAROUND: the tests from here to the help-button test go with the warning.
    def test_sharing_warns_first_and_shares_nothing_until_confirmed(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:400"])
        self.assertNotIn("share", harness.argv())
        self.assertTrue(state["panel"]["shareWarningOpen"])
        self.assertTrue(state["panel"]["opened"], "the warning shows in the open panel")

    def test_share_anyway_shares_and_the_next_share_warns_again(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:300", "share-anyway", "wait:600",
                             "share-panel", "wait:500", "open", "wait:300", "share-panel", "wait:400"])
        self.assertEqual([l for l in harness.argv() if l in ("share", "unshare")], ["share", "unshare"],
                         "Share anyway shares; stopping never warns")
        self.assertTrue(state["panel"]["shareWarningOpen"], "the next share warns again")
        self.assertEqual(state["barWrites"], [], "Share anyway saves nothing")

    def test_dont_show_again_shares_and_turns_the_warning_off_for_good(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:300", "share-dont-warn", "wait:600",
                             "share-panel", "wait:500", "share-panel", "wait:400"])
        self.assertEqual([l for l in harness.argv() if l in ("share", "unshare")], ["share", "unshare", "share"])
        self.assertFalse(state["panel"]["shareWarningOpen"])
        self.assertEqual(state["barWrites"][-1].get("warnBeforeSharing"), False,
                         "the choice is saved to the widget's shell.json entry")

    def test_with_the_warning_turned_off_sharing_starts_at_once(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:400"], settings={"warnBeforeSharing": "false"})
        self.assertIn("share", harness.argv())
        self.assertFalse(state["panel"]["shareWarningOpen"])

    def test_the_help_button_explains_why_sharing_breaks_the_desktop(self):
        harness = self.harness(logged_in=True)
        harness.run(["wait:300", "share-help", "wait:300", "share-help", "wait:300"])
        self.assertTrue(harness.after(1)["panel"]["shareHelpOpen"])
        self.assertFalse(harness.final["panel"]["shareHelpOpen"])

    def test_the_panel_closes_before_the_share_picker_opens(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:300", "share-anyway", "wait:400"])
        self.assertIn("share", harness.argv())
        self.assertFalse(
            state["panel"]["opened"], "the picker must not open under the panel"
        )

    def test_stop_stays_stopped_until_start(self):
        harness = self.harness(logged_in=True)
        harness.run(["stop", "wait:3500", "start", "wait:1500"])
        stopped = harness.after(1)
        self.assertFalse(stopped["daemonRunning"])
        argv = harness.argv()
        stop_at, start_at = argv.index("stop"), argv.index("start")
        self.assertEqual(
            [l for l in argv[stop_at:start_at] if "follow" in l],
            [],
            "nothing restarted the daemon while it was stopped",
        )
        self.assertTrue(harness.final["daemonRunning"])
        self.assertIn("state follow --format json", argv[start_at:])

    def test_diagnose_hands_the_agent_the_facts_and_the_skill(self):
        harness = self.harness(logged_in=True)
        harness.run(["join-url:http://not-https", "diagnose", "wait:500"])
        prompt = (harness.state / "agent-prompt").read_text()
        # The prompt is a command line; errors can name people, so none goes in.
        self.assertNotIn("Paste a full", prompt)
        self.assertIn("status:     Ready", prompt)
        self.assertIn("/agents/diagnose/SKILL.md", prompt)
        self.assertTrue(
            (Path(prompt.split("Follow the skill at ")[1].split(". ")[0])).is_file()
        )
        self.assertNotIn(
            "Ada", prompt, "the account's identity stays out of the prompt"
        )



def has_system_gi() -> bool:
    check = ["/usr/bin/python3", "-c", "from gi.repository import Gio"]
    return Path(check[0]).exists() and subprocess.run(check, capture_output=True).returncode == 0


@unittest.skipUnless(shutil.which("dbus-run-session") and has_system_gi(),
                     "needs dbus-run-session and the system Python's gi")
class NotifierTest(unittest.TestCase):
    """bin/tuple-notify, against a notification server on a private bus."""

    def test_each_line_becomes_one_notification_and_bad_lines_are_skipped(self):
        lines = [
            {"icon": "call-start", "summary": "Grace Hopper joined the call", "body": ""},
            "not json",
            {"icon": "call-stop", "summary": "Call ended"},
        ]
        result = subprocess.run(
            ["dbus-run-session", "--", "/usr/bin/python3",
             str(FAKE_CLIENT_DIR / "fake_notifications.py"),
             str(HERE.parent / "bin" / "tuple-notify")],
            input="".join((json.dumps(l) if isinstance(l, dict) else l) + "\n" for l in lines),
            capture_output=True, text=True, timeout=30,
        )
        received = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(received, [
            {"app": "Tuple", "icon": "call-start", "summary": "Grace Hopper joined the call", "body": ""},
            {"app": "Tuple", "icon": "call-stop", "summary": "Call ended", "body": ""},
        ], result.stderr)
        self.assertNotIn("not json", result.stderr, "errors never quote the alert")

if __name__ == "__main__":
    unittest.main()
