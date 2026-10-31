#!/usr/bin/env python3
"""Generate original, disposable exports for the live-following smoke check."""
import math
from pathlib import Path
import struct
import wave

destination = Path(__file__).resolve().parent.parent / ".build" / "following-smoke"
destination.mkdir(parents=True, exist_ok=True)
attributes = "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
solo = []
orchestra = []
events = []
for measure in range(4):
    prefix = f'<measure number="{measure + 1}">' + (attributes if measure == 0 else "")
    solo.append(prefix + "".join(
        f"<note><pitch><step>{step}</step><octave>4</octave></pitch><duration>1</duration></note>"
        for step in "CDEF"
    ) + "</measure>")
    content = "<rest/>" if measure < 2 else "<pitch><step>C</step><octave>3</octave></pitch>"
    orchestra.append(prefix + f"<note>{content}<duration>4</duration></note></measure>")
    for pitch in [60, 62, 64, 65]:
        events.extend([0, 0x90, pitch, 90, 0x83, 0x60, 0x80, pitch, 0])
track = bytes(events + [0, 0xFF, 0x2F, 0])
(destination / "following.mid").write_bytes(
    b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(track)) + track
)
(destination / "following.musicxml").write_text(
    '<score-partwise version="4.0"><part-list><score-part id="S"><part-name>Solo</part-name></score-part>'
    '<score-part id="O"><part-name>Orchestra</part-name></score-part></part-list><part id="S">'
    + "".join(solo) + '</part><part id="O">' + "".join(orchestra) + "</part></score-partwise>"
)
with wave.open(str(destination / "following.wav"), "wb") as output:
    output.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
    output.writeframes(b"".join(struct.pack("<h", int(
        1600 * math.sin(2 * math.pi * 130.8128 * frame / 44100)
        * min(1, max(0, (frame / 44100 - 4) * 50))
        * min(1, (8 - frame / 44100) * 50)
    )) for frame in range(8 * 44100)))
print(destination)
