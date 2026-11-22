# Natural following and rehearsal evidence

## Accepted behavior

The owner wants a dependable shared pulse, gentle accommodation of breaths and
slightly late attacks, and responsive following of sustained ritardando/rubato.
For the next rehearsal the existing tempo tolerance remains firm (the owner's
setting is 20%). The MuseScore tempo map remains the changing baseline.
Configured waits and cadenzas retain their existing entrance/pedal behavior;
this change does not infer new waits from notation or alter the owner's settings.

- Limit position correction separately from the soloist's established tempo.
  Small timing differences must not cause a large acceleration or deceleration.
  Consistent intentional tempo changes must still work within the tolerance.
- Show when accompanied playback is holding tempo while listening for evidence.
  Distinguish that state from tracking lost, a deliberate wait, and a cadenza.
- Automatically save bounded local evidence of sustained uncertainty, tracking
  loss, audio interruption, or sustained operation at a tempo limit. Keep manual
  saving. Include commanded playback rate and its reason; audio remains opt-in.
  Avoid repeated reports for the same incident and bound automatic disk storage
  without deleting manually saved reports, takes, or music.
- Make rehearsal checks repeatable through recognition and accompaniment control.
  Keep private recordings outside Git. Support local real-rehearsal regression
  cases and deterministic generated cases. Be explicit about what audio replay
  can establish and what still requires a horn rehearsal.

## Engineering validation

Tests exercise the existing public tracker/controller interfaces, LiveFollowing
with an injected clock/input/audio transport, the diagnostics save/read interface,
and the installed replay command. These seams are engineering decisions under
the owner's instruction to own testing and validation.

Check steady playing with a brief delayed attack, genuine slower/faster phrases,
changing written tempo, recovery after wrong/missed notes, confidence display,
wait/cadenza precedence, diagnostics throttling and storage failures, backwards
compatibility, and deterministic replay. Run the complete Swift suite and focused
release checks, review the changes from e2d2d21, build and install the signed app,
and preserve the owner's assets and rehearsal preferences.

## Delivered behavior

Position correction allows 35 ms of timing play and then contributes at most
four percentage points either side of the recognized phrase pace. Adjustments
use 350 ms smoothing. The final playback rate still obeys the configured global
tolerance, and genuine phrase tempo changes can use that full tolerance. These
are conservative initial tuning values, not a claim of human accompanist judgment.

**Holding tempo** means playback is keeping its current rate while listening for
fresh, consistent evidence. **Tracking lost**, **Waiting for you**, and **Cadenza**
retain their distinct meanings. Written tempo changes continue during a hold.

During accompanied playing, the next sequential attack can confirm a tentative
tempo across a brief unmatched pitch (up to 120 ms). The estimate expires after
2.5 seconds or 1.5 seconds without a match. A skipped note restarts the phrase.

**Aligning with your note attacks** means the last three distinct attacks were
each over 100 ms early or each over 100 ms late. While the current pitch matches,
the orchestra can ease toward the soloist by up to four percentage points around
the pulse it was holding. The correction fades when the evidence lapses.
The app compares each attack's microphone timestamp with the orchestra's
position between playback ticks. Input that arrives late can still describe an
on-time attack. An onset outside the available playback history supplies no
position correction.

Automatic reports capture sustained uncertainty, lost tracking, microphone
interruptions, and sustained tempo-limit operation. They save off the playback
thread, at most three per performance and 30 seconds apart; the latest 12 are
retained in `Diagnostics/Automatic`. Manual reports and takes are never pruned.
Reports include the planned BPM, estimated solo rate, position difference,
confidence, controller state, commanded rate, and adjustment reason. Optional
audio remains off by default and is controlled by the existing pre-performance
checkbox. Enable it before tomorrow's rehearsal to preserve short horn excerpts.

## Repeatable local rehearsal collection

The replay executable accepts a JSON array of cases with these fields:

```json
[
  {
    "name": "Steady phrase must keep its pulse",
    "report": "Following-example/report.json",
    "source": "audio",
    "fromQuarter": 100,
    "toQuarter": 120,
    "checkFromQuarter": 104,
    "startingRate": 0.87,
    "minimumRate": 0.8,
    "maximumRate": 1.05,
    "minimumMatches": 3,
    "maximumMedianAttackErrorBeats": 0.5
  }
]
```

```sh
swift run FollowingReplay --cases /path/to/private-cases.json
'/Applications/Virtual Conductor.app/Contents/MacOS/FollowingReplay' --cases /path/to/private-cases.json
```

Paths are relative to the manifest or absolute. `source` is `decisions` for the
captured observations, or `audio` for fresh analysis of the opted-in excerpt. Audio
must cover the case. The replay seeds recognition from the report, then runs
continuously with a simulated accompaniment driven by the same controller used
live. It requires uninterrupted accompanied passages and rejects crossing waits,
cadenzas, or recorded capture discontinuities. Assertions check rate bounds and
a minimum number of recognized attacks. Each case reports the median absolute
distance, in quarter beats, between the simulated orchestra and the written
note at the estimated onset of each matched attack. The optional
`maximumMedianAttackErrorBeats` sets a pass
threshold for that distance.
Exit codes: 0 pass, 2 changed decisions/failed musical expectations, 1 invalid input.

The first real-horn case was the measure-27 incident. Both its
recorded observations and fresh audio analysis pass, recognizing 11 attacks within the asserted problem interval and
commanding approximately 0.829–0.846 times planned tempo after the incident.
Its case manifest remains local in `.scratch/following-rehearsals.json`; neither
the owner's score nor audio is included in Git. Generated live-controller tests
cover the 60 ms late breath, sustained 0.84/1.16 tempo ratios, and written tempo
changes from 120 to 90 and back. Existing tests cover wrong notes and cadenza/
wait returns. The November 21 rehearsal adds private recorded-observation cases
for the tempo recovery at measures 32–33 and the repeated late arrivals at
measures 190–195 in `.scratch/nov21-following/cases.json`. Those excerpts have
no microphone audio. Acoustic timing and playing feel require a live rehearsal.

Using the same sample-timed replay for both versions, the opening excerpt
previously held at 76.8 BPM. It now reaches 100 BPM after the m.33 downbeat.
The ending's median absolute error fell from 0.538 to 0.439 quarter beats
across the same 12 matched attacks.

Replay does not measure physical microphone/headphone latency or the musical
quality of stretched audio. The original pitch ambiguity remains unexplained;
the controller limits its consequences. Notated pauses still require configured
wait points or cadenzas; this update does not automatically interpret fermatas.

## Verification on 2026-11-13

The warnings-as-errors suite completed 151 tests with no failures and two opt-in
hardware checks skipped. All 62 focused release checks passed. Independent
standards and specification reviews cleared after regressions fixed audio opt-out
during a failed save, expected-rest incident suppression, and recognition frozen
inside the asserted replay interval. Stable lifecycle kinds keep replay eligibility
independent of diagnostic wording, with compatibility for older reports.

PR #11 was merged, the signed release installed in Applications, and both private
horn cases passed using its bundled replay executable. The app reopened Ready with
the owner's score, existing cadenza and 20% tolerance. All 16 original music,
take, diagnostic and configuration files matched their pre-install hashes;
preferences were semantically unchanged. The selected microphone was unavailable
during the UI check, so fresh installed-app microphone capture was not tested.
Reconnect/select the intended microphone before rehearsal. Optional diagnostic
audio remained off, matching the owner's current setting.
