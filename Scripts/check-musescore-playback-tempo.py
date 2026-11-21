#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["mido==1.3.3"]
# ///
"""Exercise the MuseScore playback-tempo companion on a disposable four-bar score."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
from uuid import uuid4
from xml.etree import ElementTree as ET
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location('musescore_tempo', Path(__file__).with_name('musescore-tempo.py'))
tempo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tempo)

MUSIC = '''<?xml version="1.0"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
      <direction><direction-type><words>Andante</words></direction-type><sound tempo="100"/></direction>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
    </measure>
    <measure number="2">
      <note><rest measure="yes"/><duration>4</duration></note>
    </measure>
    <measure number="3">
      <direction><direction-type><words>Più mosso</words></direction-type><sound tempo="152"/></direction>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
    </measure>
    <measure number="4">
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
    </measure>
  </part>
</score-partwise>
'''
RUN_REQUESTS = '''
    onRun: {
        var score = curScore;
        score.selection.selectRange(0, 1920, 0, 1);
        processTempoRequest();
        statusOutput.write(tempoResponseFile.read());
        score.selection.clear();
        var preparation = handleTempoRequest(JSON.parse(prepareFile.read()));
        preparationOutput.write(JSON.stringify(preparation));
        if (!preparation.success) return;
        var application = JSON.parse(applyFile.read());
        application.revision = preparation.revision;
        application.snapshot = preparation.id;
        tempoResponseFile.write(JSON.stringify(handleTempoRequest(application)));
        application.id = "replay";
        repeatResult.write(JSON.stringify(handleTempoRequest(application)));
    }
    FileIO { id: statusOutput; source: root.bridge + "/status-result.json" }
    FileIO { id: preparationOutput; source: root.bridge + "/prepare-result.json" }
    FileIO { id: prepareFile; source: root.bridge + "/prepare.json" }
    FileIO { id: applyFile; source: root.bridge + "/apply.json" }
    FileIO { id: repeatResult; source: root.bridge + "/replay-result.json" }
'''


def native_score(path):
    with ZipFile(path) as archive:
        return ET.fromstring(archive.read(next(name for name in archive.namelist() if name.endswith('.mscx'))))


def main():
    plugin_name = 'vctempocheck' + uuid4().hex
    plugin = tempo.DOCUMENTS / 'Plugins' / plugin_name
    with tempfile.TemporaryDirectory(prefix='vc-playback-tempo-') as root:
        work = Path(root)
        source = work / 'music.musicxml'
        source.write_text(MUSIC)
        original = work / 'test-score.mscz'
        tempo.run_musescore(tempo.MUSESCORE, [source, '-o', original], original)
        original_bytes = original.read_bytes()
        timestamp = (time.time() + 120) * 1000
        edit = {'points': [{'measure': 2, 'beat': 1.5, 'bpm': 95}], 'end': {'measure': 4, 'beat': 1}}
        tempo.write_json(work / 'tempo-request.json', {'id': 'status', 'expires': timestamp, 'operation': 'status'})
        tempo.write_json(work / 'prepare.json', dict(edit, id='prepare', expires=timestamp, operation='prepare'))
        tempo.write_json(work / 'apply.json', dict(edit, id='apply', expires=timestamp, operation='apply',
                                                    restoreBpm=152))
        qml = (tempo.RESOURCE / 'VirtualConductor.qml').read_text()
        start, end = qml.index('    onRun:'), qml.index('    Text {')
        qml = qml[:start] + RUN_REQUESTS + qml[end:]
        qml = qml.replace('__BRIDGE_PATH__', json.dumps(str(work))).replace('pluginType: "dialog"', 'pluginType: ""')
        try:
            tempo.write_text(plugin / f'{plugin_name}.qml', qml)
            shutil.copy(tempo.RESOURCE / 'Tempo.js', plugin / 'Tempo.js')
            edited = work / 'edited.mscz'
            job = work / 'job.json'
            tempo.write_json(job, [{'in': str(original), 'out': str(edited)}])
            uri = f'musescore://extensions/v1/{plugin_name}/{plugin_name}.qml'
            tempo.run_musescore(tempo.MUSESCORE, ['-j', job, '--extension', uri], edited)
        finally:
            shutil.rmtree(plugin)
        status = tempo.read_json(work / 'status-result.json')
        assert status['success'], status
        assert status['document']['selection'] == {
            'kind': 'range',
            'locations': [{'measure': 1, 'tick': 0, 'quarterBeat': 1},
                          {'measure': 2, 'tick': 1920, 'quarterBeat': 1}],
        }, status
        prepared = tempo.read_json(work / 'prepare-result.json')
        assert prepared['success'] and prepared['id'] == 'prepare', prepared
        plan = prepared['plan']
        applied = tempo.read_json(work / 'tempo-response.json')
        assert applied['success'], applied
        replay = tempo.read_json(work / 'replay-result.json')
        assert not replay['success'], replay
        score = native_score(edited)
        markings = list(score.iter('Tempo'))
        assert len(markings) == 4, [ET.tostring(t) for t in markings]
        assert any('Più mosso' in (t.findtext('text') or '') and
                   abs(float(t.findtext('tempo')) * 60 - 95) < 0.001 for t in markings)
        assert sum(t.findtext('visible') == '0' for t in markings) == 2
        assert original.read_bytes() == original_bytes
        baseline, output = work / 'before.mid', work / 'edited.mid'
        tempo.run_musescore(tempo.MUSESCORE, [original, '-o', baseline], baseline)
        tempo.run_musescore(tempo.MUSESCORE, [edited, '-o', output], output)
        tempo.verify_midi(baseline, output, plan)
        explicit = work / 'claimed.mid'
        assert tempo.export_status(edited, [explicit])[0]['status'] == 'missing'
        shutil.copyfile(output, explicit)
        assert tempo.export_status(edited, [explicit])[0]['status'] == 'same age or newer'
        os.utime(explicit, (timestamp / 1000 - 240, timestamp / 1000 - 240))
        assert tempo.export_status(edited, [explicit])[0]['status'] == 'older than score'
        print('PASS: native selection, prepared playback edit, duplicate rejection, hidden and written tempos, MIDI and export status')


if __name__ == '__main__':
    main()
