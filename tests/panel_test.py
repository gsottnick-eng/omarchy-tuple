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
        self.env = dict(
            os.environ,
            QT_QPA_PLATFORM="offscreen",
            HARNESS_SCREEN="1600x1000",
            FAKE_TUPLE_STATE=str(self.state),
            XDG_BIN_HOME="",
            HYPRLAND_INSTANCE_SIGNATURE="fake00000000_1700000000_1",
            PATH=f"{FAKE_CLIENT_DIR}:{path}" if installed else path,
        )

    def run(self, steps=(), settle=1500, step_delay=700):
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

    def cleanup(self):
        # The fake's follow loops end when they see `stopped`, so nothing outlives the test.
        (self.state / "stopped").touch()
        shutil.rmtree(self.workdir, ignore_errors=True)


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

    def test_sign_in_takes_the_code_as_one_argument_and_never_echoes_it(self):
        harness = self.harness()
        harness.run(["sign-in", "code:wrong-code", "code:good-code", "wait:1500"])
        self.assertTrue(harness.after(0)["loginUrl"].startswith("https://"))
        rejected = harness.after(1)
        self.assertIn("invalid authorization code", rejected["error"])
        self.assertNotIn("wrong-code", rejected["error"])
        self.assertTrue(harness.final["loggedIn"])
        self.assertEqual(harness.final["loginUrl"], "")
        self.assertIn("auth good-code", harness.argv())
        self.assertGreater(len(harness.final["panel"]["rooms"]), 0)

    def test_a_blank_code_is_refused_without_running_anything(self):
        harness = self.harness()
        state = harness.run(["sign-in", "code:   "])
        self.assertNotEqual(state["error"], "")
        self.assertFalse(any(line.startswith("auth") for line in harness.argv()))

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

        def alerts(snapshot):
            return " ".join(" ".join(cmd) for cmd in snapshot["detached"])

        joined, left = harness.after(2), harness.after(4)
        self.assertIn("Grace Hopper joined the call", alerts(joined))
        self.assertIn("Grace Hopper left the call", alerts(left))
        self.assertNotIn("Katherine Johnson", alerts(harness.final))

    def test_a_brief_disconnect_announces_nothing(self):
        # A network blip flips `connected` away and back within the debounce
        # window, so neither a leave nor a join is announced.
        harness = self.harness(logged_in=True, in_call=True, flags=("muted",))
        harness.run(["wait:200", "flag:guest", "wait:500", "unflag:guest", "wait:3500"])
        alerts = " ".join(" ".join(cmd) for cmd in harness.final["detached"])
        self.assertNotIn("Grace Hopper joined the call", alerts)
        self.assertNotIn("Grace Hopper left the call", alerts)

    def test_calling_someone_uses_their_email_and_the_call_shows_up(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["call:Grace Hopper", "wait:1200"])
        self.assertIn("call start grace@example.com", harness.argv())
        self.assertTrue(state["inCall"])
        self.assertEqual(state["calling"], "")

    def test_a_busy_contact_in_a_joinable_call_is_joined_not_rung(self):
        harness = self.harness(logged_in=True)
        harness.run(["call:Katherine Johnson", "wait:1000"])
        self.assertIn("call join katherine@example.com", harness.argv())

    def test_joining_a_room_uses_its_slug(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["join:room-16", "wait:1000"])
        self.assertIn("rooms join room-16", harness.argv())
        self.assertTrue(state["inCall"])

    def test_a_pasted_link_must_be_https(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["join-url:tuple.example/c/room-1"])
        self.assertNotEqual(state["error"], "")
        self.assertFalse(any(line.startswith("call join") for line in harness.argv()))

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
        harness.run(["wait:300", "share", "wait:800", "mute", "wait:500"])
        held = harness.after(2)
        self.assertIn("share", harness.argv())
        self.assertTrue(held["status"].startswith("Choose a screen to share"))
        self.assertTrue(held["pickerPending"])
        # The daemon is blocked on the picker, so a mute must not run.
        self.assertNotIn("call mute", harness.argv())
        self.assertIn("Tuple is waiting for the share picker", harness.final["status"],
                      "refused commands say why")

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

    def test_the_panel_closes_before_the_share_picker_opens(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(["wait:300", "share-panel", "wait:400"])
        self.assertIn("share", harness.argv())
        self.assertFalse(
            state["panel"]["opened"], "the picker must not open under the panel"
        )

    def test_call_settings_are_read_once_and_written_as_arguments(self):
        harness = self.harness(logged_in=True, in_call=True)
        state = harness.run(
            ["wait:300", "setting:overlay=0", "setting:guest-mode=control", "wait:800"]
        )
        self.assertEqual(
            state["settings"]["overlay"], "0", "the toggle's new value is kept"
        )
        self.assertEqual(state["settings"]["guest-mode"], "control")
        self.assertIn("settings", harness.argv())
        self.assertIn("set overlay 0", harness.argv())
        self.assertIn("set guest-mode control", harness.argv())
        self.assertEqual(
            [l for l in harness.argv() if l.startswith("settings")],
            ["settings"],
            "read once, not polled",
        )

    def test_the_settings_toggles_need_both_verbs(self):
        harness = self.harness(logged_in=True, in_call=True, flags=("no_settings",))
        state = harness.run(["wait:300"])
        self.assertFalse(state["canSettings"])
        self.assertNotIn("settings", harness.argv())
        self.assertNotIn("set ", harness.argv())

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
        harness.run(["diagnose", "wait:500"])
        prompt = (harness.state / "agent-prompt").read_text()
        self.assertIn("status:     Ready", prompt)
        self.assertIn("/agents/diagnose/SKILL.md", prompt)
        self.assertTrue(
            (Path(prompt.split("Follow the skill at ")[1].split(". ")[0])).is_file()
        )
        self.assertNotIn(
            "Ada", prompt, "the account's identity stays out of the prompt"
        )


if __name__ == "__main__":
    unittest.main()
