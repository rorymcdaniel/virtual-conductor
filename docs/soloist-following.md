# Soloist following

The performer confirmed this design on 2026-10-31. The initial integrated
implementation is available through **Live following…** in the app.

## Confirmed decisions

- The performer configures wait points directly in the app by measure and beat.
- Accompaniment must wait for the soloist at these points before continuing.
- A wait releases when the app recognizes the expected solo entrance, rather
  than any new note or incidental sound.
- The performer enters the measure and beat in the app; the app infers the
  expected pitch from the solo part in MusicXML at that location.
- An on-time expected entrance lets accompaniment continue seamlessly through
  the wait point. It pauses only if that entrance has not occurred.
- While waiting, accompaniment falls silent rather than sustaining the
  preceding sound. This is an initial decision to revisit after testing.
- Between wait points, tempo following is bounded by a global, configurable
  tolerance, defaulting to ±10% of the planned tempo at the current location.
- The tempo tolerance is a firm limit. If the soloist slows below the allowed
  minimum between wait points, accompaniment keeps moving at that minimum,
  even if it gets ahead of the soloist. It does not stop to recover alignment.
- If tracking becomes uncertain between wait points, accompaniment briefly
  retains the last confidently followed tempo, then smoothly returns to the
  planned tempo while continuing to listen for the soloist. It keeps moving
  throughout; fallback timing remains to be determined through testing.
- When tracking recovers, accompaniment restores alignment through gradual
  tempo adjustments within the configured tolerance. It must not skip or
  replay music to catch up: continuity for the listener takes priority over
  immediate alignment.
- The intended listening setup uses headphones, including open-back headphones
  with modest accompaniment leakage and the solo instrument prominent at the
  microphone. Speaker playback is outside the initial scope. Recognition with
  headphone leakage needs real-world testing.
- Right Arrow, already sent by the performer's foot pedal, manually releases a
  wait when entrance recognition fails.
- Existing configured cadenza behavior is preserved and takes priority over
  automatic soloist following, allowing the performer to vary a cadenza freely.
- Automatically identify passages of at least one measure with soloist playing
  and no orchestra from MusicXML. The performer wants full following in these
  passages without individually configuring each passage.
- In these passages, free following tracks the performer's position through
  the written solo part, allowing extreme rubato and pauses beyond the global
  tempo tolerance.
- At the start of an automatically detected solo passage, the clicks end on
  the written boundary. The preceding orchestral sound can ring out in the WAV
  while the conductor follows the soloist. The release ends when the recording
  goes quiet or the next orchestral entrance is reached.
- After a freely followed passage, the orchestra returns at the planned tempo,
  then resumes following within the global tolerance. Extreme rubato at the
  end of the solo passage does not determine the orchestral return tempo.
- The planned-tempo return also applies when the solo part has a rest at the
  orchestral re-entry. Proposed timing is to count the written rest at planned
  tempo after recognizing the final solo note's end; the exact recognition and
  timing behavior needs validation.
- Initially, free following is restricted to unaccompanied passages. Manually
  enabling it while orchestral audio is sounding is deferred and may be
  reconsidered after testing.
- Automatically detected unaccompanied passages have no per-passage opt-out
  from free following. The soloist controls their pace through playing;
  explicitly configured cadenza behavior still takes priority.
- If the app loses the soloist's position during free following, the orchestra
  remains silent until tracking recovers or Right Arrow cues the orchestral
  return. It must not return on a timer while tracking is uncertain.
- Provide a prominent, hard-to-miss visual indication when the app loses the
  soloist's position. This is especially important during initial testing.
- Clearly distinguish "Waiting for you" during a recognized deliberate pause
  from "Tracking lost" when the app is uncertain of the soloist's position.
  Both states must be prominent and readable while playing.
- Following must tolerate occasional wrong or missed notes by recognizing
  position from the surrounding phrase. At an explicit wait point, the
  expected entrance remains required unless the performer uses Right Arrow.
- For this feature, score notation and MusicXML fermatas do not create wait
  points. Direct configuration is preferred for reliable, explicit performance
  control.
- Live following has an on/off switch for fixed-playback rehearsal and
  comparison testing. Existing pedal-controlled cadenzas work in either mode.

## Acceptance checks

- Exercise both on-time and delayed expected entrances, unrelated notes, and
  Right Arrow release at configured wait points.
- Verify bounded tempo changes, continuous playback during loss and recovery
  of tracking, and tolerance of occasional wrong or missed notes.
- Verify automatic unaccompanied-passage detection, extreme rubato and pauses,
  planned-tempo return, and silence during uncertain free following.
- Verify cadenza precedence, following disabled, and visibly distinct waiting
  and tracking-lost states.
- Test with the performer's open-back headphones and microphone. Assess audible
  return latency, recognition reliability, and audio quality during tempo
  changes; document remaining real-world limitations.

## Engineering details to validate

- Entrance recognition and return timing, including solo rests before re-entry.
- Tracking confidence, fallback timing, and smoothing of tempo adjustments.
- MusicXML interpretation and alignment with the accompaniment recording.

## Initial implementation and practical limits

- Pitch-preserving time stretching adjusts the existing WAV and its clicks
  together. The conducting position uses the adjusted playback clock.
- Live analysis uses a bounded microphone queue, short pitch-analysis windows,
  and local phrase matching. It tolerates nearby skipped/wrong notes and detects
  repeated-pitch articulation from amplitude dips. It is not a general-purpose
  score follower for arbitrary jumps, multiphonics, or chords.
- MusicXML concert pitches include chromatic and octave transposition. The
  existing import constraints still apply: linear 4/4, no pickups, repeats,
  jumps, grace notes that add time to the measure, or unsupported playback ornaments.
  Ordinary grace notes leave the written beat grid intact. Export matching
  accounts for their MIDI attacks and for repeated pitches in marked single-note
  or chord tremolos. Unsupported
  scores retain fixed playback; following explains why it cannot start.
- Explicit waits accept fractional beats but must coincide with a solo note
  attack. An attack recognized just before its boundary queues adjacent audio
  continuously. Later recognition starts the prepared return immediately;
  microphone analysis and output latency remain audible timing limits. Truly
  simultaneous reactive entrances cannot be guaranteed before instrument tests.
- After the final solo note releases, any remaining notated rest is counted at
  the planned tempo. When the solo has a note at the orchestral return, that
  entrance supplies the return cue. Right Arrow remains the fallback.
- If the orchestral return lies inside a sustained solo note, there is no
  observable attack or release at that internal beat. The app displays an
  explicit pedal cue request rather than guessing the duration of extreme
  rubato inside that note.
- A quiet microphone cannot always distinguish a deliberate pause from a
  missed note or an undetected instrument. The display reports the recognizer's
  confidence, not certain knowledge of the performer's intention.
- Headphone leakage has a synthetic signal test. Real horn playing, actual
  open-back headphone leakage, and perceived orchestral stretching quality
  remain unvalidated. Repeated identical notes without detectable articulation
  and ambiguous repeated phrases are particular cases to try.
- Wait points, solo selection, and the enable switch are stored against the
  exact MIDI and MusicXML bytes. Changed exports start with fresh following
  settings rather than silently applying stale entrance positions. The tempo
  tolerance is global. Original scores, WAV exports, and recorded takes are
  never changed by live following.

## Reproducible checks

`swift test` covers concert-pitch extraction, automatic free passages, cadenza
precedence, pitch detection with synthetic leakage, bounded tempo and fallback,
repeated-pitch articulation, capture overflow, and live transport transitions.
The live transport tests inject a microphone and audio clock; one feeds synthetic
PCM through the streaming analysis path to release an expected entrance.

For a disposable app fixture, run `python3 Scripts/generate-following-fixture.py`.
Load the three files in `.build/following-smoke/`, select **Solo**, and enable
following. Measures 1–2 are unaccompanied; the orchestra enters at measure 3.
The written solo repeats C4–D4–E4–F4 in concert pitch. A wait at measure 3, beat 1
expects C4. No user music is included in this fixture.

Validation on 2026-10-31: the full suite passed with warnings treated as errors
(93 tests, one opt-in hardware check skipped). The release app builds and
launches. Automated UI inspection reached the new main-window control, but the
existing export picker kept its confirmation button disabled for the generated
MIDI. File-type-filter experiments did not resolve it and were reverted; a full
loaded-score UI walkthrough remains unverified. Real microphone/device binding,
instrument recognition, and perceived audio timing still need an owner trial.
