"""Synthetic, asset-free checks for score timing transfer and preservation."""
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import mido
import numpy as np

from performance_tempo.alignment import read_anchors
from performance_tempo.score import Score, midi_notes, silence_part, verify_midi


def fixture(notes=None):
    return f'''<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Horn</part-name></score-part></part-list>
    <part id="P1"><measure number="1"><attributes><divisions>12</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
    <transpose><diatonic>-5</diatonic><chromatic>-9</chromatic></transpose></attributes>
    <direction><direction-type><words>Allegro</words><metronome><beat-unit>quarter</beat-unit><per-minute>128</per-minute></metronome></direction-type><sound tempo="128" dynamics="80"/></direction>
    {notes or '<note><pitch><step>C</step><octave>5</octave></pitch><duration>48</duration><type>whole</type></note>'}
    </measure></part></score-partwise>'''


class ScoreTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.folder = Path(self.work.name)
        self.source = self.folder / 'source.musicxml'
        self.source.write_text(fixture())

    def test_timing_preserves_notes_transposition_words_dynamics_and_source(self):
        original = self.source.read_bytes()
        score = Score(self.source)
        output = self.folder / 'timed.musicxml'
        score.write_timing(output, np.array([4., 4.5, 5.5, 6., 8.]))
        root = ET.parse(output).getroot()
        self.assertEqual(self.source.read_bytes(), original)
        for tag in ('note', 'transpose', 'words'):
            self.assertEqual([ET.tostring(x) for x in root.iter(tag)], [ET.tostring(x) for x in score.root.iter(tag)])
        self.assertEqual(root.find('.//sound[@dynamics]').get('dynamics'), '80')
        self.assertEqual([float(s.get('tempo')) for s in root.iter('sound') if 'tempo' in s.attrib], [120, 60, 120, 30])
        self.assertEqual([x.text for x in root.findall('.//forward/duration')], ['12', '12', '12'])
        self.assertEqual(root.findtext('.//backup/duration'), '36')
        self.assertEqual(Score(output).end, 4)

    def test_backup_chord_and_rest_voices(self):
        notes = '<note><rest/><duration>48</duration></note><backup><duration>48</duration></backup><note><pitch><step>C</step><octave>5</octave></pitch><duration>48</duration></note><note><chord/><pitch><step>E</step><octave>5</octave></pitch><duration>48</duration></note>'
        self.source.write_text(fixture(notes))
        self.assertEqual(Score(self.source).end, 4)

    def test_rejects_structures_without_performed_order_mapping(self):
        for tag in ('repeat', 'ending', 'segno', 'fermata'):
            with self.subTest(tag=tag):
                self.source.write_text(fixture().replace('</measure>', f'<{tag}/></measure>'))
                with self.assertRaises(ValueError):
                    Score(self.source)
        self.source.write_text(fixture().replace('<beats>4</beats>', '<beats>3</beats>'))
        with self.assertRaises(ValueError):
            Score(self.source)
        self.source.write_text(fixture().replace('<duration>48</duration>', '<duration>12</duration>'))
        with self.assertRaises(ValueError):
            Score(self.source)

    def test_rejects_collapsed_nan_and_missing_beat_boundaries(self):
        for times in ([0, 1, 2, 2, 4], [0, 1, float('nan'), 3, 4], [0, 1, 2, 3]):
            with self.assertRaises(ValueError):
                Score(self.source).write_timing(self.folder / 'bad.musicxml', times)

    def test_round_trip_detects_missing_inside_note_tempo(self):
        midi = mido.MidiFile(ticks_per_beat=480)
        midi.tracks.append(mido.MidiTrack([mido.MetaMessage('set_tempo', tempo=500000),
                                         mido.MetaMessage('set_tempo', tempo=1000000, time=480)]))
        output = self.folder / 'timed.mid'
        midi.save(output)
        times = np.array([5, 5.5, 6.5, 7.5, 8.5])
        self.assertLess(verify_midi(output, times), 1e-10)
        midi.tracks[0].pop()
        midi.save(output)
        with self.assertRaises(ValueError):
            verify_midi(output, times)

    def test_silences_only_selected_native_part_with_multiple_staves(self):
        source = self.folder / 'native.mscx'
        source.write_text('<museScore><Score><Part><Staff/><Staff/></Part><Part><Staff/></Part>'
                         '<Staff id="1"><Note><pitch>60</pitch></Note></Staff>'
                         '<Staff id="2"><Note><pitch>64</pitch></Note></Staff>'
                         '<Staff id="3"><Note><pitch>67</pitch></Note></Staff></Score></museScore>')
        output = self.folder / 'muted.mscx'
        self.assertEqual(silence_part(source, output, 1), 1)
        staves = ET.parse(output).getroot().findall('Score/Staff')
        self.assertIsNone(staves[0].find('.//play'))
        self.assertIsNone(staves[1].find('.//play'))
        self.assertEqual(staves[2].findtext('.//play'), '0')

    def test_anchor_validation_requires_monotonic_score_and_time(self):
        path = self.folder / 'anchors.json'
        valid = [dict(quarter=0, seconds=2), dict(quarter=4, seconds=5)]
        path.write_text(json.dumps(valid))
        self.assertEqual(read_anchors(path, 4, 6), [(0, 2), (4, 5)])
        for bad in ([valid[1], valid[0]], [valid[0], valid[0]], [dict(quarter=8, seconds=1)], [dict(quarter=1.5, seconds=3)], [dict(quarter=1, seconds=float('nan'))]):
            path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError):
                read_anchors(path, 4, 6)


if __name__ == '__main__':
    unittest.main()
