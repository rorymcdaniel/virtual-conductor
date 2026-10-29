#!/usr/bin/env python3
"""Installed MuseScore integration smoke check; synthetic score only. Quit MuseScore first."""
from pathlib import Path
import json, shutil, subprocess, tempfile, time, zipfile, xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
RES=ROOT/'Sources/VirtualConductor/Resources/MuseScore'
BASE=Path.home()/'Documents/MuseScore4'
WORK=Path(tempfile.mkdtemp(prefix='vc-check-',dir=BASE))
PLUGIN=BASE/'Plugins/VirtualConductor'
RENDER=Path.home()/'Library/Application Support/MuseScore/MuseScore4/extensions/virtual-conductor-render'
APP='/Applications/MuseScore 4.app/Contents/MacOS/mscore'
backup={}
for p in [PLUGIN,RENDER]:
    if p.exists():
        dst=WORK/(p.name+'-backup');shutil.copytree(p,dst);backup[p]=dst
    p.mkdir(parents=True,exist_ok=True)
def run(args):
    log=WORK/f'process-{len(list(WORK.glob("process-*")))}.log'
    with log.open('wb') as f:
        p=subprocess.run([APP]+[str(a) for a in args],stdout=f,stderr=f,timeout=60)
    if p.returncode: raise RuntimeError(f'MuseScore exit {p.returncode}; see {log}')
def native(path):
    with zipfile.ZipFile(path) as z:return ET.fromstring(z.read(next(n for n in z.namelist() if n.endswith('.mscx'))))
def command(source,operation,revision=None):
    request={'id':str(time.time_ns()),'operation':operation,'expires':time.time()*1000+30000}
    if revision is not None:request.update(revision=revision,start=0,end=8,tempos=[{'quarter':0,'bpm':120},{'quarter':1,'bpm':60},{'quarter':5,'bpm':90},{'quarter':8,'bpm':120}])
    (WORK/'request.json').write_text(json.dumps(request))
    out=WORK/f'{request["id"]}.mscz';job=WORK/'job.json';job.write_text(json.dumps([{'in':str(source),'out':str(out)}]))
    run(['-j',job,'--extension','musescore://extensions/v1/virtualconductor/virtualconductor.qml'])
    response=json.loads((WORK/'response.json').read_text());assert response['id']==request['id']
    return response,out
try:
    source=WORK/'synthetic.musicxml'
    source.write_text('''<?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note></measure><measure number="2"><note><rest/><duration>4</duration><type>whole</type></note></measure><measure number="3"><note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note></measure></part></score-partwise>''')
    # Use the real companion handler, without its persistent GUI window in the CLI harness.
    qml=(RES/'VirtualConductor.qml').read_text().replace('__BRIDGE_PATH__',json.dumps(str(WORK))).replace('pluginType: "dialog"','pluginType: ""')
    (PLUGIN/'VirtualConductor.qml').write_text(qml);shutil.copy(RES/'Tempo.js',PLUGIN/'Tempo.js')
    snapshot,baseline=command(source,'snapshot');assert snapshot['success'],snapshot
    kept,edited=command(baseline,'keep',snapshot['revision']);assert kept['success'],kept
    score=native(edited);assert len(list(score.iter('Tempo')))==4
    assert [n.findtext('pitch') for n in score.iter('Note')]==['60','62']
    stale,unchanged=command(edited,'keep',snapshot['revision']);assert not stale['success'],stale
    assert len(list(native(unchanged).iter('Tempo')))==4
    # A second keep replaces, rather than stacks, the four markings.
    reopened,_=command(edited,'snapshot')
    assert reopened['revision']==kept['revision'],'Save/reopen changed the musical signature'
    again,replaced=command(edited,'keep',reopened['revision']);assert again['success'],again
    assert len(list(native(replaced).iter('Tempo')))==4
    (RENDER/'manifest.json').write_text(json.dumps({'uri':'musescore://extensions/virtualconductor/render','type':'composite','title':'VC smoke','ui_context':'Any','actions':[{'code':'render','type':'macros','path':'render.js'}]}))
    (RENDER/'render.js').write_text((RES/'Tempo.js').read_text()+"\nfunction main() { api.engraving.curScore.setMetaTag('virtualConductorSignature', signature(api.engraving.curScore)); }")
    (WORK/'job.json').write_text(json.dumps([{'in':str(baseline),'out':str(WORK/'macro.mscz')}]))
    run(['-j',WORK/'job.json','--extension','musescore://extensions/virtualconductor/render?action=render'])
    value=next(t.text for t in native(WORK/'macro.mscz').iter('metaTag') if t.attrib.get('name')=='virtualConductorSignature')
    assert value==snapshot['revision'],'Live and CLI signatures differ'
    run([edited,'-o',WORK/'preview.mid'])
    run([edited,'-o',WORK/'preview.wav'])
    assert (WORK/'preview.mid').stat().st_size>30
    assert (WORK/'preview.wav').stat().st_size>1000
    print('PASS: snapshot, live keep, stale rejection, replacement, CLI/live agreement, separate MIDI/WAV exports')
    print('Artifacts:',WORK)
finally:
    for p in [PLUGIN,RENDER]:
        shutil.rmtree(p)
        if p in backup:shutil.copytree(backup[p],p)
