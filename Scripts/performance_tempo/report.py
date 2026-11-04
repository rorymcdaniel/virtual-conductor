"""Local listening review; no server or uploaded recording required."""
import csv
import html
import json
import os
from pathlib import Path
from urllib.parse import quote

import librosa
import numpy as np
import soundfile as sf


def write_report(folder, recording, score, times, measures, manifest):
    folder = Path(folder)
    with (folder / 'tempo.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['measure', 'beat', 'quarter_note_bpm', 'recording_seconds'])
        for q in range(score.end):
            writer.writerow([score.measures[q // 4][0], q % 4 + 1,
                             f'{60 / (times[q + 1] - times[q]):.6f}', f'{times[q]:.6f}'])
        writer.writerow(['END', '', '', f'{times[-1]:.6f}'])
    (folder / 'timing.json').write_text(json.dumps(manifest | {'times': times.tolist(), 'measures': measures}, indent=2))
    print('Creating listening review with beat clicks…', flush=True)
    audio, sr = librosa.load(recording, sr=22050)
    audio = audio * (0.7 / max(float(np.max(np.abs(audio))), 1e-6))
    for q, seconds in enumerate(times[:-1]):
        count = int(sr * 0.035)
        t = np.arange(count) / sr
        click = 0.22 * np.sin(2 * np.pi * (1500 if q % 4 == 0 else 1000) * t) * np.exp(-t * 100)
        first = round(seconds * sr)
        last = min(first + count, len(audio))
        if last > first:
            audio[first:last] += click[:last - first]
    sf.write(folder / 'alignment-clicks.wav', np.clip(audio, -1, 1), sr, subtype='PCM_16')
    recording_url = quote(os.path.relpath(Path(recording).resolve(), folder.resolve()))
    rows = ''.join(f'<tr><td><button onclick="seek({m["seconds"]})">{html.escape(score.measures[i][0])}</button></td>'
                   f'<td>{m["seconds"]:.2f}</td><td>{m["bpm"]:.1f}</td>'
                   f'<td>{html.escape(", ".join(m["review"]) or "—")}</td></tr>' for i, m in enumerate(measures))
    graph = ' '.join(f'{i / max(1, len(measures) - 1) * 1000:.1f},{180 - min(180, m["bpm"]):.1f}'
                     for i, m in enumerate(measures))
    document = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Performance timing review</title><style>
body{font:17px system-ui;background:#101b23;color:#edf5f6;max-width:1080px;margin:35px auto;padding:0 24px;line-height:1.55}
h1{font-size:32px} h2{font-size:22px} a{color:#92e0d2} button,input,select{font:inherit;padding:6px 10px;border-radius:6px}
button{cursor:pointer;background:#9ce2d4;border:0;color:#142129} audio{width:100%} table{border-collapse:collapse;width:100%}
td,th{text-align:left;border-bottom:1px solid #38505e;padding:7px} .panel{background:#1c2e38;padding:18px;border-radius:12px;margin:20px 0}
label{display:inline-block;margin:8px} input{width:90px} .muted{color:#b5c8d0} #position{font-size:24px;font-variant-numeric:tabular-nums}
</style><h1>__TITLE__</h1>
<p>A listening draft following this performance. The pitch-match checks are heuristics, not a guarantee of correct beats.
Listen to the opening, flagged passages, transitions, and ending against your score before relying on the accompaniment.</p>
<div class="panel"><div id="position">Ready</div><p><label>Listen to <select id="mode" onchange="changeSource()">
<option value="clicks">Recording with beat clicks</option><option value="original">Original recording</option>__ACCOMP_OPTION__</select></label></p>
<audio id="player" controls preload="metadata" src="alignment-clicks.wav"></audio>
<p class="muted">Higher click = first beat of a measure. Click a measure below to hear its entrance. Recording timestamps include the lead-in;
accompaniment playback starts at the first score beat.</p></div>
<h2>Tempo across the movement</h2><p class="muted">Average quarter-note BPM per measure; the score contains changes on every quarter beat.</p>
<svg viewBox="0 0 1000 190" role="img" aria-label="Tempo over the movement"><polyline fill="none" stroke="#9ce2d4" stroke-width="2" points="__GRAPH__"/></svg>
<h2>Correct a landmark</h2><p>Pause at an identifiable note attack in the original recording or click track. Enter its measure and beat,
then add a landmark. Download the landmarks and give the file to the agent to regenerate the accompaniment. All times are in the original recording.</p>
<label>Measure <select id="measure">__MEASURE_OPTIONS__</select></label>
<label>Beat <input id="beat" type="number" min="1" max="4" step="1" value="1"></label>
<button onclick="addAnchor()">Mark current time</button> <button onclick="saveAnchors()">Download landmarks</button>
<p id="anchors" class="muted"></p><p>If the final release is wrong, tell the agent its time in the original recording.</p>
<h2>Measure review</h2><table><thead><tr><th>Measure</th><th>Recording seconds</th><th>Mean BPM</th><th>Check</th></tr></thead><tbody>__ROWS__</tbody></table>
<script>
const times=__TIMES__, labels=__LABELS__, end=times.length-1, original=__ORIGINAL__, landmarks=__ANCHORS__;
const player=document.querySelector('#player'), mode=document.querySelector('#mode');
function recordingTime(){return player.currentTime+(mode.value==='accompaniment'?times[0]:0)}
function seek(t){player.currentTime=Math.max(0,t-(mode.value==='accompaniment'?times[0]:0));player.play().catch(()=>{})}
function changeSource(){let t=recordingTime();player.pause();player.src=mode.value==='original'?original:mode.value==='clicks'?'alignment-clicks.wav':'accompaniment.wav';player.addEventListener('loadedmetadata',()=>{player.currentTime=Math.max(0,t-(mode.value==='accompaniment'?times[0]:0))},{once:true})}
function addAnchor(){if(mode.value==='accompaniment'){alert('Use the original recording or click track to mark a landmark.');return}
let m=Number(document.querySelector('#measure').value),b=Number(document.querySelector('#beat').value),q=(m-1)*4+b-1;
if(!Number.isFinite(q)||m%1||b%1||m<1||q<0||q>=end||b<1||b>4){alert('Choose a valid measure and whole beat.');return}
let i=landmarks.findIndex(x=>x.quarter===q);if(i>=0)landmarks.splice(i,1);landmarks.push({quarter:q,seconds:Number(recordingTime().toFixed(3))});landmarks.sort((a,b)=>a.quarter-b.quarter);showAnchors()}
function showAnchors(){document.querySelector('#anchors').textContent=JSON.stringify(landmarks)}
function saveAnchors(){let blob=new Blob([JSON.stringify(landmarks,null,2)],{type:'application/json'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='anchors.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)}
function update(){let t=recordingTime(),q=0;while(q<end&&times[q+1]<=t)q++;document.querySelector('#position').textContent=t<times[0]?'Recording lead-in':q===end?'End':`Measure ${labels[Math.floor(q/4)]} · Beat ${q%4+1} · ♩ = ${(60/(times[q+1]-times[q])).toFixed(1)}`;requestAnimationFrame(update)}
showAnchors();update();</script></html>'''
    substitutions = {'__TITLE__': html.escape(Path(recording).stem), '__ROWS__': rows, '__GRAPH__': graph,
                     '__MEASURE_OPTIONS__': ''.join(f'<option value="{i+1}">{html.escape(m[0])}</option>' for i, m in enumerate(score.measures)),
                     '__LABELS__': json.dumps([m[0] for m in score.measures]).replace('<', '\\u003c'),
                     '__TIMES__': json.dumps(times.tolist()),
                     '__ORIGINAL__': json.dumps(recording_url), '__ANCHORS__': json.dumps(manifest['anchors']),
                     '__ACCOMP_OPTION__': '<option value="accompaniment">Synthesized accompaniment</option>' if manifest['rendered'] else ''}
    for key, value in substitutions.items():
        document = document.replace(key, value)
    (folder / 'review.html').write_text(document)
