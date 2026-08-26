"""End-to-end tests for the Tuple bar widget.

Each test loads the real plugin in tests/harness (real Omarchy Ui components,
real process execution), drives it the way a click would, and asserts on the
state the panel actually reached.

Most tests run against tests/fake-tuple, a scripted client that speaks the real
client's exact output, because signing in and joining a call need a real Tuple
account. The tests marked "real client" run against the official binary.

    tests/harness/../../.venv-harness/bin/python -m unittest discover -s tests -p 'panel_test.py'
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HARNESS = HERE / "harness" / "main.py"
FAKE_CLIENT_DIR = HERE / "fake-tuple"
OMARCHY = Path(os.environ.get("OMARCHY_SHELL", "/tmp/omarchy/shell"))

# Noise from the stand-in Quickshell types; nothing the plugin controls.
IGNORED_QT_WARNINGS = ("propertyCache.append", "Unable to assign [undefined] to int")


def real_client() -> str | None:
    return shutil.which("tuple", path=f"{Path.home()}/.local/bin:{os.environ.get('PATH', '')}")


class Harness:
    """One run of the panel: set up a client state, drive it, read back what happened."""

    def __init__(self, test: unittest.TestCase, *, fake=True, logged_in=False, settings=None):
        self.test = test
        self.workdir = Path(tempfile.mkdtemp(prefix="tuple-panel-"))
        self.state = self.workdir / "state"
        self.data = self.workdir / "data"
        self.state.mkdir()
        (self.data / "tuple" / "0").mkdir(parents=True)
        if logged_in:
            (self.state / "logged_in").touch()

        self.env = dict(os.environ)
        self.env.update({
            "QT_QPA_PLATFORM": "offscreen",
            "HARNESS_SCREEN": "1600x1000",
            "FAKE_TUPLE_STATE": str(self.state),
            "XDG_DATA_HOME": str(self.data),
        })
        if fake:
            self.env["PATH"] = f"{FAKE_CLIENT_DIR}:{self.env.get('PATH', '')}"
        self.settings = settings or {}

    def run(self, steps=(), settle=1800, step_delay=900, shot=None):
        dumps = self.workdir / "dumps"
        final = self.workdir / "final.json"
        command = [
            sys.executable, str(HARNESS),
            "--omarchy", str(OMARCHY),
            "--settings", json.dumps(self.settings),
            "--dump", str(final),
            "--dump-each", str(dumps),
            "--settle", str(settle),
            "--step-delay", str(step_delay),
            "--do", ",".join(steps),
        ]
        if shot:
            command += ["--shot", str(shot)]

        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=180)
        noise = [
            line for line in result.stderr.splitlines()
            if line.strip() and not any(ignored in line for ignored in IGNORED_QT_WARNINGS)
        ]
        self.test.assertEqual(result.returncode, 0, f"harness failed:\n{result.stderr}")
        self.test.assertEqual(noise, [], "the panel logged QML errors")

        self.steps = [json.loads(path.read_text()) for path in sorted(dumps.glob("*.json"))] if dumps.exists() else []
        self.final = json.loads(final.read_text())
        return self.final

    def after(self, step_name):
        """State right after the numbered step, e.g. after("01-login")."""
        for index, path in enumerate(sorted((self.workdir / "dumps").glob("*.json"))):
            if path.name.startswith(step_name):
                return self.steps[index]
        raise AssertionError(f"no dump for step {step_name!r}")

    def client_state(self):
        return sorted(p.name for p in self.state.iterdir())

    def stop_sandbox_processes(self):
        """Stop anything still running out of this sandbox.

        Tuple's daemon is a singleton keyed on the abstract socket
        @tuple-daemon, and it outlives the CLI invocation that revived it. A
        real-client test that only deletes its workdir leaves that daemon
        holding the socket with its data directory deleted underneath it.
        Every later client then attaches to a daemon that cannot persist
        anything -- including the developer's own session, which silently
        stops recording logins and writing the log the panel reads.

        Match on the executable path so this only ever touches processes this
        sandbox started. `tuple off` would be the polite way to ask, but it
        stops whichever daemon holds the socket, which may be the developer's.
        """
        root = str(self.workdir)
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                exe = os.readlink(entry / "exe")
            except OSError:
                continue
            # A deleted binary reads back as "/path/to/tuple (deleted)".
            if exe.startswith(root):
                try:
                    os.kill(int(entry.name), signal.SIGTERM)
                except OSError:
                    pass

    def cleanup(self):
        self.stop_sandbox_processes()
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

    # ------------------------------------------------------------- signed out

    def test_signed_out_offers_sign_in_and_nothing_else(self):
        state = self.harness().run()
        self.assertTrue(state["installed"])
        self.assertFalse(state["loggedIn"])
        self.assertEqual(state["statusSummary"], "Signed out")
        self.assertEqual(state["panel"]["barLabel"], "Sign in")
        self.assertTrue(state["panel"]["showSignIn"])
        self.assertFalse(state["panel"]["showRooms"])
        self.assertFalse(state["panel"]["showPeople"])
        self.assertEqual(state["contacts"], [])

    def test_sign_in_surfaces_the_browser_url_then_accepts_the_code(self):
        harness = self.harness()
        harness.run(["login", "wait:1200", "auth:test-code-123", "wait:1200"])

        after_login = harness.after("00-login")
        self.assertTrue(after_login["awaitingAuthCode"])
        self.assertTrue(after_login["loginUrl"].startswith("https://production.tuple.app/start?"))

        self.assertTrue(harness.final["loggedIn"])
        self.assertTrue(harness.final["panel"]["showPeople"])
        self.assertIn("logged_in", harness.client_state())

    def test_a_rejected_authorization_code_reports_instead_of_running(self):
        state = self.harness().run(["auth:no"])
        self.assertFalse(state["loggedIn"])
        self.assertIn("authorization code", state["lastError"])

    # --------------------------------------------------------------- contacts

    def test_contacts_load_with_presence_and_favourites_first(self):
        state = self.harness(logged_in=True).run()
        self.assertEqual([c["name"] for c in state["contacts"]],
                         ["Grace Hopper", "Ada Lovelace", "Alan Turing"])
        self.assertTrue(state["contacts"][0]["favorite"])
        self.assertEqual(state["contacts"][1]["status"], "online")
        # The id from `tuple ls` is what `tuple favorite` needs.
        self.assertEqual([c["selector"] for c in state["contacts"]],
                         ["usr_102", "usr_101", "usr_103"])

    def test_calling_a_contact_picks_the_right_number_from_the_picker(self):
        harness = self.harness(logged_in=True)
        # Alan is third in `ls` order and third in the picker, but the plugin
        # must resolve it through the picker rather than by position.
        state = harness.run(["call:2", "wait:1500"])
        self.assertTrue(state["inCall"])
        self.assertTrue(state["panel"]["showCall"])
        self.assertIn("Alan Turing", state["actionStatus"] + state["lastError"])
        self.assertIn("in_call", harness.client_state())

    def test_favouriting_a_contact_writes_through_to_the_client(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["favorite:1", "wait:1500"])
        ada = next(c for c in state["contacts"] if c["name"] == "Ada Lovelace")
        self.assertTrue(ada["favorite"])

    # ------------------------------------------------------------ call controls

    def test_mute_and_share_track_the_daemon_log(self):
        harness = self.harness(logged_in=True)
        harness.run(["call:0", "wait:1500", "mute", "wait:1200", "share", "wait:1200"])

        after_mute = harness.after("02-mute")
        self.assertTrue(after_mute["muted"])
        self.assertFalse(after_mute["sharing"])

        self.assertTrue(harness.final["sharing"])
        self.assertTrue(harness.final["inCall"])
        self.assertEqual(harness.final["statusSummary"], "In a call · sharing")

    def test_leaving_a_call_clears_sharing_too(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["call:0", "wait:1500", "share", "wait:1200", "end", "wait:1500"])
        self.assertFalse(state["inCall"])
        self.assertFalse(state["sharing"])
        self.assertFalse(state["panel"]["showCall"])
        self.assertNotIn("in_call", harness.client_state())

    def test_a_new_call_reveals_and_remembers_the_personal_room(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["new", "wait:1500"])
        self.assertEqual(state["personalUrl"], "https://tuple.app/c/ada-personal")
        self.assertTrue(state["inCall"])
        self.assertEqual([r["name"] for r in state["rooms"]], ["My personal room"])
        # Remembered through the widget's own settings entry.
        self.assertEqual(state["bar"]["lastEntry"].get("personalUrl"), "https://tuple.app/c/ada-personal")

    def test_opening_the_panel_never_starts_a_call(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["refresh", "wait:1500"])
        self.assertFalse(state["inCall"])
        self.assertNotIn("in_call", harness.client_state())

    # ------------------------------------------------------------------ rooms

    def test_saving_a_room_persists_it_and_makes_it_joinable(self):
        harness = self.harness(logged_in=True)
        harness.run([
            "save-room:https://tuple.app/c/design-review|Design review", "wait:800",
            "join:0", "wait:1500",
        ])
        after_save = harness.after("00-save-room")
        self.assertEqual([r["name"] for r in after_save["rooms"]], ["Design review"])
        self.assertEqual(after_save["bar"]["lastEntry"]["savedRooms"],
                         [{"url": "https://tuple.app/c/design-review", "name": "Design review", "favorite": False}])
        self.assertTrue(harness.final["inCall"])

    def test_a_room_link_the_client_cannot_join_is_explained_not_forwarded(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["save-room:https://tuple.app/room/design|Design"])
        self.assertEqual(state["rooms"], [])
        self.assertIn("tuple.app/c/", state["lastError"])

    def test_rooms_can_be_pinned_and_forgotten(self):
        harness = self.harness(logged_in=True, settings={
            "savedRooms": [
                {"url": "https://tuple.app/c/one", "name": "One", "favorite": False},
                {"url": "https://tuple.app/c/two", "name": "Two", "favorite": False},
            ]
        })
        harness.run(["pin-room:1", "wait:800", "forget-room:1", "wait:800"])

        # Pinning reorders the list, and the indices follow what is displayed:
        # after pinning "Two" it sorts first, so index 1 is now "One".
        after_pin = harness.after("00-pin-room")
        self.assertEqual([r["name"] for r in after_pin["rooms"]], ["Two", "One"])
        self.assertEqual([r["name"] for r in harness.final["rooms"]], ["Two"])

    # --------------------------------------------------------------- settings

    def test_every_client_setting_gets_the_right_control(self):
        state = self.harness(logged_in=True).run()
        by_key = {s["key"]: s for s in state["settings"]}
        self.assertEqual(by_key["overlay"]["kind"], "bool")
        self.assertEqual(by_key["capture"]["kind"], "enum")
        self.assertEqual(by_key["capture"]["options"], ["auto", "x11", "portal"])
        self.assertEqual(by_key["transcription-model"]["kind"], "string")

    def test_toggling_a_setting_writes_it_back_and_reloads(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["toggle-setting:overlay", "wait:1500"])
        overlay = next(s for s in state["settings"] if s["key"] == "overlay")
        self.assertEqual(overlay["value"], "0")
        self.assertEqual((harness.state / "settings" / "overlay").read_text(), "0")

    def test_cycling_an_enum_setting_uses_the_clients_allowed_values(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["toggle-setting:capture", "wait:1500"])
        capture = next(s for s in state["settings"] if s["key"] == "capture")
        self.assertEqual(capture["value"], "x11")

    def test_signing_out_returns_to_the_sign_in_view(self):
        harness = self.harness(logged_in=True)
        state = harness.run(["logout", "wait:1500"])
        self.assertFalse(state["loggedIn"])
        self.assertTrue(state["panel"]["showSignIn"])

    # ---------------------------------------------------------- not installed

    def test_a_missing_client_offers_to_install_it(self):
        harness = self.harness(fake=False, settings={"installDir": "/nonexistent/bin"})
        harness.env["PATH"] = "/usr/bin:/bin"  # hide any real client
        state = harness.run()
        self.assertFalse(state["installed"])
        self.assertTrue(state["panel"]["showSetup"])
        self.assertEqual(state["statusSummary"], "Tuple is not installed")
        self.assertEqual(state["panel"]["barLabel"], "Tuple")

    def test_installing_downloads_verifies_and_reports_progress(self):
        harness = self.harness(fake=False)
        target = harness.workdir / "bin"
        harness.env["PATH"] = "/usr/bin:/bin"
        harness.settings = {"installDir": str(target)}
        state = harness.run(["install", "wait:45000"], step_delay=45000)

        self.assertEqual(state["installStage"], "done", state["installMessage"])
        self.assertTrue((target / "tuple").exists())
        self.assertTrue(os.access(target / "tuple", os.X_OK))
        self.assertTrue(state["installed"])
        self.assertRegex(state["clientVersion"], r"^v\d{4}_\d{2}_\d{2}")

    def test_a_boolean_setting_written_as_a_string_still_takes_effect(self):
        # `omarchy bar set <id> showLabel true` writes the string "true", not a
        # boolean. Reading it with `=== true` turned the feature off at the
        # moment the user asked for it on.
        off = self.harness(logged_in=True, settings={"showLabel": "false"}).run()
        self.assertEqual(off["panel"]["barLabel"], "Tuple")
        self.assertEqual(off["panel"]["barText"], "")

        on = self.harness(logged_in=True, settings={"showLabel": "true"}).run()
        self.assertEqual(on["panel"]["barText"], on["panel"]["barLabel"])

    # ----------------------------------------------------------------- audio

    def test_audio_devices_come_from_pipewire_not_the_client(self):
        if not shutil.which("pactl"):
            self.skipTest("pactl not installed")
        harness = self.harness(logged_in=True)
        state = harness.run()
        self.assertTrue(state["audioAvailable"])
        # Tuple exposes no audio settings, so none of these may come from it.
        self.assertNotIn("output", [s["key"] for s in state["settings"]])
        for device in state["audioOutputs"] + state["audioInputs"]:
            self.assertTrue(device["name"])
            self.assertTrue(device["label"])
        # A sink monitor is a loopback of output, never a microphone.
        self.assertTrue(all(not d["name"].endswith(".monitor") for d in state["audioInputs"]))
        self.assertTrue(state["panel"]["showAudio"])

    def test_the_panel_hides_audio_when_the_devices_cannot_be_read(self):
        harness = self.harness(logged_in=True)
        # Shadow pactl with a stub that fails, rather than emptying PATH --
        # the plugin needs sh for every other command it runs.
        shadow = harness.workdir / "shadow"
        shadow.mkdir()
        stub = shadow / "pactl"
        stub.write_text("#!/bin/sh\nexit 1\n")
        stub.chmod(0o755)
        harness.env["PATH"] = f"{shadow}:{harness.env['PATH']}"
        state = harness.run()
        self.assertFalse(state["audioAvailable"])
        self.assertEqual(state["audioOutputs"], [])
        self.assertFalse(state["panel"]["showAudio"])

    # ----------------------------------------------------------- real client

    def test_real_client_is_detected_and_its_settings_are_understood(self):
        if not real_client():
            self.skipTest("official Tuple client not installed")
        harness = self.harness(fake=False)
        state = harness.run()
        self.assertTrue(state["installed"])
        self.assertEqual(state["generation"], "legacy")
        self.assertFalse(state["supportsRooms"])
        self.assertRegex(state["clientVersion"], r"^v\d{4}_\d{2}_\d{2}")
        self.assertEqual(
            sorted(s["key"] for s in state["settings"]),
            ["capture", "guest-mode", "overlay", "start-calls-muted", "transcription-model"],
        )


if __name__ == "__main__":
    unittest.main()
