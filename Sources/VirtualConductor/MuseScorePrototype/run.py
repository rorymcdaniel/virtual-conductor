#!/usr/bin/env python3
"""Throwaway installed-runtime proof. Uses synthetic music and temporary outputs only."""
from pathlib import Path
import json, shutil, subprocess, tempfile, zipfile, xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parent
APP = '/Applications/MuseScore 4.app/Contents/MacOS/mscore'
INSTALL = Path.home() / 'Library/Application Support/MuseScore/MuseScore4/extensions/vc-tempo-proof'
OUT = Path(tempfile.mkdtemp(prefix='vc-tempo-proof-'))

def run(*args):
    result = subprocess.run([APP, *map(str,args)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    (OUT / f'process-{len(list(OUT.glob("process-*")))}.log').write_bytes(result.stdout)
    if result.returncode: raise RuntimeError(f'MuseScore exited {result.returncode}: {args}')

def score(path):
    with zipfile.ZipFile(path) as z:
        return ET.fromstring(z.read(next(n for n in z.namelist() if n.endswith('.mscx'))))

def tempos(path):
    data=path.read_bytes(); ppq=int.from_bytes(data[12:14], 'big'); pos=14; result=[]
    while pos<len(data):
        size=int.from_bytes(data[pos+4:pos+8],'big'); b=data[pos+8:pos+8+size]; pos+=8+size; i=0; tick=0; status=0
        def vlq():
            nonlocal i
            v=0
            while True:
                x=b[i];i+=1;v=(v<<7)|(x&127)
                if x<128:return v
        while i<len(b):
            tick+=vlq()
            if b[i]>=128: status=b[i];i+=1
            if status==255:
                kind=b[i];i+=1;n=vlq(); payload=b[i:i+n];i+=n
                if kind==81:result.append([tick/ppq,int.from_bytes(payload,'big')])
            elif status in (240,247):i+=vlq()
            else:i+=1 if status&240 in (192,208) else 2
    return sorted(result)

# This dedicated scratch extension must not replace an unrelated installation.
if INSTALL.exists(): raise RuntimeError(f'Remove the previous prototype installation first: {INSTALL}')
INSTALL.mkdir(parents=True)
try:
    shutil.copy(ROOT/'manifest.json', INSTALL/'manifest.json')
    report={}
    for mode in ['apply','rollback','undo','redo']:
        script=(ROOT/'processing.js').read_text().replace('s.endCmd();', 's.endCmd(true);' if mode=='rollback' else 's.endCmd();')
        if mode in ('undo','redo'): script=script.replace('api.log.info("VC_PROOF done");','e.cmd("undo");\n'+('e.cmd("redo");\n' if mode=='redo' else '')+'api.log.info("VC_PROOF done");')
        (INSTALL/'processing.js').write_text(script)
        native=OUT/f'{mode}.mscz'; job=OUT/f'{mode}.json'
        job.write_text(json.dumps([{'in':str(ROOT/'synthetic.musicxml'),'out':str(native)}]))
        run('-j',job,'--extension','musescore://extensions/virtualconductor/tempo-proof?action=processing')
        root=score(native)
        midi=OUT/f'{mode}.mid';run(native,'-o',midi)
        report[mode]={'tempo_marks':len(list(root.iter('Tempo'))),'notes':[n.findtext('pitch') for n in root.iter('Note')], 'rests':len(list(root.iter('Rest'))),'midi_tempos':tempos(midi)}
        print(mode,json.dumps(report[mode]),flush=True)
    (OUT/'results.json').write_text(json.dumps(report,indent=2))
    print('Artifacts:',OUT)
finally:
    shutil.rmtree(INSTALL)
