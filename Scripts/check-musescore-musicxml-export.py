#!/usr/bin/env python3
"""Exercise installed MuseScore exports using synthetic scores only, with no companion installation."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
import wave
import xml.etree.ElementTree as ET

APP = Path('/Applications/MuseScore 4.app/Contents/MacOS/mscore')
if not APP.is_file():
    raise SystemExit('MuseScore is unavailable; native export check was not run.')
if subprocess.run(['/usr/bin/pgrep', '-x', 'mscore'], capture_output=True).returncode == 0:
    raise SystemExit('Quit MuseScore before running this synthetic export check.')

WORK = Path(tempfile.mkdtemp(prefix='vc-musicxml-export-'))
print('Artifacts:', WORK, flush=True)
commands = []


def run(source, destination):
    args = [str(APP), str(source), '-o', str(destination)]
    log = WORK / f'{destination.name}.log'
    commands.append({'arguments': args, 'log': str(log)})
    (WORK / 'commands.json').write_text(json.dumps(commands, indent=2))
    with log.open('wb') as output:
        result = subprocess.run(args, stdout=output, stderr=output, timeout=180)
    if result.returncode:
        raise RuntimeError(f'MuseScore exit {result.returncode}; see {log}')


results = []
for name, bpm, midi_tempo in [('rehearsal', 120, b'\x07\xa1\x20'), ('preview', 60, b'\x0f\x42\x40')]:
    source = WORK / f'{name}-input.musicxml'
    source.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
  <part id="P1"><measure number="1">
    <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
    <direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>{bpm}</per-minute></metronome></direction-type><sound tempo="{bpm}"/></direction>
    <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
  </measure></part>
</score-partwise>
''')
    score = WORK / f'{name}.mscz'
    run(source, score)
    original = hashlib.sha256(score.read_bytes()).hexdigest()
    for extension in ['mid', 'wav', 'musicxml']:
        run(score, score.with_suffix('.' + extension))
    assert hashlib.sha256(score.read_bytes()).hexdigest() == original, 'Native snapshot was overwritten'
    xml = score.with_suffix('.musicxml')
    document = ET.parse(xml).getroot()
    assert document.tag == 'score-partwise'
    assert any(float(sound.attrib.get('tempo', 0)) == bpm for sound in document.iter('sound'))
    assert document.findtext('.//pitch/step') == 'C'
    assert document.findtext('.//pitch/octave') == '4'
    midi = score.with_suffix('.mid').read_bytes()
    assert midi.startswith(b'MThd') and b'\xff\x51\x03' + midi_tempo in midi
    with wave.open(str(score.with_suffix('.wav')), 'rb') as audio:
        frames = audio.getnframes()
        assert frames > 0
    results.append({'bundle': name, 'bpm': bpm, 'native_sha256': original,
                    'musicxml_bytes': xml.stat().st_size, 'midi_bytes': len(midi), 'wav_frames': frames})

(WORK / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
print('PASS: actual MuseScore same-snapshot MIDI/WAV/uncompressed MusicXML exports at 120 and 60 BPM; native snapshots unchanged')
print('This checks CLI exports, not the live companion UI or Keep mutation.')
