# Following tempo confidence

## Accepted behavior

During the owner's rehearsal, the accompaniment accelerated around measure 27
although the MIDI and score stayed at approximately 108 BPM. A local diagnostic
reproduced the tracker mistaking sounds for later notes and treating those jumps
as faster playing. The owner approved holding the last trusted tempo whenever
the match is uncertain.

- Uncertain note matches must not accelerate or slow the orchestra, either through
  the tempo estimate or through correction of its position relative to the soloist.
- A consistent phrase must still allow genuine tempo changes within the chosen
  tolerance. The score's written tempo changes continue to apply.
- Small expressive changes remain responsive. A large change needs more evidence
  than three sustained-note attacks; while it is unconfirmed, carry the established
  pulse through the notes and any following solo rest.
- Missed or wrong notes must not leave the tracker permanently ahead of the player.
- While confidence is being recovered, hold the current playback rate. Start and
  manually cued returns continue to use the planned tempo.
- Existing free-following, wait-point, and manual cadenza behavior is preserved.
- Existing local diagnostic reports remain readable. The owner's score, audio,
  following settings, and tempo tolerance are not changed by this fix.

## Evidence

The saved diagnostic replay reproduced every recognition decision. The recorded
positions imply playback around 94 BPM before the mistake and 128–129 BPM afterward;
these are inferred transport rates, not measurements of acoustic output. No tempo
command or capture interruption occurred at the mistaken measure-27 matches.
The underlying reason for the first differing pitch readings was not established.
The private rehearsal report and its audio remain on the owner's Mac.

## Implementation and verification

Accompanied reacquisition stays near the sounding accompaniment. Plausible
immediate-next-note evidence remains available outside that window so a slow or
fast long-note phrase can establish its tempo before playback has caught up.
Doubtful matches
may recover a nearby earlier position instead of locking the search ahead.
Skipped/backwards matches begin a new timing phrase; rejected pitches contribute
no timing evidence. Tempo and position correction require at least three ordered
attacks spanning 0.6 seconds, with both the phrase fit and individual intervals
consistent. Long notes can establish a phrase; normal onset jitter is allowed.
Free following keeps its existing recognition behavior.

Changes greater than 12% relative to the tracker's established pace now need at
least four coherent attacks. For sparse phrases, the short fitting window retains
only three attacks, so the next attack must produce a coherent estimate within 5%
of the pending estimate. Sustaining a pitch cannot supply this confirmation.
Inconsistent timing, rejected pitches, skipped/backwards matches, and recognition
resets discard the pending estimate. Smaller adjustments retain the three-attack
rule. This deliberately adds an attack of latency to large changes on long notes;
it does not disable following them or reduce the user's tempo tolerance.

Synthetic regressions cover the original forward-match acceleration through the
live playback controller, missed-note recovery, backwards recovery, short and
uneven recovery phrases, long notes, and genuine faster/slower playing. Legacy
diagnostic files still decode. The private rehearsal was also replayed using both
its recorded transport positions and a simulated transport driven by the updated
controller. Neither replay accelerated through the problem passage. This is
software replay evidence; a new horn rehearsal is still the musical check.

## Sustained-note slowdown verification (2026-11-18)

The owner's later diagnostic captured three half-note attacks establishing a
0.775 rate against the planned 108 BPM, followed by a solo rest. The notes were
already interpreted with their correct lengths. The short phrase was accepted
too readily as a new tempo, and playback carried that slowdown into the rest.
The report also contains capture interruptions; the focused continuous replay
uses the uninterrupted interval at quarters 211–218 and does not replay across
those interruptions. There is no opted-in audio in this report, so the reason for
the detected attack timing is not established.

The original replay failed at 0.745–0.961 times planned tempo. With additional
confirmation it holds 0.961 throughout the passage while recognizing the notes.
Synthetic live-controller tests cover three half notes followed by a solo rest,
both apparent slowdown and acceleration, and small genuine tempo changes.
Further tests check that a fourth consistent attack permits a large change,
contradictory timing does not, pending confirmation survives diagnostic encoding,
and extended long-note phrases still reach their performed tempo. The earlier
measure-27 observation and audio replays also pass. Private reports remain local.

The complete Swift suite passed: 162 tests passed and four opt-in hardware tests
were skipped. The warnings-as-errors build passed. The signed release was installed
in Applications; its bundled replay passed all three private cases, and the app
opened Ready with the owner's score, solo staff, following setting, and output
selection restored. The 36 checked local data/export files were unchanged and
preferences were semantically unchanged (the recent-rehearsal JSON was re-encoded).
A new microphone/headphone rehearsal has not been performed for this change.

## Frequent yellow holds in the first-page rehearsal (2026-11-18)

The 11:18 rehearsal reached measure 57 with ±30% tempo tolerance. In the saved
excerpts, the controller spent about 50 seconds holding tempo during accompanied
playing while a pitch match was less than 0.2 seconds old. Position recognition can continue while the controller
waits for enough consistent attacks to change the orchestra's pace.

The run also logged 49 recognition timing resets, 24 of them within 25 ms of
the preceding reset. The earlier implementation compared microphone sample count
with the time the UI polled for audio. Delaying one read of an intact synthetic
phrase by 60 ms reproduced two resets and left its last note in Holding tempo.
On the Scarlett 2i2 at 48 kHz, a check with occasional delayed reads delivered
112 batches with continuous capture timestamps. The previous calculation would
have reset ten times. The original reports lack individual tap timestamps, so
which rehearsal resets represented real input gaps remains unknown.

The live input now publishes complete blocks with their capture timestamps.
The regression checks recognition of all four synthetic attacks and recovery of
Following status. Separate checks cover gaps inside and between batches, stale
input at a wait, and queue overflow. The banner keeps a recent pitch match mint
while showing Holding tempo, and turns yellow as the app listens for a missing
match. A new horn rehearsal is still needed to measure the effect across the page.

## Picking up a quicker pulse after measure seven

Two afternoon rehearsals on November 18 captured the accompaniment holding a
slow pace after the horn's attacks had sped up. In measures 25–26, recognizing
the same written note twice discarded the earlier attacks used to estimate
tempo. In measure 29, an uneven earlier attack outweighed four more recent
attacks that established a quicker pace.

The accompanied follower now keeps a note's original onset when it recognizes
that same note again. If the full phrase gives an inconsistent tempo estimate,
the follower checks the four latest consecutive attacks with the same timing and
minimum-duration requirements. A written repeated note still supplies a new
attack. An isolated breath still leaves the established pulse in place.

At the end of the two affected excerpts, continuous replay at the saved ±30%
tolerance showed the following commanded rates, relative to the written tempo.

| Excerpt | Previous follower | Updated follower |
| --- | --- | --- |
| Measures 25–26 | 78–89% | 93–94% |
| Measure 29 into 30 | 75% | 91–93% |

Both opening-phrase replays and the earlier steady-horn and half-note regression
cases passed. These excerpts contain detected pitches and attack times. The
effect across a complete live performance still needs a rehearsal.

## Expressive grace notes

The follower reads the grace pitches attached to each principal note on the
selected MusicXML staff. In accompanied playing it listens for the ornament near
the written beat, carries its current pace while the ornament sounds, and starts
estimating the next phrase from the principal. This also disambiguates a
principal that repeats a half-beat later. At an explicit wait on that beat, the
principal releases the orchestra. Playing the principal directly also works.

The checked rehearsal excerpts did not contain the owner's grace-note passages.
Generated audio using the concerto's solo pitches and written timing exercised
40, 150, and 250 ms ornaments in measures 157, 158, 163, and 164. Each principal
and its next four notes matched in order. The same check at the measure 156,
beat 4 wait released on the principal for all three durations. These checks
exercise pitch detection and tracking in software. The musical feel with live
horn and headphones still needs a rehearsal.
