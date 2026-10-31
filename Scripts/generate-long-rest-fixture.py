#!/usr/bin/env python3
"""Create synthetic long-rest UAT music; optionally render it with MuseScore."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import wave
import xml.etree.ElementTree as ET


def element(parent, tag, text=None, **attributes):
    node = ET.SubElement(parent, tag, attributes)
    if text is not None:
        node.text = str(text)
    return node


def note(measure, duration, kind, pitch=None, dotted=False, full_rest=False):
    node = element(measure, "note")
    if pitch is None:
        element(node, "rest", **({"measure": "yes"} if full_rest else {}))
    else:
        pitched = element(node, "pitch")
        element(pitched, "step", pitch[0])
        element(pitched, "octave", pitch[1])
    element(node, "duration", duration)
    if not full_rest:
        element(node, "type", kind)
    if dotted:
        element(node, "dot")


def score():
    root = ET.Element("score-partwise", version="4.0")
    work = element(root, "work")
    element(work, "work-title", "Long rest cue trial — synthetic")
    listing = element(root, "part-list")
    for index, name in enumerate(("Solo", "Accompaniment"), 1):
        part_id = f"P{index}"
        entry = element(listing, "score-part", id=part_id)
        element(entry, "part-name", name)
        instrument = element(entry, "score-instrument", id=f"{part_id}-I1")
        element(instrument, "instrument-name", "Piano")
        midi = element(entry, "midi-instrument", id=f"{part_id}-I1")
        element(midi, "midi-channel", index)
        element(midi, "midi-program", 1)
        part = element(root, "part", id=part_id)
        for number in range(1, 10):
            measure = element(part, "measure", number=str(number))
            if number == 1:
                attributes = element(measure, "attributes")
                element(attributes, "divisions", 2)
                key = element(attributes, "key")
                element(key, "fifths", 0)
                time = element(attributes, "time")
                element(time, "beats", 4)
                element(time, "beat-type", 4)
                clef = element(attributes, "clef")
                element(clef, "sign", "G" if index == 1 else "F")
                element(clef, "line", 2 if index == 1 else 4)
                if index == 1:
                    direction = element(measure, "direction", placement="above")
                    metronome = element(element(direction, "direction-type"), "metronome")
                    element(metronome, "beat-unit", "quarter")
                    element(metronome, "per-minute", 60)
                    element(direction, "sound", tempo="60")
            if index == 2:
                for pitch in (("C", 3), ("E", 3), ("G", 3), ("E", 3)):
                    note(measure, 2, "quarter", pitch)
            elif number < 9:
                note(measure, 8, "whole", full_rest=True)
            else:
                note(measure, 4, "half")
                note(measure, 1, "eighth")
                note(measure, 3, "quarter", ("C", 5), dotted=True)
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New external directory; never overwrites an existing directory")
    parser.add_argument("--export", action="store_true", help="Render a matching native/MIDI/WAV/MusicXML bundle")
    parser.add_argument("--musescore", default="/Applications/MuseScore 4.app/Contents/MacOS/mscore")
    parser.add_argument("--timeout", type=float, default=90, help="Maximum seconds per MuseScore export (default: 90)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / "source.musicxml"
    source.write_bytes(score())
    source_hash = digest(source)
    manifest = {"source_sha256": source_hash, "tempo_bpm": 60, "measures": 9,
                "solo_staff": "Solo", "full_rest_measures": 8,
                "cue_quarter": 34, "entrance_quarter": 34.5, "exports": {}}
    manifest_path = output / "manifest.json"
    try:
        if args.export:
            native = output / "long-rest.mscz"
            jobs = [(source, native), (native, output / "long-rest.mid"),
                    (native, output / "long-rest.wav"), (native, output / "long-rest.musicxml")]
            native_hash = None
            for input_path, destination in jobs:
                log = output / (destination.suffix[1:] + ".log")
                with log.open("wb") as stream:
                    result = subprocess.run([args.musescore, str(input_path), "-o", str(destination)],
                                            stdout=stream, stderr=subprocess.STDOUT, timeout=args.timeout)
                if digest(source) != source_hash or (native_hash and digest(native) != native_hash):
                    raise RuntimeError("MuseScore changed an input; preserved outputs require inspection")
                if result.returncode or not destination.is_file() or destination.stat().st_size == 0:
                    raise RuntimeError(f"MuseScore export failed (exit {result.returncode}); inspect {log}")
                if destination == native:
                    native_hash = digest(native)
                    manifest["native_sha256"] = native_hash
                if destination.suffix == ".musicxml":
                    ET.parse(destination)
                elif destination.suffix == ".mid":
                    if not destination.read_bytes().startswith(b"MThd"):
                        raise RuntimeError(f"Invalid MIDI export: {destination}")
                elif destination.suffix == ".wav":
                    with wave.open(str(destination)) as audio:
                        if audio.getnframes() == 0:
                            raise RuntimeError(f"Empty WAV export: {destination}")
                manifest["exports"][destination.name] = {"sha256": digest(destination), "bytes": destination.stat().st_size}
                print(f"Exported {destination}", flush=True)
        manifest["status"] = "complete"
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError, wave.Error) as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise SystemExit(str(error)) from error
    finally:
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Fixture and manifest: {output}")


if __name__ == "__main__":
    main()
