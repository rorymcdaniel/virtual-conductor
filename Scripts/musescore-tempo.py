#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["mido==1.3.3"]
# ///
"""Inspect the open MuseScore document and apply verified playback-only tempo edits."""

import argparse
from bisect import bisect_right
from contextlib import contextmanager
import fcntl
from fractions import Fraction
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from uuid import uuid4
from xml.etree import ElementTree as ET
from zipfile import ZipFile

import mido

SCRIPTS = Path(__file__).resolve().parent
RESOURCE = SCRIPTS.parent / 'Sources/VirtualConductor/Resources/MuseScore'
DOCUMENTS = Path.home() / 'Documents/MuseScore4'
SUPPORT = Path.home() / 'Library/Application Support/MuseScore/MuseScore4'
EXTENSION_URI = 'musescore://extensions/virtualconductor/playback-tempo'
MUSESCORE = '/Applications/MuseScore 4.app/Contents/MacOS/mscore'


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as file:
        staged = Path(file.name)
        try:
            file.write(text)
            file.close()
            staged.replace(path)
        finally:
            staged.unlink(missing_ok=True)


def write_json(path, value):
    write_text(path, json.dumps(value, allow_nan=False, ensure_ascii=False))


def read_json(path):
    return json.loads(path.read_text())


@contextmanager
def bridge_lock(bridge):
    bridge.mkdir(parents=True, exist_ok=True)
    with (bridge / 'tempo.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another playback-tempo command is running.') from None
        yield


def request(bridge, operation, **fields):
    request_file = bridge / 'tempo-request.json'
    response_file = bridge / 'tempo-response.json'
    identifier = uuid4().hex
    deadline = time.monotonic() + 5
    write_json(request_file, dict(fields, operation=operation, id=identifier, expires=(time.time() + 5) * 1000))
    try:
        while time.monotonic() < deadline:
            try:
                response = read_json(response_file)
            except (FileNotFoundError, json.JSONDecodeError):
                response = {}
            if response.get('id') == identifier:
                if not response['success']:
                    raise ValueError(response['error'])
                return response
            time.sleep(0.10)
        raise TimeoutError(f'MuseScore did not reply to {operation}. Check the companion window before retrying.')
    finally:
        request_file.unlink(missing_ok=True)


def install(bridge, plugin):
    qml = (RESOURCE / 'VirtualConductor.qml').read_text()
    write_text(plugin / 'Tempo.js', (RESOURCE / 'Tempo.js').read_text())
    write_text(plugin / 'VirtualConductor.qml', qml.replace('__BRIDGE_PATH__', json.dumps(str(bridge))))
    return {'installed': str(plugin), 'next': 'Reload plugins in MuseScore and run Virtual Conductor.'}


def window_info():
    try:
        result = subprocess.run(['swift', str(SCRIPTS / 'musescore-document.swift')], capture_output=True,
                                text=True, timeout=6, check=True)
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return {}


def document_path(document, window, session):
    if path := window.get('path'):
        return Path(path).resolve(), 'window'
    if not document:
        return None, None
    try:
        entries = read_json(session)
    except (OSError, json.JSONDecodeError):
        return None, None
    name = document['name']
    candidates = {Path(path).resolve() for path in entries if name in (Path(path).stem, Path(path).name)}
    if len(candidates) == 1:
        return candidates.pop(), 'session name'
    return None, None


def export_status(score, explicit):
    if not score or not score.is_file():
        return []
    exports = explicit or [score.with_suffix(suffix) for suffix in ('.mid', '.wav', '.musicxml')]
    score_time = score.stat().st_mtime_ns
    return [{'path': str(path), 'status': 'missing' if not path.is_file() else
             'older than score' if path.stat().st_mtime_ns < score_time else 'same age or newer'}
            for path in exports]


def run_musescore(executable, arguments, output):
    log = output.with_suffix(output.suffix + '.log')
    with log.open('wb') as stream:
        process = subprocess.run([str(executable), *map(str, arguments)], stdout=stream, stderr=stream, timeout=120)
    if process.returncode or not output.is_file() or output.stat().st_size == 0:
        raise ValueError(f'MuseScore did not produce {output.name}. See {log}.')


def transform(args, source, output, body):
    folder = args.extension
    with bridge_lock(folder):
        write_json(folder / 'manifest.json', {
            'uri': EXTENSION_URI, 'type': 'composite', 'title': 'Virtual Conductor playback tempo',
            'ui_context': 'Any', 'actions': [{'code': 'run', 'type': 'macros', 'path': 'render.js', 'show_on_appmenu': False}],
        })
        write_text(folder / 'render.js', (RESOURCE / 'Tempo.js').read_text() +
                   '\nfunction main() { var score = api.engraving.curScore; try { ' + body +
                   " } catch (error) { score.setMetaTag('vcTempoError', String(error)); } }\n")
        job = output.with_suffix('.json')
        write_json(job, [{'in': str(source), 'out': str(output)}])
        run_musescore(args.musescore, ['-j', job, '--extension', EXTENSION_URI + '?action=run'], output)


def metadata(path, key):
    with ZipFile(path) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        root_path = next(item.get('full-path') for item in container.iter('rootfile')
                         if item.get('full-path', '').endswith('.mscx'))
        root = ET.fromstring(archive.read(root_path))
    error = root.findtext('./Score/metaTag[@name="vcTempoError"]')
    if error:
        raise ValueError(error)
    value = root.find(f'./Score/metaTag[@name="{key}"]')
    if value is None:
        raise ValueError(f'MuseScore did not report {key}. See {path}.log.')
    return value.text


def midi_data(path):
    midi = mido.MidiFile(path)
    events = {Fraction(0): 500000}
    quarter = Fraction(0)
    for event in mido.merge_tracks(midi.tracks):
        quarter += Fraction(event.time, midi.ticks_per_beat)
        if event.type == 'set_tempo':
            events[quarter] = event.tempo
    notes = []
    for track in midi.tracks:
        tick = 0
        messages = []
        for event in track:
            tick += event.time
            if event.type in ('note_on', 'note_off'):
                messages.append((Fraction(tick, midi.ticks_per_beat), event.type, event.channel,
                                 event.note, event.velocity))
        notes.append(messages)
    return events, notes


def tempo_function(events):
    positions = sorted(events)
    return lambda quarter: 60_000_000 / events[positions[bisect_right(positions, quarter) - 1]]


def midi_pauses(events, notes, plan):
    # MuseScore renders a timed caesura as four extra MIDI quarters. Require
    # matching tempo events and an attack-free gap, as in MIDIFile.mappingCaesuras.
    gaps = []
    attacks = sorted(quarter for track in notes for quarter, type_, _, _, velocity in track
                     if type_ == 'note_on' and velocity)
    for quarter in sorted(set(plan['pauses'])):
        start = Fraction(round(quarter * 480), 480) + 4 * len(gaps)
        end = start + 4
        if start > 0 and start in events and end in events and not any(start <= attack < end for attack in attacks):
            gaps.append((start, end))
    return gaps


def playback_quarter(written, gaps):
    quarter = Fraction(round(written * 480), 480)
    for start, _ in gaps:
        if quarter >= start:
            quarter += 4
    return quarter


def verify_midi(baseline, candidate, plan):
    original, original_notes = midi_data(baseline)
    edited, edited_notes = midi_data(candidate)
    if edited_notes != original_notes:
        raise ValueError('The exported MIDI note events changed.')
    points = plan['points']
    gaps = midi_pauses(original, original_notes, plan)
    positions = [playback_quarter(point['quarter'], gaps) for point in points]
    start, end = positions[0], playback_quarter(plan['end'], gaps)
    actual = tempo_function(edited)
    previous = tempo_function(original)
    checkpoints = set(edited) | set(original) | set(positions) | {end}
    checkpoints.update(Fraction(beat) for beat in range(int(start), int(end) + 1))
    for quarter in sorted(checkpoints):
        if start <= quarter < end and not any(a <= quarter < b for a, b in gaps):
            expected = points[bisect_right(positions, quarter) - 1]['bpm']
        elif end == plan['scoreEnd'] and quarter >= end:
            continue
        else:
            expected = previous(quarter)
        if abs(actual(quarter) - expected) > 0.004:
            raise ValueError(f'MIDI quarter {quarter}: expected {expected:.4f} BPM, got {actual(quarter):.4f}.')


def playback_status(args):
    window = window_info()
    try:
        response = request(args.bridge, 'status', compare=args.compare_saved)
        document = response['document']
        companion_error = None
    except (TimeoutError, ValueError) as error:
        response, document, companion_error = {}, None, str(error)
    path, source = document_path(document, window, args.session)
    musical_state = None
    if args.compare_saved and path and path.suffix.lower() == '.mscz' and response.get('revision'):
        with tempfile.TemporaryDirectory(dir=args.bridge) as folder:
            copy = Path(folder) / 'status.mscz'
            transform(args, path, copy, "score.setMetaTag('vcTempoSaved', signature(score));")
            musical_state = 'matches saved score' if metadata(copy, 'vcTempoSaved') == response['revision'] else 'differs'
    return {'document': document, 'path': str(path) if path else None, 'pathSource': source,
            'saved': not window['edited'] if source == 'window' and 'edited' in window else None,
            'musicalState': musical_state, 'companionError': companion_error,
            'exports': export_status(args.score or path, args.export)}


def edit(args, live):
    source = args.score.resolve(strict=True)
    if source.suffix.lower() != '.mscz':
        raise ValueError('Choose a saved native .mscz score.')
    folder = args.bridge / 'tempo-edits' / uuid4().hex
    folder.mkdir(parents=True)
    print(f'Tempo edit artifacts: {folder}', file=sys.stderr)
    snapshot = folder / source.name
    data = source.read_bytes()
    snapshot.write_bytes(data)
    score_hash = sha256(data).hexdigest()
    fields = {'points': args.tempo, 'end': args.end}
    js_fields = json.dumps(fields)
    if live:
        prepared = request(args.bridge, 'prepare', **fields)
        window = window_info()
        path, _ = document_path(prepared['document'], window, args.session)
        if path != source or window.get('edited') is True:
            raise ValueError('Open the specified full score in MuseScore and save any pending edits first.')
        plan = prepared['plan']
    else:
        probe = folder / 'planned.mscz'
        transform(args, snapshot, probe,
                  f"score.setMetaTag('vcTempoPlan', JSON.stringify(playbackPlan(api.engraving, score, {js_fields})));")
        plan = json.loads(metadata(probe, 'vcTempoPlan'))

    baseline = folder / 'before.mid'
    run_musescore(args.musescore, [snapshot, '-o', baseline], baseline)
    events, notes = midi_data(baseline)
    fields['restoreBpm'] = tempo_function(events)(playback_quarter(plan['end'], midi_pauses(events, notes, plan)))
    candidate = folder / 'preview.mscz'
    transform(args, snapshot, candidate,
              "score.setMetaTag('vcTempoBefore', signature(score)); "
              f"applyPlayback(api.engraving, score, {json.dumps(fields)}); "
              "score.setMetaTag('vcTempoAfter', signature(score));")
    revision = metadata(candidate, 'vcTempoAfter')
    if live and metadata(candidate, 'vcTempoBefore') != prepared['revision']:
        raise ValueError('The saved file and the open full score have different musical revisions. Save the full score first.')
    preview_midi = folder / 'preview.mid'
    run_musescore(args.musescore, [candidate, '-o', preview_midi], preview_midi)
    verify_midi(baseline, preview_midi, plan)
    receipt = folder / 'receipt.json'
    write_json(receipt, {'score': str(source), 'plan': plan})
    if live:
        if sha256(source.read_bytes()).hexdigest() != score_hash:
            raise ValueError('The saved score changed during verification. Prepare the tempo edit again.')
        applied = request(args.bridge, 'apply', **fields, revision=prepared['revision'], snapshot=prepared['id'])
        if applied['revision'] != revision:
            raise ValueError('The live edit differs from the verified preview. Inspect the score and use Undo before saving.')
    return {'result': 'applied in MuseScore; save when ready' if live else 'verified preview',
            'score': str(source), 'plan': plan, 'receipt': str(receipt), 'preview': str(candidate),
            'exports': export_status(source, args.export)}


def verify_saved(args):
    receipt = args.receipt.resolve(strict=True)
    values = read_json(receipt)
    score = Path(values['score'])
    data = score.read_bytes()
    output = receipt.parent / f'saved-{uuid4().hex}.mid'
    with tempfile.TemporaryDirectory(dir=receipt.parent) as folder:
        snapshot = Path(folder) / score.name
        snapshot.write_bytes(data)
        run_musescore(args.musescore, [snapshot, '-o', output], output)
    verify_midi(receipt.parent / 'before.mid', output, values['plan'])
    if score.read_bytes() != data:
        raise ValueError('The score changed on disk during verification. Run verify again.')
    return {'result': 'verified saved score', 'score': str(score), 'exports': export_status(score, args.export)}


def position(text):
    try:
        bar, quarter = text.split(':')
        return {'measure': int(bar), 'beat': float(Fraction(quarter))}
    except (ValueError, ZeroDivisionError, OverflowError):
        raise argparse.ArgumentTypeError('Use MEASURE:BEAT, for example 165:1 or 174:3/2.') from None


def point(text):
    try:
        where, bpm = text.split('=')
        value = float(bpm)
        if not 10 <= value <= 600:
            raise ValueError
        return dict(position(where), bpm=value)
    except ValueError:
        raise argparse.ArgumentTypeError('Use MEASURE:BEAT=BPM with BPM from 10 to 600.') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', type=Path, default=DOCUMENTS / 'VirtualConductor')
    parser.add_argument('--plugin', type=Path, default=DOCUMENTS / 'Plugins/VirtualConductor')
    parser.add_argument('--session', type=Path, default=SUPPORT / 'session/session.json')
    parser.add_argument('--extension', type=Path, default=SUPPORT / 'extensions/virtual-conductor-playback-tempo')
    parser.add_argument('--musescore', type=Path, default=Path(MUSESCORE))
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('install', help='Install or update the MuseScore companion.')
    status = commands.add_parser('status', help='Read the current document, selection, and export timestamps.')
    status.add_argument('--compare-saved', action='store_true', help='Compare the open musical revision with the saved score.')
    status.add_argument('--score', type=Path, help='Report exports for this file if the active document is unavailable.')
    verify = commands.add_parser('verify', help='Verify the saved score against a playback tempo edit receipt.')
    verify.add_argument('receipt', type=Path)
    for subcommand in ('apply', 'preview'):
        command = commands.add_parser(subcommand)
        command.add_argument('--score', required=True, type=Path)
        command.add_argument('--end', required=True, type=position, help='Exclusive range end, MEASURE:BEAT.')
        command.add_argument('--tempo', required=True, action='append', type=point, help='MEASURE:BEAT=BPM, in score order.')
        command.add_argument('--export', action='append', type=Path, help='Check this export instead of same-stem defaults.')
    for command in (status, verify):
        command.add_argument('--export', action='append', type=Path, help='Check this export instead of same-stem defaults.')
    args = parser.parse_args()
    with bridge_lock(args.bridge):
        if args.command == 'install':
            result = install(args.bridge.resolve(), args.plugin)
        elif args.command == 'status':
            result = playback_status(args)
        elif args.command == 'verify':
            result = verify_saved(args)
        else:
            result = edit(args, live=args.command == 'apply')
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, ET.ParseError, StopIteration) as error:
        sys.exit(str(error))
