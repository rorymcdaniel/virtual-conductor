# Start at a chosen measure

The owner needs to return to an earlier passage during practice without replaying
the piece. Provide a whole-measure entry, defaulting to 1 on score load, usable
while stopped, paused, waiting, or finished. Applying it prepares a fresh start;
the existing Start button begins playback. Keep the configured preparation count
and the upbeat, using the selected measure's planned tempo. The accompaniment
must begin at that measure, with no earlier music during preparation.

Pause/Resume continues from the current position. Reset returns to the selected
start and gives preparation again. Invalid measure numbers leave the existing
position intact. Changing the start does not edit the score, MIDI/WAV exports,
recorded takes, cadenza/wait settings, or tempo tolerance.

Use **Start at measure → Go → Start**. Enter also applies the measure. New exports
default to measure 1. Changing preparation or cadenza settings keeps the selected
start. The new control is disabled during playback; pause first to move elsewhere.

Both fixed playback and live following must use the same score position. Earlier
waits and cadenzas are bypassed. A start within a manual cadenza prepares first,
then waits for the existing pedal return. A start inside a free-following passage
prepares first, then listens from the chosen measure. Long-rest cues and displayed
measure numbers continue to refer to the original score.

Recognition retains a slightly early entrance across the chosen downbeat without
letting earlier waits/cadenzas interrupt preparation. A tied note that began before
the selected measure cannot move the displayed position back into the count-in.

Verification uses the existing timing, PreparedPerformance, LiveFollowing, and
PerformanceModel interfaces: selected-tempo preparation; source audio/click
alignment; invalid input; backward restart; waits/free passages/cadenzas; and
unchanged behavior starting from measure 1. The owner delegates these engineering
choices, so no product decision or technical-seam approval is needed.

## Verification on November 17, 2026

All 163 tests passed on the final code, with four opt-in hardware tests skipped.
All 43 focused release checks passed, including ten measure-start scenarios.
Independent standards and specification reviews cleared after regressions covered
slightly early held entrances, tied notes crossing the selected start, and carried
notes entering free time during ordinary playback.

The signed app was installed and checked with the owner's score. The field loaded
as 1; Go selected 48, Enter selected 32, and muted live playback completed the
preparation and advanced through the selected passage. The microphone started.
Invalid 0 retained the paused performance and displayed the valid 1–206 range.
Go and Reset then left the app Ready at 32 with two preparation measures.
Volume was restored to its pre-test value and Blackhole & Headphones remained
selected. All 29 original asset hashes and the semantic preferences matched the
pre-install snapshot, including the owner's current 30% tolerance.

No horn performance was used in the muted UI check; tracking loss without played
notes was expected and produced a local report without audio. Musical response
with the horn remains for rehearsal. The start selection is session-local and
defaults to 1 when exports are loaded or the app is reopened.
