# Transferring a recorded performance's timing

Research and implementation observations, 2026-11-04.

## Recommended approach

Align the recording with the score's sounding pitches, then derive a time for each
score beat. A single BPM estimate cannot identify which measure is being played
or reproduce expressive changes in speed. This is an offline alignment problem;
it is independent of the app's live soloist following.

Chroma features describe energy in twelve pitch classes and reduce sensitivity
to instrumentation and octave differences. That makes them useful for matching
an orchestral recording with a symbolic or synthesized reference. They do not
uniquely identify repeated material or the position inside a sustained chord.
[AudioLabs Chroma Toolbox](https://www.audiolabs-erlangen.de/resources/MIR/chromatoolbox/)
describes the representation and its musical motivation.

The official [librosa music synchronization example](https://librosa.org/doc/1.0.0/auto_tutorials/03-advanced/plot_music_sync.html)
demonstrates chroma plus dynamic time warping (DTW) for recordings with variable
tempos. Basic full-matrix DTW is a useful baseline, but the production choice here
is [Sync Toolbox](https://github.com/groupmm/synctoolbox), whose reference pipeline
combines memory-restricted multiscale DTW and onset-sensitive refinement. Its
repository includes an audio-to-score notebook. This avoids requiring a complete
synthetic audio render merely to construct alignment features.

The implemented pipeline uses pinned Sync Toolbox 1.4.2, quantized chroma and
decaying locally normalized chroma onset features (DLNCO), at 50 frames/second.
MuseScore exports a full-score MIDI reference; note positions are converted to
a neutral 120-quarter-notes/minute coordinate system so original tempo markings
do not dictate the result. The recording is decoded to mono at 22,050 Hz and its
tuning deviation is estimated before extracting features. These settings are
engineering choices for this workflow, not a published guarantee of accuracy.

## Score interpretation and playback

The supplied MusicXML has 20 parts and 206 measures, all in 4/4, with no repeat,
ending or fermata elements. Part P13 is **Corno Solo in Mib**, with a chromatic
transpose of -9 semitones; the orchestral horns transpose by -7. The solo must
not be treated as a horn in F. MusicXML transposition specifies the adjustment
from written to sounding pitch. Using MuseScore's MIDI export delegates this
interpretation to the notation application.
[MusicXML transpose specification](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/transpose/)

MusicXML playback tempo is expressed in quarter notes per minute, irrespective
of the displayed beat unit. A sound can carry its own offset, or a direction can
use an offset with `sound="yes"`; otherwise a direction offset defaults to visual
placement only. These rules matter when inserting tempo changes inside notes or
rests. [Sound specification](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/sound/),
[offset specification](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/offset/).

An interoperability experiment during implementation found that offset-only
tempo directions survived inside held notes but were dropped inside full-measure
rests: 824 requested beat tempos became 257 MIDI events, with approximately 11.2
seconds of cumulative drift. Explicit `forward` elements before each beat tempo,
followed by a `backup` before the unchanged original notes, preserved all 824
events. The final MIDI round trip differed from requested beat times by at most
9 microseconds. These are local observations of the installed MuseScore, not
claims about every MusicXML consumer.

MuseScore's documented converter supports `-o` for output selected by extension,
including MIDI, MusicXML, native scores and WAV; `-j` supports conversion jobs.
The handbook cautions that its command reference originated in version 3, so
actual exports must be checked. [MuseScore command-line reference](https://handbook.musescore.org/appendix/command-line-usage).
The implementation therefore verifies the MIDI exported from the resulting
MusicXML rather than substituting an independently generated tempo MIDI.

## Reusable process and validation

Run `Scripts/transfer-performance-tempo.py` with a matching MusicXML score, a
recording and a new output directory. Use `--render --solo-part P13` for this
concerto. WAV and FLAC are preferred inputs; other supported audio formats are
decoded by librosa. The script retains source hashes and refuses to reuse an
existing output directory. Its embedded dependency declaration pins the analysis
environment. See the user workflow documentation for the complete invocation.

The output includes a timed MusicXML copy, full-score MIDI, native MuseScore
copies, accompaniment WAV, beat timing data and an HTML listening review.
Keeping the solo in the full-score MIDI supports the app's solo-staff mapping;
only accompaniment audio should omit it. The implementation silences native
solo notes using `play=0` without deleting notation. Local verification found
exactly 6,247 accompaniment notes remaining from the original 7,117, with all
non-solo notes unchanged. Native save/reopen was also exercised.

The generated Babork interpretation in `LocalData/PerformanceTempo/Babork-v2`
maps the first score beat to recording time 4.28 seconds and the final boundary
to 551.54 seconds. These are estimated musical boundaries, not the file's whole
duration. Playback output begins at score time zero: introductory recording
silence is not a count-in, and recording time is recovered by adding the start
offset. Reverberation after the final attack is not necessarily notated duration;
the first and last measures always need listening review. Explicit `--start`,
`--end` and monotonically ordered `{quarter, seconds}` landmarks can correct them
or constrain ambiguous internal passages.

Synthetic known-timing validation reported 10 ms median error and 20 ms
95th-percentile/maximum error. This checks recovery on the controlled fixture,
not accuracy on the commercial orchestral performance. The native app loaded
the actual bundle as 206 measures and found two long-rest cues for P13.

## Limits and review

The actual interpretation has 56 measures flagged by heuristics for weak pitch
matching, uneven beat timing or recording boundaries. These flags are review
prompts, not calibrated confidence probabilities. A successful DTW path and
accurate tempo export do not prove that every beat corresponds to the right
musical event. Listen around flags, important entrances and transitions; add
landmarks and rerun into a new directory when needed.

The current linear score workflow rejects unsupported repeats and jumps rather
than guessing the performed order. In a future expanded-score workflow, repeat
visits must be explicit: different timing on two visits cannot generally be
represented by one ordinary tempo per written position. The MusicXML `time-only`
attribute can distinguish repeat passes, but application support would require
separate verification. [MusicXML sound specification](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/sound/).

Timing is interpolated between note attacks before quarter-beat tempos are
computed. This avoids turning arbitrary DTW steps within sustained sonorities
into spurious tempo fluctuations, but cannot recover unobservable motion within
a held sound or every within-beat expressive detail. Cuts, additions, alternate
cadenzas, substantial score discrepancies and applause can also mislead alignment.
These require explicit review or a matching score; the present output is a
usable listening draft rather than a claim of exact transcription.
