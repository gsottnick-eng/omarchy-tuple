#!/usr/bin/env python3
"""Rebuild sounds/*.wav, the call sounds, from plain sine tones.

Deterministic: the same script always writes the same bytes, which
tests/sounds.test.mjs checks. Short, soft and quiet (peak about -12 dBFS) so
they sit under voices. Rising means someone arrived or something started,
falling means they left or it stopped.

    python3 tools/make-sounds.py
"""

import math
import struct
import sys
import wave
from pathlib import Path

RATE = 48000
PEAK = 0.25  # about -12 dBFS

# name: list of (frequency in Hz, or (from, to) for a glide; seconds)
SOUNDS = {
    "joined": [(659.25, 0.11), (880.0, 0.16)],
    "left": [(880.0, 0.11), (659.25, 0.16)],
    "call-start": [(523.25, 0.09), (659.25, 0.09), (783.99, 0.18)],
    "call-end": [(783.99, 0.09), (659.25, 0.09), (523.25, 0.18)],
    "mute": [(392.0, 0.09)],
    "unmute": [(783.99, 0.09)],
    "share-start": [((523.25, 1046.5), 0.24)],
    "share-stop": [((1046.5, 523.25), 0.24)],
}


def note(frequency, seconds):
    count = int(RATE * seconds)
    start, end = frequency if isinstance(frequency, tuple) else (frequency, frequency)
    phase = 0.0
    samples = []
    for i in range(count):
        t = i / RATE
        f = start + (end - start) * i / count
        phase += 2 * math.pi * f / RATE
        attack = min(1.0, t / 0.006)          # no click on the way in
        decay = math.exp(-5.0 * t / seconds)  # a soft chime, not a beep
        release = min(1.0, (count - i) / (RATE * 0.01))
        # A little second harmonic makes it warmer than a bare sine.
        tone = math.sin(phase) + 0.18 * math.sin(2 * phase)
        samples.append(tone / 1.18 * attack * decay * release)
    return samples


def render(parts):
    samples = []
    for frequency, seconds in parts:
        samples += note(frequency, seconds)
    return b"".join(struct.pack("<h", round(s * PEAK * 32767)) for s in samples)


def main(out: Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    for name, parts in SOUNDS.items():
        with wave.open(str(out / f"{name}.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(render(parts))
    return 0


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    sys.exit(main(Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "sounds"))
