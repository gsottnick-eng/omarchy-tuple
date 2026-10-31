#!/usr/bin/env python3
"""Rebuild preview.png, the marketplace and README picture.

Renders the real dropdown with the fake client (tests/fake-tuple, fake names
only) at 2.5x size, then lays the shots out with preview.html and
screenshots that page with headless Chromium. Needs the test venv
(see AGENTS.md) and chromium.

    .venv-harness/bin/python tools/preview/make-preview.py
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tests"))
import panel_test  # noqa: E402

SHOTS = {
    # name: (client state, harness steps, widget settings)
    "call.png": ({"in_call": True}, ["open", "wait:600"], {}),
    "settings.png": ({}, ["open", "wait:300", "settings", "wait:600"], {}),
}


def render(work: Path, name: str, state: dict, steps: list, settings: dict) -> None:
    harness = panel_test.Harness(unittest.TestCase(), logged_in=True, **state)
    harness.env["HARNESS_SCREEN"] = "4000x2400"
    run = subprocess.run
    subprocess.run = lambda command, **kw: run(command + ["--panel-shot", str(work / name)], **kw)
    try:
        harness.run(steps, settings=settings, font_size=30)
    finally:
        subprocess.run = run


def main() -> int:
    chromium = shutil.which("chromium") or shutil.which("google-chrome-stable")
    if not chromium:
        print("needs chromium", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for name, (state, steps, settings) in SHOTS.items():
            render(work, name, state, steps, settings)
        shutil.copy(HERE / "preview.html", work / "preview.html")
        subprocess.run(
            [chromium, "--headless=new", f"--user-data-dir={work / 'profile'}",
             "--disable-gpu", "--hide-scrollbars", "--window-size=1920,1080",
             "--force-device-scale-factor=2", "--virtual-time-budget=3000",
             f"--screenshot={REPO / 'preview.png'}", (work / "preview.html").as_uri()],
            check=True, capture_output=True,
        )
    print(REPO / "preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
