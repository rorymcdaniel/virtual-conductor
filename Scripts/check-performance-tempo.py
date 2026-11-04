#!/usr/bin/env python3
"""Installed-runtime check with an independently timed, synthesized performance.

Run in the same Python environment as transfer-performance-tempo.py.
Requires MuseScore and fluidsynth. Generates only original synthetic test music.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

import mido
import numpy as np
import soundfile as sf

from performance_tempo.alignment import align, audio_features
from performance_tempo.score import Score, export_score, midi_notes, silence_part, verify_midi

APP = Path('/Applications/MuseScore 4.app/Contents/MacOS/mscore')
FONT = Path('/Applications/MuseScore 4.app/Contents/Resources/sound/MS Basic.sf3')


def main():
    folder = Path(tempfile.mkdtemp(prefix='vc-performance-tempo-'))
    print(f'Synthetic artifacts: {folder}', flush=True)
    root = ET.Element('score-partwise', version='4.0')
    listing = ET.SubElement(root, 'part-list')
    for pid, name in [('P1', 'Resting top staff'), ('P2', 'Horn in E flat'), ('P3', 'Piano')]:
        part = ET.SubElement(listing, 'score-part', id=pid)
        ET.SubElement(part, 'part-name').text = name
    pitches = ['C', 'E', 'G', 'D', 'F', 'A', 'B', 'E', 'D', 'G', 'B', 'F',
               'A', 'C', 'E', 'G', 'F', 'D', 'B', 'A', 'G', 'E', 'C', 'D',
               'E', 'A', 'F', 'B', 'D', 'G', 'C', 'E']
    for part_index, pid in enumerate(['P1', 'P2', 'P3']):
        part = ET.SubElement(root, 'part', id=pid)
        for bar in range(8):
            measure = ET.SubElement(part, 'measure', number=str(bar + 1))
            if bar == 0:
                a = ET.SubElement(measure, 'attributes')
                ET.SubElement(a, 'divisions').text = '4'
                meter = ET.SubElement(a, 'time')
                ET.SubElement(meter, 'beats').text = '4'
                ET.SubElement(meter, 'beat-type').text = '4'
                if pid == 'P2':
                    transpose = ET.SubElement(a, 'transpose')
                    ET.SubElement(transpose, 'diatonic').text = '-5'
                    ET.SubElement(transpose, 'chromatic').text = '-9'
            for beat in range(1 if pid == 'P1' else 4):
                n = ET.SubElement(measure, 'note')
                if pid == 'P1':
                    ET.SubElement(n, 'rest', measure='yes')
                else:
                    pitch = ET.SubElement(n, 'pitch')
                    ET.SubElement(pitch, 'step').text = pitches[(bar * 4 + beat + (3 if pid == 'P3' else 0)) % 32]
                    ET.SubElement(pitch, 'octave').text = '5' if pid == 'P2' else '3'
                ET.SubElement(n, 'duration').text = '16' if pid == 'P1' else '4'
                ET.SubElement(n, 'type').text = 'whole' if pid == 'P1' else 'quarter'
    source = folder / 'synthetic.musicxml'
    ET.ElementTree(root).write(source, encoding='utf-8', xml_declaration=True)
    score = Score(source)
    reference = folder / 'reference.mid'
    export_score(APP, source, reference)
    notes = midi_notes(reference)
    # Ground truth is authored independently as a MIDI tempo map, then synthesized.
    seconds_per_beat = np.array([.58, .55, .62, .70, .74, .69, .65, .60] * 4)
    lead = 0.8
    expected = np.r_[lead, lead + np.cumsum(seconds_per_beat)]
    midi = mido.MidiFile(reference)
    for track in midi.tracks:
        pending = 0
        events = []
        for e in track:
            pending += e.time
            if e.type != 'set_tempo':
                events.append(e.copy(time=pending))
                pending = 0
        track[:] = events
    tempos = mido.MidiTrack()
    for q, duration in enumerate(seconds_per_beat):
        tempos.append(mido.MetaMessage('set_tempo', tempo=round(duration * 1e6), time=0 if q == 0 else midi.ticks_per_beat))
    midi.tracks.insert(0, tempos)
    performance = folder / 'known.mid'
    midi.save(performance)
    raw = folder / 'known.wav'
    subprocess.run(['fluidsynth', '-ni', '-R', '0', '-C', '0', '-g', '0.6', '-r', '22050', '-F', str(raw), str(FONT), str(performance)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    audio, sr = sf.read(raw)
    padded = np.concatenate([np.zeros((round(lead * sr), audio.shape[1])), audio])
    sf.write(raw, padded, sr)
    features = audio_features(raw, folder)
    recovered, _, _ = align(features, notes, score.end, start=lead, finish=float(expected[-1]))
    errors = np.abs(recovered - expected)
    assert np.percentile(errors, 95) < .15 and max(errors) < .22, errors
    corrected, _, _ = align(features, notes, score.end,
                            anchors=[(0., lead), (16., float(expected[16])), (32., float(expected[-1]))])
    np.testing.assert_allclose(corrected[[0, 16, 32]], expected[[0, 16, 32]], atol=1e-10)
    # Exercise inside-bar tempo changes when the first staff has ONLY whole-measure rests.
    timed = folder / 'timed.musicxml'
    score.write_timing(timed, expected)
    export_score(APP, timed, folder / 'timed.mid')
    error = verify_midi(folder / 'timed.mid', expected)
    assert midi_notes(folder / 'timed.mid') == notes
    native = folder / 'timed.mscx'
    export_score(APP, timed, native)
    muted = folder / 'muted.mscx'
    silence_part(native, muted, 1)
    export_score(APP, muted, folder / 'muted.mid')
    assert midi_notes(folder / 'muted.mid') == [n for n in notes if n[4] != 1]
    verify_midi(folder / 'muted.mid', expected)
    # Reopen/save/export as native, the same path the owner will use.
    export_score(APP, muted, folder / 'muted.mscz')
    export_score(APP, folder / 'muted.mscz', folder / 'reopened.mid')
    verify_midi(folder / 'reopened.mid', expected)
    print(f'PASS: recovered known rubato; median={np.median(errors):.3f}s, p95={np.percentile(errors,95):.3f}s, max={max(errors):.3f}s. '
          f'MuseScore tempo error={error:.8f}s; notes/transposition retained; solo muting and native reopen verified.')


if __name__ == '__main__':
    main()
