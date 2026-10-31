# Synthetic long-rest trial

Generate a new, disposable passage outside the repository:

```sh
python3 Scripts/generate-long-rest-fixture.py /tmp/long-rest-trial --export
```

The directory must not exist. Without `--export`, the script writes only the source MusicXML and manifest. `--musescore /path/to/mscore` selects another installed MuseScore executable; each export has a 90-second timeout, configurable with `--timeout`. Logs and a manifest remain available after failure. The script never opens or changes the owner's music, replaces an existing output directory, or quits an existing MuseScore window.

The source contains two single-staff parts, **Solo** and **Accompaniment**, in constant 4/4 at quarter note = 60. The solo has eight full resting measures, then a half rest and eighth rest before a dotted-quarter C5 on the and of beat 3 in measure 9. The accompaniment plays quarter notes throughout all nine measures. Cue quarter is 34; entrance quarter is 34.5. All content is synthetic.

Exports are generated from one native snapshot: `long-rest.mscz`, `long-rest.mid`, `long-rest.wav`, and `long-rest.musicxml`. Input SHA-256 hashes are checked after every export. `manifest.json` records output hashes and sizes. The native file stays unchanged while MIDI, WAV, and MusicXML are exported. Generated native files can include MuseScore metadata, so their byte hashes need not reproduce across runs even though source XML and musical content do.

For a trial, load the matching MIDI/WAV/MusicXML exports in Virtual Conductor, select **Solo**, and set the full-rest threshold to 8. Count 1/8 through 8/8; measure 9's initial silence must keep 8/8 rather than 9/8. The entrance cue begins on beat 3, half a beat before the solo enters. Preparatory measures must not count toward the eight rests. With quarter note = 60, each full measure lasts four seconds; the cue begins 34 seconds after the score starts, independent of the preparatory offset.

Look away for two measures, look back, and try to recover your place from the counter. Repeat in clean/full-screen mode. Judge readability and cue prominence while holding your instrument; this trial is owner UAT, not evidence that instrument-playing readability has already been established.

## Executed generation check

On 2026-10-30, the installed MuseScore executable at `/Applications/MuseScore 4.app/Contents/MacOS/mscore` successfully generated all four exports in `/tmp/vc-long-rest-fixture-agent`. The MIDI was 433 bytes, exported MusicXML 18,448 bytes, and WAV 13,759,246 bytes (stereo, 44.1 kHz, 39 seconds including render tail). Source and native SHA-256 checks stayed unchanged. The final script revision repeated all exports at `/tmp/vc-long-rest-fixture-final`, also verifying MIDI header and readable nonempty WAV. Source-only generation, refusal to overwrite an existing directory, and a failed-export manifest were checked separately. Structural assertions verified deterministic source XML, nine complete measures in each part, eight solo resting measures, the 34.5-quarter solo onset, and 36 accompaniment attacks.

This verifies generation and export integrity. It does not claim the app's displayed state, audible device output, or soloist readability; those require the integrated app checks and owner trial.
