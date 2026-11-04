"""Score preservation and MuseScore round-trip checks, independent of alignment."""
from copy import deepcopy
from fractions import Fraction
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import mido
import numpy as np


class Score:
    def __init__(self, path):
        self.tree = ET.parse(path)
        self.root = self.tree.getroot()
        if self.root.tag != 'score-partwise':
            raise ValueError('Use an uncompressed, partwise MusicXML export from MuseScore.')
        self.parts = self.root.findall('part')
        self.names = {p.get('id'): p.findtext('part-name', p.get('id'))
                      for p in self.root.findall('part-list/score-part')}
        if not self.parts:
            raise ValueError('The score contains no parts.')
        # These must be represented as performed order before audio can map to notation.
        for tag in ('repeat', 'ending', 'segno', 'coda', 'fermata'):
            if self.root.find('.//' + tag) is not None:
                raise ValueError(f'{tag} notation is not supported yet. Use a linear score copy.')
        for sound in self.root.iter('sound'):
            if any(k in sound.attrib for k in ('dacapo', 'dalsegno', 'tocoda', 'fine')):
                raise ValueError('Playback jumps are not supported. Use a linear score copy.')
        self.measures = []
        for part in self.parts:
            timeline = []
            divisions = None
            for measure in part.findall('measure'):
                attributes = measure.find('attributes')
                if attributes is not None:
                    if attributes.find('divisions') is not None:
                        divisions = Fraction(attributes.findtext('divisions'))
                    meter = attributes.find('time')
                    if meter is not None and (meter.findtext('beats'), meter.findtext('beat-type')) != ('4', '4'):
                        raise ValueError('This version needs a constant 4/4 score, matching Virtual Conductor.')
                if divisions is None or divisions <= 0:
                    raise ValueError('Missing or invalid MusicXML divisions.')
                cursor = Fraction(0)
                extent = Fraction(0)
                for child in measure:
                    duration = Fraction(child.findtext('duration', '0')) / divisions
                    if child.tag == 'backup':
                        cursor -= duration
                    elif child.tag == 'forward':
                        cursor += duration
                    elif child.tag == 'note' and child.find('chord') is None and child.find('grace') is None:
                        cursor += duration
                    extent = max(extent, cursor)
                if extent != 4 or measure.get('implicit') == 'yes':
                    raise ValueError(f'Measure {measure.get("number")} is not a complete 4/4 bar; pickups are not supported.')
                timeline.append((measure.get('number', str(len(timeline) + 1)), divisions))
            if self.measures and [x[0] for x in timeline] != [x[0] for x in self.measures]:
                raise ValueError('Part measure timelines differ.')
            self.measures = timeline
        self.end = 4 * len(self.measures)

    def write_timing(self, destination, times):
        times = np.asarray(times, dtype=float)
        if len(times) != self.end + 1 or not np.all(np.isfinite(times)) or np.any(np.diff(times) <= 0):
            raise ValueError('Timing must contain one strictly increasing boundary per quarter beat, including the end.')
        bpms = 60 / np.diff(times)
        if np.any((bpms < 10) | (bpms > 600)):
            raise ValueError('Detected timing exceeds 10–600 BPM; correct the alignment anchors before exporting.')
        root = deepcopy(self.root)
        # Remove only tempo semantics, retaining dynamics, words, offsets, and notation.
        for parent in root.iter():
            for child in list(parent):
                if child.tag == 'sound':
                    child.attrib.pop('tempo', None)
                if child.tag == 'metronome':
                    parent.remove(child)
        for measure in root.findall('part/measure'):
            for direction in list(measure.findall('direction')):
                for dtype in list(direction.findall('direction-type')):
                    if not len(dtype):
                        direction.remove(dtype)
                if direction.find('direction-type') is None:
                    measure.remove(direction)
        # Walk the MusicXML cursor, then restore it before the original notes.
        # MuseScore drops offset-only tempos inside full-measure rests; forward/backup
        # creates the required positions even when the top orchestral staff is silent.
        # Hidden metronomes keep the printed score readable.
        for index, measure in enumerate(root.find('part').findall('measure')):
            division = self.measures[index][1]
            insert_at = next((i for i, c in enumerate(measure) if c.tag not in ('print', 'attributes')), len(measure))
            additions = []
            for beat in range(4):
                if beat:
                    forward = ET.Element('forward')
                    ET.SubElement(forward, 'duration').text = str(float(division)) if division.denominator != 1 else str(int(division))
                    additions.append(forward)
                direction = ET.Element('direction', placement='above')
                dtype = ET.SubElement(direction, 'direction-type')
                metronome = ET.SubElement(dtype, 'metronome', {'print-object': 'no'})
                ET.SubElement(metronome, 'beat-unit').text = 'quarter'
                bpm = f'{bpms[4 * index + beat]:.6f}'
                ET.SubElement(metronome, 'per-minute').text = bpm
                ET.SubElement(direction, 'sound', tempo=bpm)
                additions.append(direction)
            backup = ET.Element('backup')
            duration = 3 * division
            ET.SubElement(backup, 'duration').text = str(float(duration)) if duration.denominator != 1 else str(int(duration))
            additions.append(backup)
            for offset, element in enumerate(additions):
                measure.insert(insert_at + offset, element)
        ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)


def export_score(executable, source, destination):
    destination = Path(destination)
    with destination.with_suffix(destination.suffix + '.log').open('wb') as log:
        result = subprocess.run([str(executable), str(source), '-o', str(destination)],
                                stdout=log, stderr=log, timeout=600)
    if result.returncode or not destination.is_file() or destination.stat().st_size == 0:
        raise RuntimeError(f'MuseScore export failed: see {destination}.log')


def midi_notes(path):
    """Read concert-pitch note intervals in quarter units; track-local channels matter."""
    midi = mido.MidiFile(path)
    notes = []
    for index, track in enumerate(midi.tracks):
        tick = 0
        active = {}
        for event in track:
            tick += event.time
            if event.type == 'note_on' and event.velocity:
                active.setdefault((event.channel, event.note), []).append((tick, event.velocity))
            elif event.type == 'note_off' or (event.type == 'note_on' and not event.velocity):
                queue = active.get((event.channel, event.note), [])
                if queue:
                    start, velocity = queue.pop(0)
                    if tick > start and event.channel != 9:
                        notes.append((start / midi.ticks_per_beat, (tick - start) / midi.ticks_per_beat,
                                      event.note, velocity, index))
        if any(active.values()):
            raise ValueError('Unclosed MIDI notes in MuseScore export.')
    if not notes:
        raise ValueError('MuseScore exported no pitched notes.')
    return notes


def verify_midi(path, times, tolerance=0.012):
    """Check every exported beat against the intended elapsed performance time."""
    midi = mido.MidiFile(path)
    tempo, tick, seconds = 500000, 0, 0.0
    segments = [(0.0, 0.0, tempo)]
    for event in mido.merge_tracks(midi.tracks):
        seconds += mido.tick2second(event.time, midi.ticks_per_beat, tempo)
        tick += event.time
        if event.type == 'set_tempo':
            tempo = event.tempo
            segments.append((tick / midi.ticks_per_beat, seconds, tempo))
    errors = []
    segment = 0
    for quarter, expected in enumerate(times - times[0]):
        while segment + 1 < len(segments) and segments[segment + 1][0] <= quarter:
            segment += 1
        q, t, us = segments[segment]
        errors.append(abs(t + (quarter - q) * us / 1e6 - expected))
    maximum = max(errors)
    if maximum > tolerance:
        raise ValueError(f'MuseScore timing round trip differs by {maximum:.3f}s; no verified bundle was produced.')
    return maximum


def silence_part(source, destination, part_index):
    """Disable playback of solo notes in an audio-only native copy; retain notation."""
    tree = ET.parse(source)
    score = tree.getroot().find('Score')
    parts = score.findall('Part')
    if part_index < 0 or part_index >= len(parts):
        raise ValueError('Solo part not found in native score.')
    # MuseScore 4.7 omits IDs in Part/Staff definitions; score staves are in part order.
    offset = sum(len(p.findall('Staff')) for p in parts[:part_index])
    count_staves = len(parts[part_index].findall('Staff'))
    selected_staves = score.findall('Staff')[offset:offset + count_staves]
    count = 0
    for staff in selected_staves:
        for note in staff.iter('Note'):
            play = note.find('play')
            if play is None:
                play = ET.SubElement(note, 'play')
            play.text = '0'
            count += 1
    if count == 0:
        raise ValueError('No solo notes were found to silence.')
    tree.write(destination, encoding='utf-8', xml_declaration=True)
    return count
