# Beat detection improvements, 2026-11-12

## Product target

Live following and **Record interpretation → Analyze** should recover the player's
pace from a monophonic solo phrase without requiring every note to be correct.
Live analysis must keep up with incoming audio, preserve attacks when microphone
buffers arrive together, and retain the existing tempo tolerance, continuous
playback, wait-point recognition, free-passage, and pedal behavior. Recordings,
score exports, and kept interpretations must remain intact.

This change covers those two native app paths. The separate Python workflow for
aligning complete commercial recordings is not the Record interpretation feature
and is unchanged.

## Reproduction and cause

The baseline was reproduced twice with generated PCM using:

```sh
swift test --filter 'BeatDetectionTests|LiveFollowingTests/testFastPhrase'
```

Before the fix:

- Eight repeated C4 notes with 20 ms tongue gaps became one observed note;
  interpretation analysis failed with “Not enough clear pitched notes”.
- A clean phrase at amplitude 0.002 produced no detected notes.
- Eight notes at 125 ms intervals, delivered in 100 ms microphone batches,
  left live free following near the first note instead of reaching the eighth.

Live polling reduced each incoming batch to its final pitch window and one
articulation flag. Intermediate attacks disappeared, and observations were timed
from UI polling rather than the sample sequence. Offline analysis had separate
pitch code, merged repeated pitches across short gaps, and rejected quiet signals
using an absolute loudness cutoff.

## Implementation

`SoloAudioAnalyzer` is a shared incremental module. It consumes samples and emits
all 10 ms observations, with a 40 ms pitch window and timestamps derived from the
sample count. Partial downsampling groups survive chunk boundaries. Its rolling
sample storage is bounded, and the live caller processes queued batches off the
main actor and outside the capture callback. Recording analysis uses the same
observations in cancellable chunks.

A short centre-window energy measurement retains articulation gaps even when a
longer pitch window overlaps sounding notes on both sides. Repeated-note runs
are preserved; the existing phrase matcher supplies the score's rhythmic grid
and can skip an occasional wrong/missed note. Tempo still comes from phrase
attacks, not a requirement to hear an attack on every beat. Held-note timing and
unplayed beats remain inferred from the surrounding phrase.

Pitch detection retains the existing [YIN cumulative normalized difference
method](https://pubmed.ncbi.nlm.nih.gov/12002874/), removes DC, uses Accelerate's
vectorized squared-distance calculation, and admits quiet periodic signals down
to an RMS floor of 0.0001. Tests also reject silence, constant DC, and seeded
broadband noise. This is not acoustic source separation: sufficiently prominent
pitched background sound can still be mistaken for the soloist.

Live capture requests 256-frame taps instead of 1024. Hardware can choose its
own delivery size. Queue overflow, batches older than the 250 ms processing
budget, and late analysis results reset analysis/phrase timing rather than
using old attacks to release a wait. Physical input/output device latency is
additional to the analysis window and is not measured by PCM replay.

## Acceptance checks

```sh
swift test -Xswiftc -warnings-as-errors
swift test -c release --filter 'BeatDetectionTests|LiveFollowingTests'
```

The generated replay checks:

- 8, 44.1, 48, and 96 kHz input; low/middle/high registers; legato, repeated,
  and short notes; onset and recorded beat errors within 40 ms.
- Phrase rate within 0.04 of the known playback-rate ratio; vibrato and one
  wrong note still recover the following and recorded phrase tempo.
- Repeated articulations with 10, 15, and 20 ms gaps; modest synthetic headphone
  leakage; quiet playing; silence, DC, and noise rejection.
- Identical observations regardless of 1024-frame or whole-recording delivery.
- Live fast-phrase recovery through the actual queue/async analysis/transport
  path, plus bounded synthetic entrance latency and stale-batch rejection.
- Processing an 8.3-second signal with p99 processing time below the 10 ms hop
  and total processing time below one quarter of the signal duration.
- Existing wait-point, cadenza, free-passage, pedal, tempo-bound, recording
  lifecycle, score, and playback tests.

The historical exact comparison with the old browser detector was replaced by
comparison with the independent synthesis clock, tightened from 80 to 40 ms.
CSV/encoding compatibility fixtures remain unchanged.

## Limits

These are deterministic synthesized instrument tests, not a claim of parity
with SmartMusic or Cadenza. Real horn attacks, room sound, microphone gain,
open-back headphone bleed, and perceived accompaniment response still need an
instrument trial. Monophonic input, the supported score format, and a detectable
articulation for repeated notes remain required. Ambiguous phrases, arbitrary
score jumps, chords, and strong accompaniment leakage are not solved here.
