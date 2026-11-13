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

Accompanied matches must be near the sounding accompaniment. Doubtful matches
may recover a nearby earlier position instead of locking the search ahead.
Skipped/backwards matches begin a new timing phrase; rejected pitches contribute
no timing evidence. Tempo and position correction require at least three ordered
attacks spanning 0.6 seconds, with both the phrase fit and individual intervals
consistent. Long notes can establish a phrase; normal onset jitter is allowed.
Free following keeps its existing recognition behavior.

Synthetic regressions cover the original forward-match acceleration through the
live playback controller, missed-note recovery, backwards recovery, short and
uneven recovery phrases, long notes, and genuine faster/slower playing. Legacy
diagnostic files still decode. The private rehearsal was also replayed using both
its recorded transport positions and a simulated transport driven by the updated
controller. Neither replay accelerated through the problem passage. This is
software replay evidence; a new horn rehearsal is still the musical check.
