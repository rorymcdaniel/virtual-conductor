#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["synctoolbox==1.4.2", "numpy==2.2.6", "scipy==1.15.3", "librosa==0.11.0", "soundfile==0.13.1", "mido==1.3.3"]
# ///
"""Transfer a complete recorded performance's timing to a separate MuseScore score."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

import numpy as np
import soundfile as sf

from performance_tempo.alignment import align, audio_features, read_anchors, sha256
from performance_tempo.report import write_report
from performance_tempo.score import Score, export_score, midi_notes, silence_part, verify_midi


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--score', type=Path, required=True, help='Matching uncompressed MusicXML')
    parser.add_argument('--recording', type=Path, required=True, help='WAV, FLAC, or another librosa-supported audio file')
    parser.add_argument('--output', type=Path, required=True, help='New directory for this interpretation (must not exist)')
    parser.add_argument('--solo-part', help='MusicXML part ID to silence in accompaniment audio, e.g. P13')
    parser.add_argument('--render', action='store_true', help='Also render accompaniment WAV and native MuseScore copies')
    parser.add_argument('--anchors', type=Path, help='JSON list of {quarter, seconds} landmarks; quarter is zero-based')
    parser.add_argument('--start', type=float, help='Recording seconds at score beat 1 (otherwise estimate music start)')
    parser.add_argument('--end', type=float, help='Recording seconds at final score boundary (otherwise estimate release)')
    parser.add_argument('--musescore', type=Path, default=Path('/Applications/MuseScore 4.app/Contents/MacOS/mscore'))
    parser.add_argument('--cache', type=Path, default=Path('.scratch/performance-tempo-cache'))
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output directory already exists. Choose a new name; existing interpretations are never overwritten.')
    if not args.musescore.is_file():
        parser.error('MuseScore executable not found; use --musescore.')
    score = Score(args.score)
    if args.solo_part is not None and args.solo_part not in score.names:
        parser.error('Unknown solo part. Available parts: ' + ', '.join(f'{k}: {v}' for k, v in score.names.items()))
    if args.render and args.solo_part is None:
        parser.error('--render requires --solo-part so the accompaniment leaves your solo silent.')
    args.output.mkdir(parents=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    score_hash, recording_hash = sha256(args.score), sha256(args.recording)
    print(f'Preparing {len(score.measures)} measures; originals remain unchanged.', flush=True)
    reference = args.output / 'reference.mid'
    export_score(args.musescore, args.score, reference)
    notes = midi_notes(reference)
    if max(q + d for q, d, *_ in notes) > score.end + 0.02:
        raise ValueError('MuseScore playback extends beyond the written timeline; check repeats or ornaments.')
    features = audio_features(args.recording, args.cache)
    anchors = read_anchors(args.anchors, score.end, float(features['duration']))
    times, measures, path = align(features, notes, score.end, anchors, args.start, args.end)
    np.save(args.output / 'alignment-path.npy', path)
    score.write_timing(args.output / 'performance.musicxml', times)
    # Export MIDI from the actual new MusicXML; never substitute a separately built tempo MIDI.
    export_score(args.musescore, args.output / 'performance.musicxml', args.output / 'performance.mid')
    error = verify_midi(args.output / 'performance.mid', times)
    if midi_notes(args.output / 'performance.mid') != notes:
        raise ValueError('Tempo application changed the exported notes. Inspect the score before use.')
    rendered = False
    if args.render:
        print('Rendering native score and accompaniment with MuseScore…', flush=True)
        native = args.output / 'performance.mscx'
        export_score(args.musescore, args.output / 'performance.musicxml', native)
        export_score(args.musescore, native, args.output / 'performance.mscz')
        part_index = [p.get('id') for p in score.parts].index(args.solo_part)
        muted = args.output / 'accompaniment.mscx'
        silence_part(native, muted, part_index)
        export_score(args.musescore, muted, args.output / 'accompaniment-check.mid')
        muted_notes = midi_notes(args.output / 'accompaniment-check.mid')
        # Track indices in the native MIDI must correspond exactly before trusting the mute.
        expected = [n for n in notes if n[4] != part_index]
        if muted_notes != expected:
            raise ValueError('Could not verify solo muting without changing accompaniment notes.')
        verify_midi(args.output / 'accompaniment-check.mid', times)
        export_score(args.musescore, muted, args.output / 'accompaniment.mscz')
        export_score(args.musescore, muted, args.output / 'accompaniment.wav')
        audio = sf.info(args.output / 'accompaniment.wav')
        if audio.frames <= 0 or abs(audio.duration - (times[-1] - times[0])) > 30:
            raise ValueError('Rendered audio duration does not match the timing map.')
        rendered = True
    if sha256(args.score) != score_hash or sha256(args.recording) != recording_hash:
        raise ValueError('An input changed during analysis. Rerun against a stable score and recording.')
    manifest = dict(schema=1, created=datetime.now(timezone.utc).isoformat(), score=str(args.score.resolve()),
                    recording=str(args.recording.resolve()), score_sha256=score_hash, recording_sha256=recording_hash,
                    solo_part=args.solo_part, rendered=rendered, tuning_cents=int(features['tuning']),
                    anchors=[dict(quarter=q, seconds=t) for q, t in anchors],
                    start_seconds=float(times[0]), end_seconds=float(times[-1]),
                    midi_round_trip_max_error_seconds=error, algorithm='Sync Toolbox 1.4.2 chroma + DLNCO, 50 Hz',
                    status='listening draft; heuristic review flags are not calibrated confidence')
    write_report(args.output, args.recording, score, times, measures, manifest)
    (args.output / 'complete.json').write_text(json.dumps(manifest, indent=2))
    flagged = [m['measure'] for m in measures if m['review']]
    print(f'Done: {args.output.resolve()}\nReview {len(flagged)} flagged measures in review.html.\n'
          f'MuseScore timing verified within {error:.6f}s at every beat.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f'Could not complete timing transfer: {error}', file=sys.stderr)
        sys.exit(1)
