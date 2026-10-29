#!/usr/bin/env node
// Capture the browser implementation's current behavior for the native port.
// Expected values below are computed by importing/evaluating production code.
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
// Pass the original browser reference checkout; it is deliberately external.
if (!process.argv[2]) throw new Error('Usage: node Scripts/generate-conductor-fixtures.mjs /path/to/browser-project');
const referenceRoot = pathToFileURL(resolve(process.argv[2]) + '/');
const browser = name => new URL('Sources/VirtualConductorPrototype/' + name, referenceRoot);
const { parseMIDI, createPerformanceTiming } = await import(browser('midi-timing.mjs'));
const { compileCadenza, passageSettings } = await import(browser('cadenza.mjs'));
const { passageRange, validateBeatTimes, analyzeTake } = await import(browser('tempo-analysis.mjs'));
const { encodeWAV } = await import(browser('take-recorder.mjs'));

const fixtures = new URL('../Tests/ConductorCoreTests/Fixtures/', import.meta.url);
// Preserve production floating-point values: native parity checks need to
// distinguish exact emitted inputs from values that were pre-rounded here.
const preserve = n => n;
const json = value => JSON.stringify(value, null, 2) + '\n';

function vlq(value) {
  let n = value & 0x7f;
  while ((value >>= 7)) n = (n << 8) | ((value & 0x7f) | 0x80);
  const bytes = [];
  for (;;) { bytes.push(n & 0xff); if (n & 0x80) n >>= 8; else break; }
  return bytes;
}
function makeMidi() {
  const events = [];
  const add = (tick, bytes, order=0) => events.push({tick, bytes, order});
  add(0, [0xff,0x51,3,0x07,0xa1,0x20]); // 500000 us/qn
  add(0, [0x90,60,90]);
  add(720, [0xff,0x51,3,0x05,0xb8,0xd8], 1); // 375000 us/qn at q=1.5
  add(960, [0x80,60,0]);
  add(1680, [0xff,0x51,3,0x09,0x89,0x68], 1); // 625000 us/qn at q=3.5
  add(1920, [0x90,64,90]);
  add(2400, [0x80,64,0]);
  add(3840, [0xff,0x2f,0]);
  events.sort((a,b)=>a.tick-b.tick||a.order-b.order);
  let previous=0; const track=[];
  for (const event of events) { track.push(...vlq(event.tick-previous),...event.bytes); previous=event.tick; }
  const header=[0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xe0];
  const chunk=[0x4d,0x54,0x72,0x6b,(track.length>>>24)&255,(track.length>>>16)&255,(track.length>>>8)&255,track.length&255,...track];
  return new Uint8Array([...header,...chunk]);
}

// A tiny DOM is used only to invoke the existing tempo utility's CSV button.
async function exportGoldenCSV(score) {
  const nodes=new Map(), downloads=[];
  function element(tag='div') {
    const item={tag,children:[],value:'',disabled:false,hidden:false,open:false,textContent:'',
      classList:{toggle(){},contains(){return false}}, append(...xs){this.children.push(...xs)},
      replaceChildren(){this.children=[]}, querySelectorAll(selector){return this.children.flatMap(c=>[...(c.tag===selector?[c]:[]),...c.querySelectorAll(selector)])},
      get lastElementChild(){return this.children.at(-1)}, setAttribute(){}, addEventListener(){},
      showModal(){this.open=true}, close(){this.open=false}, click(){}, getContext(){return {clearRect(){}}}};
    return item;
  }
  const get=id=>{if(!nodes.has(id))nodes.set(id,element());return nodes.get(id)};
  for(const [id,value] of Object.entries({takeStartMeasure:'1',takeStartBeat:'1',takeEndMeasure:'2',takeEndBeat:'1',manualStart:'0.500',manualEnd:'2.000'}))get(id).value=value;
  class Capture {
    constructor(_audio,callbacks){this.callbacks=callbacks;this.recording=false;}
    async connect(){this.stream={};return true}
    start(){this.recording=true}
    async stop(){this.recording=false;this.callbacks.onTake({samples:new Float32Array(8000),sampleRate:1000,reason:'stopped'})}
    release(){this.stream=null;this.recording=false}
  }
  const audio={currentTime:1,state:'running',resume:async()=>{},createBuffer(){return {copyToChannel(){}}},createBufferSource(){return {connect(){},disconnect(){},stop(){},start(){}}}};
  const context=vm.createContext({TakeRecorder:Capture,encodeWAV,passageRange,validateBeatTimes,Float32Array,Blob,
    document:{getElementById:get,createElement:element,addEventListener(){}},
    navigator:{mediaDevices:{enumerateDevices:async()=>[]}},requestAnimationFrame:()=>1,cancelAnimationFrame(){},setTimeout(){},
    URL:{createObjectURL:blob=>{downloads.push(blob);return 'blob:fixture'},revokeObjectURL(){}},
    dependencies:{getContext:()=>audio,getDestination:()=>({}),pausePerformance:async()=>{},outputAvailable:()=>true,outputClock:()=>0,drawGesture(){}},
    score,setTimeout(){}});
  let source=await readFile(browser('tempo-utility.mjs'),'utf8');
  source=source.replace(/^import .*;\n/gm,'').replace('export function','function');
  vm.runInContext(source,context);
  vm.runInContext('const utility=setupTempoUtility(dependencies); utility.setScore(score,"fixture");',context);
  await get('tempoUtility').onclick(); await get('enableInput').onclick();
  get('recordTake').onclick(); await get('stopTake').onclick();
  // The production recorder initializes these fields from the captured take;
  // set the requested deterministic endpoints after that initialization.
  get('manualStart').value='0.500'; get('manualEnd').value='2.000';
  get('manualDraft').onclick(); get('approveTempo').onclick(); get('exportTempo').onclick();
  if(downloads.length!==1) throw new Error('Production CSV export did not produce exactly one download.');
  return await downloads[0].text();
}

// Original generated notes, no score or performance material.
function makeReferenceMidi() {
  const events = [];
  const add = (tick, bytes) => events.push({tick, bytes});
  add(0, [0xff,0x51,3,0x07,0xa1,0x20]);
  add(720, [0xff,0x51,3,0x05,0xb8,0xd8]);
  add(4080, [0xff,0x51,3,0x09,0x89,0x68]);
  for (const [pitch,start,end] of [[60,0,1],[64,1,2],[67,2,3],[62,3,4],[65,4,6],[69,6,8]]) {
    add(start*480,[0x90,pitch,90]); add(end*480,[0x80,pitch,0]);
  }
  add(64*480,[0xff,0x2f,0]); events.sort((a,b)=>a.tick-b.tick);
  let previous=0; const track=[];
  for (const e of events) { track.push(...vlq(e.tick-previous),...e.bytes); previous=e.tick; }
  return new Uint8Array([0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xe0,0x4d,0x54,0x72,0x6b,0,0,(track.length>>>8)&255,track.length&255,...track]);
}
const realBytes=makeReferenceMidi();
await writeFile(new URL('synthetic-score.mid',fixtures),realBytes);
const real=parseMIDI(realBytes.buffer.slice(realBytes.byteOffset,realBytes.byteOffset+realBytes.byteLength));
const synthetic=makeMidi();
const syntheticBuffer=synthetic.buffer.slice(synthetic.byteOffset,synthetic.byteOffset+synthetic.byteLength);
const fractional=parseMIDI(syntheticBuffer);
await writeFile(new URL('fractional-tempo.mid',fixtures),synthetic);

const realPassages=[{startMeasure:1,startBeat:2,returnMeasure:11,returnBeat:3},{startMeasure:12,startBeat:2,returnMeasure:14,returnBeat:1}];
const cadenza=compileCadenza(realPassages,real,437);
const prep={};
for(const count of [0,2]) {
  const timing=createPerformanceTiming(real,count);
  const times=[0,timing.leadSeconds,timing.prepSeconds,timing.prepSeconds+real.secondsAtQuarter(0),
    timing.prepSeconds+real.secondsAtQuarter(1),timing.prepSeconds+real.secondsAtQuarter(4),timing.musicalEnd];
  prep[count]={prepBeats:timing.prepBeats,leadSeconds:preserve(timing.leadSeconds),prepSeconds:preserve(timing.prepSeconds),
    musicalEnd:preserve(timing.musicalEnd),totalBeats:timing.totalBeats,
    samples:times.map(time=>({time:preserve(time),position:timing.position(time)}))};
}

const player=await readFile(browser('player.mjs'),'utf8');
const start=player.indexOf('const landings='); const end=player.indexOf('function context()',start);
if(start<0||end<0) throw new Error('Could not find conductor curve source in player.mjs');
const geometryContext=vm.createContext({});
vm.runInContext(`${player.slice(start,end)};globalThis.geometry={landings,controls,samples:Array.from({length:4},(_,beat)=>[0,.25,.5,.75,1].map(f=>({beat,f,point:curve(beat,f)})))};`,geometryContext);
const geometry=JSON.parse(JSON.stringify(geometryContext.geometry));

const csv=await exportGoldenCSV(real);
const reference={
  source:{midi:'synthetic-score.mid',sha256:createHash('sha256').update(realBytes).digest('hex'),bytes:realBytes.byteLength,
    ppqn:real.ppqn,trackCount:real.tracks.length,trackNotes:real.tracks.map(t=>({name:t.name,notes:t.notes})),
    endQuarter:real.endQuarter,duration:preserve(real.duration),openingBPM:preserve(real.openingBPM),measures:real.measures,
    tempoSegments:real.segments.map(s=>({quarter:preserve(s.quarter),seconds:preserve(s.seconds),secondsPerQuarter:preserve(s.secondsPerQuarter)}))},
  preparation:prep,
  cadenza:{input:realPassages,settings:passageSettings(cadenza),compiled:cadenza.map(p=>Object.fromEntries(Object.entries(p).map(([k,v])=>[k,typeof v==='number'?preserve(v):v])))},
  geometry,
  csv:{range:{startMeasure:1,startBeat:1,endMeasure:2,endBeat:1},manualEndpointsSeconds:[0.5,2],text:csv,
    semantics:{header:csv.split('\r\n')[0],lineEnding:'CRLF',tempoPrecision:3,restoreOriginalTempo:true,restorationBoundary:'exclusive end beat'}}
};
await writeFile(new URL('reference.json',fixtures),json(reference));

const fractionalJson={source:'fractional-tempo.mid',sha256:createHash('sha256').update(synthetic).digest('hex'),bytes:synthetic.byteLength,
  parsed:{ppqn:fractional.ppqn,endQuarter:fractional.endQuarter,duration:preserve(fractional.duration),openingBPM:preserve(fractional.openingBPM),
    tempoSegments:fractional.segments.map(s=>({quarter:preserve(s.quarter),seconds:preserve(s.seconds),secondsPerQuarter:preserve(s.secondsPerQuarter)})),
    probes:[0,1,1.5,2.75,3.5,4,8].map(quarter=>({quarter,seconds:preserve(fractional.secondsAtQuarter(quarter)),roundTrip:preserve(fractional.quarterAtSeconds(fractional.secondsAtQuarter(quarter))),bpm:preserve(fractional.tempoAtSeconds(fractional.secondsAtQuarter(quarter)))}))}};
await writeFile(new URL('fractional-tempo.json',fixtures),json(fractionalJson));
process.stdout.write(`Generated reference fixtures: ${realBytes.byteLength} synthetic reference MIDI bytes; SHA-256 ${reference.source.sha256}; ${synthetic.byteLength} synthetic MIDI bytes.\n`);

// Independent browser analysis of generated original pitches and synthetic PCM.
const rate=16000, seconds=q=>1.5+q*.6+q*q*.01;
const samples=new Float32Array(Math.ceil((seconds(8)+.3)*rate));
for(const n of real.tracks[0].noteEvents){
  const start=seconds(n.startQuarter),end=seconds(Math.min(8,n.endQuarter)),f=440*2**((n.pitch-69)/12);
  for(let i=Math.ceil(start*rate);i<Math.floor(end*rate);i++){
    const t=i/rate-start,e=Math.min(1,t/.01,(end-i/rate)/.015);
    samples[i]=.3*e*(Math.sin(2*Math.PI*f*t)+.2*Math.sin(4*Math.PI*f*t));
  }
}
const analysis=analyzeTake(samples,rate,real.tracks[0].noteEvents,{start:0,end:8});
await writeFile(new URL('synthetic-analysis.json',fixtures),json({beats:analysis.beats,matched:analysis.matched}));
