# Edit MuseScore playback tempos

Use the playback-tempo command to change the sound of the open score while preserving its written directions. It verifies a preview using MuseScore’s MIDI export, then applies the edit in one Undo action. **Keep it** in a Virtual Conductor rehearsal remains the separate workflow for applying a recording’s interpretation.

## Connect the companion

Run `Scripts/musescore-tempo.py install` from this checkout. The command uses `uv` and the installed MuseScore Studio app. In MuseScore, open **Plugins → Manage plugins**, reload plugins, enable **Virtual Conductor**, and run **Plugins → Virtual Conductor**. Leave its small window open. After an update, close and reopen that window so it loads the new code.

Run `Scripts/musescore-tempo.py status` to check the active score and selection. Open the full score tab before editing. A range selection reports an inclusive start and exclusive end. The command uses macOS window metadata for the path and saved state when available. If that lookup is unavailable, the companion’s score name can identify a unique matching document in the MuseScore session, and the saved state is reported as unknown. Add `--compare-saved` to compare the open musical content with the disk copy. This comparison covers the musical fingerprint and can miss layout and mixer changes.

## Edit and verify

1. Save the native score in MuseScore. Specify the first tempo and any later changes in score order. Use written measure numbers and quarter-note beats, with beat 1 at the start of the bar. Fractions such as `174:3/2` are accepted. Specify the first beat outside the edit as the exclusive end.
2. Use `preview` to verify an isolated copy, or `apply` to verify the copy and apply the same edit to the open score. The command checks the source and the active score again before applying. An edit that timed out may already have been applied. Check MuseScore before retrying.
3. Save in MuseScore when satisfied. Run `Scripts/musescore-tempo.py verify RECEIPT` using the receipt path in the command's output. It exports MIDI from the saved file, checks the requested tempos and the original tempo behavior outside the edit, and compares MIDI note events.

Example with ♩ = 100 throughout measures 165–172, followed by 95, 90 and 85 at measures 173–175.

```sh
Scripts/musescore-tempo.py apply \
  --score "/path/to/score.mscz" \
  --tempo 165:1=100 --tempo 173:1=95 --tempo 174:1=90 --tempo 175:1=85 \
  --end 176:1
```

The command updates the playback value of written tempo text, sets contained gradual changes to a neutral playback factor, and inserts hidden tempo marks where needed. The tempo at the exclusive end returns to the original value. Include a whole gradual change if the edit overlaps it. Supported scores have a straight 4/4 timeline without repeats, jumps, or pickups. The verifier accounts for MIDI bars MuseScore inserts at timed caesuras.

Verification and status report MIDI, WAV, and MusicXML files with the same name as the score. Use repeatable `--export PATH` arguments for files stored elsewhere. **Older than score** means an export may still use the previous tempo. **Same age or newer** is a timestamp check. Re-export a matching set or prepare the connected rehearsal when you need updated accompaniment. The command leaves existing exports in place.

Run `Scripts/check-musescore-playback-tempo.py` to exercise the native companion handler and MIDI verification using a disposable score.
