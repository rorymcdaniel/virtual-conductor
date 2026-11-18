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
