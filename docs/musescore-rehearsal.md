# Rehearse with MuseScore

This feature is integrated into Virtual Conductor and ready for personal testing. The intended loop is **play freely → hear accompaniment → keep it**. There is no need to export MIDI/WAV or edit tempo numbers by hand.

## First use

1. Build with `Scripts/build-virtual-conductor.sh` and open `.build/virtual-conductor/Virtual Conductor.app`.
2. Open and save your native `.mscz` score in MuseScore 4.7.6. Set its accompaniment mix as desired.
3. In Virtual Conductor, choose **MuseScore rehearsal… → Install / update MuseScore companion**.
4. In MuseScore, use **Plugins → Manage plugins → Reload plugins**, enable **Virtual Conductor**, then run it from the Plugins menu. Leave its small connection window open.
5. In Virtual Conductor, choose the saved score and **Prepare rehearsal**. Preparation checks the open score against the saved file and creates matching MIDI, WAV and MusicXML automatically.
6. Choose **Record interpretation…**, choose a passage and microphone, then record without accompaniment. Select the solo part and **Analyze take**, or use manual endpoints if needed.
7. Choose **Hear accompaniment**. Listen to the selected passage rendered with your timing. Beat-table edits are optional. A changed draft requires another preview.
8. Choose **Keep it**. The companion changes the open MuseScore score as one undoable action. The app adopts the preview's MIDI/WAV/MusicXML and retains your take and cadenza settings. Save in MuseScore when ready.

Recording another take or closing the recording window without Keep does not apply the draft to MuseScore. Keep leaves the native score unsaved so normal Save and Undo remain yours. If you edit or undo in MuseScore, save and prepare again to refresh the app.

## Supported first version

- Native scores with a straight 4/4 timeline. Timing can change inside held notes and rests.
- Visible, text-following tempo markings. Existing tempo text in the passage is replaced. The original effective tempo is restored at its end.
- Gradual tempo changes wholly inside the passage are removed. A gradual change crossing a passage boundary is refused rather than altering outside music.
- Requests have IDs and expire; Keep checks that the same score is selected and its musical content matches the prepared revision. It does not retry a failed Keep automatically.
- Export failure retains the prior rehearsal. Preparation and rendering run separate bounded MuseScore processes for MIDI, WAV and MusicXML. A missing or invalid MusicXML export prevents publication of the replacement bundle.

Repeats, jumps, and pickup bars are not yet supported for Keep and produce a specific message. Preparation/playback can still use the saved exports. The main MIDI reader also requires 4/4. These limits are temporary implementation limits, not changes to the intended product behavior.

## Validation and known gaps

Automated checks cover tempo requests, boundary restoration, take retention, native companion request handling, stale-request rejection, replacing prior markings, save/reopen signature stability, agreement between command-line and companion score signatures, and separate synthetic MIDI/WAV exports. The command-line companion check runs the same handler without its persistent window. Run it with MuseScore closed:

```sh
python3 Scripts/check-musescore-link.py
```

Still needs testing with your music and hardware:

- The persistent companion window and its polling behavior during normal rehearsal. Native UI automation was unavailable during the final integration pass (screen-capture service failure); the handler was exercised through MuseScore's command-line runtime instead.
- Actual sound, mixer/solo-mute export behavior, Muse Sounds/VSTs, and alignment between what you played and the preview. The solo part must remain present in MIDI for analysis.
- Manual tempo-text edits, gradual-change fixtures, fermatas, and complex notation. Fermatas may affect timing beyond the tempo map.
- Reconnect, closing score tabs, app restart, and simultaneous MuseScore windows. Use one Virtual Conductor app and one companion connection at a time.

The score signature tracks notes, durations, tempo text, and spanners. It is not a complete document hash: mixer, layout, some articulations and other properties are not represented. After changing those, save and prepare again before preview/Keep. A timeout after Keep may mean MuseScore applied it but the reply was lost; inspect the score before retrying.

The source file is never rewritten by Virtual Conductor. Preview snapshots and export logs are retained under `~/Documents/MuseScore4/VirtualConductor/` for diagnosis. The app has no cache cleanup yet. The companion is installed under `~/Documents/MuseScore4/Plugins/VirtualConductor/`; custom MuseScore plugin directories require moving it there manually. The render helper lives under MuseScore's Application Support extensions directory.

## Long-rest cues

Prepare a rehearsal, then choose **Solo staff** and a positive **Long rest** threshold in full measures. A multi-staff instrument lists its staves separately. Choose the one containing your music; the app does not infer it from a MIDI track. Changing staff or threshold recomputes cues without changing music or audio.

Manual **Load new exports…** also accepts an optional matching uncompressed MusicXML file. All three files must come from the same score snapshot. MIDI/WAV alone continue to play, with a message explaining why long-rest cues are unavailable. Score replacement clears staff selection when its association cannot be established. Keeping an interpretation refreshes cues from the matching preview exports and current tempo map.

Cues support a linear, constant-4/4 score without pickups. Unsupported repeats, jumps, meter changes or unestablished MusicXML-to-MIDI mapping disable cues with a reason. The mapping check is conservative; it may reject playback ornaments or other exports whose note positions differ. Cross-staff tie continuations without a matching MIDI attack are conservatively unavailable. It does not expand repeats or follow the soloist.

A qualifying rest displays a counter from its first full resting measure, even before the threshold has elapsed in playback. Eight full resting measures show **1/8** through **8/8**. If the next entrance is measure 9 beat 3.5, the count stays **8/8** through the partial rest, the entrance cue begins at beat 3, and the count ends at the entrance. There is no ninth full resting measure, earlier preparatory cue or invented entrance after a trailing rest.

### Owner trial

Use the generated synthetic passage described in [Long-rest fixture](long-rest-fixture.md), then try your own supported score. Select the solo staff, set threshold eight, and play with normal preparation. Check the count during all eight full rests. Look away for two or three measures while holding your instrument, then look back and recover your place. In measure 9, check that the cue begins on beat 3 before the and-of-3 entrance. Repeat with controls hidden (H) and in full screen. Try pause/resume and reset/replay.

Judge readability from your normal playing distance, whether the cue attracts attention, and whether its placement obscures the conductor or measure number. Size, placement and prominence remain adjustable. This trial evaluates usability; automated timing checks cannot establish soloist readability.
