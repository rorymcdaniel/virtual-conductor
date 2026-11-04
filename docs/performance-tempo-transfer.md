# Play with a recorded interpretation

Give the agent a complete performance recording and matching uncompressed
MusicXML. The process matches music to score positions and creates a separate
MuseScore score and synthesized accompaniment with timing at each quarter beat.
The original recording, MusicXML, and open MuseScore document remain unchanged.
This is an agent-run command workflow, without a new analysis button in the app.

WAV or FLAC is preferred; WAV is the tested input. Other librosa-supported formats
may work. Use the same movement and performed order, without cuts or extra repeats.
Export current edits from MuseScore first: analysis reads the file, not unsaved
contents of the open window. No music is uploaded. Everything runs locally after
dependencies are installed, and generated music and caches are excluded from Git.

## Repeatable command

From the repository, with MuseScore and `uv` installed:

```sh
uv run --locked --script Scripts/transfer-performance-tempo.py \
  --score 'Zweites Konzert.musicxml' \
  --recording 'RStrauss_Horn_Concerto_No2_-1M_13_Radek_Babork.wav' \
  --solo-part P13 --render \
  --output LocalData/PerformanceTempo/Babork-new
```

Choose a new output directory for every run; existing interpretations are never
overwritten. The script lock pins Python dependencies; `uv` installs its own
environment. Override the MuseScore path with `--musescore` if necessary.
Recording features are cached by SHA-256 under `.scratch/performance-tempo-cache`.

The solo ID comes from the MusicXML part list. In this score, `P13` is **Corno
Solo in Mib**, the horn in E-flat. MuseScore supplies concert-pitch MIDI for
alignment; do not assume F-horn transposition. An invalid solo ID prints the
available choices. Without `--render`, the command produces timed MusicXML/MIDI
and the listening review, without native scores or accompaniment WAV.

## Output

| File | Purpose |
| --- | --- |
| `performance.mscz` | Editable timed score with every instrument playing |
| `accompaniment.mscz` | Same notation and timing, with solo-note playback disabled |
| `performance.musicxml` | Timed interchange score and Virtual Conductor score data |
| `performance.mid` | Complete notes and verified tempo map, including the solo |
| `accompaniment.wav` | MuseScore-rendered audio without the solo |
| `review.html` | Local player, measure navigation, tempo graph and landmark editor |
| `alignment-clicks.wav` | Recording with estimated beat clicks; higher click on downbeats |
| `tempo.csv` / `timing.json` | Beat timings, source hashes and review flags |
| `complete.json` | Written only when the whole requested operation succeeds |

Other files are diagnostic artifacts. A failed run may leave an incomplete
directory; do not treat it as verified without `complete.json`. Retry into a new
directory. Tempo markings are hidden for printing; MuseScore's **Show invisible**
option can display them in gray for editing. The accompaniment copy disables
solo notes while retaining notation. Custom mix, Muse Sounds, and VST choices
from an existing native score are not preserved by the MusicXML import process.

## Listen, correct, and play

Open `review.html` locally; no server is needed. Listen to the opening, major
transitions, flagged measures, and final release against your score. Switch
between the recording, recording with clicks, and synthesized accompaniment.
Click a measure to seek to its estimated start. The visual beat follows the audio.

Flags mean weak pitch agreement or unusually uneven beat intervals. Expressive
playing can legitimately trigger them. These are heuristics, not calibrated
confidence or proof that unflagged bars are correct.

To correct a match, pause at a recognizable whole beat in the original recording
or click track. Select its measure and beat, mark a landmark, and download the
JSON. Rerun with `--anchors /path/to/anchors.json` and a new output directory.
Landmarks must increase in score position and recording time. JSON uses zero-based
quarter positions: measure 1 beat 1 is 0, measure 2 beat 1 is 4. Only whole
quarter-beat landmarks are supported.

Music boundaries are initially estimated from sustained audio activity. Noise,
applause, reverberation, and quiet openings can confuse this estimate. Specify
`--start 4.28 --end 551.54`, or include quarter 0 and the final quarter boundary
in the landmark JSON. A score starting with silence requires an explicit start.
The final release needs particular care if another movement follows immediately.

In Virtual Conductor, load **performance.mid**, **accompaniment.wav**, and
**performance.musicxml** together through **Load new exports…**. Select the solo
staff and leave live following off. Alternatively, launch the installed app:

```sh
'/Applications/Virtual Conductor.app/Contents/MacOS/VirtualConductor' \
  "$PWD/LocalData/PerformanceTempo/Babork-v2/performance.mid" \
  "$PWD/LocalData/PerformanceTempo/Babork-v2/accompaniment.wav" \
  "$PWD/LocalData/PerformanceTempo/Babork-v2/performance.musicxml"
```

Accompaniment starts at score beat 1 without the recording's lead-in. The app
supplies preparation measures. Review and CSV timestamps include the original
lead-in.

## Scope and validation

Supported scores are linear 4/4 with full bars, no repeats/jumps, and no notated
fermatas. Unsupported structures are rejected. Unnotated pauses can become slow
beat intervals; values outside 10–600 quarter-note BPM are rejected. This transfers
tempo at quarter-beat resolution, not articulation, dynamics, within-beat phrasing,
or tone quality. Different editions, cadenzas, repeated material and weak attacks
can require landmarks. Live microphone following is unchanged.

Sync Toolbox multiscale DTW matches pitch-class and pitch-onset features at 50 Hz,
after estimating recording tuning. All pitched MIDI tracks use a neutral 120-BPM
coordinate system. Timing within a held sonority is interpolated between note
attacks instead of differentiating arbitrary DTW stairs.

MuseScore re-exports every proposed score. The resulting MIDI must retain the
reference notes and agree with elapsed time at every quarter boundary within
12 ms. Solo muting must remove only the chosen track's notes. These checks prove
application of the map, not its perceptual accuracy against a real performance.

MuseScore 4.7.6 dropped offset-only tempos inside full-measure rests on the first
staff. The writer advances the MusicXML cursor using `forward` before each tempo
and restores it using `backup` before the original notes. The installed-runtime
test specifically covers this failure, including a silent first staff.

Run in the script's Python environment:

```sh
python Scripts/test_performance_tempo.py
python Scripts/check-performance-tempo.py
```

The runtime check requires MuseScore and `fluidsynth`, and generates original
synthetic music. On 2026-11-04 it recovered independently synthesized rubato with
median error 10 ms and 95th-percentile/maximum error 20 ms. It verified tempo
changes within full-measure rests, preserved transposition and notes, silenced
only the solo, and retained timing after native save/reopen. Seven unit tests
cover preservation, timing validation, unsupported structures, muting and anchors.

The first owner bundle, `LocalData/PerformanceTempo/Babork-v2`, contains 206 measures
and 824 quarter-beat tempos, with estimated recording bounds 4.28–551.54 seconds
and 56 flagged measures. MuseScore's maximum cumulative error against the requested
map was 9 microseconds. Virtual Conductor loaded it as Ready with the E-flat solo
selected and two qualifying long rests. The review page was visually checked in
Chrome. Complete human musical listening and instrument play-through are still
untested; the synthetic alignment result does not establish accuracy on every
beat of the orchestral recording.

See [primary-source research](research/performance-tempo-transfer.md).
