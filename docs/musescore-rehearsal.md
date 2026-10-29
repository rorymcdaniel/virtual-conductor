# Rehearse with MuseScore

This feature is integrated into Virtual Conductor and ready for personal testing. The intended loop is **play freely → hear accompaniment → keep it**. There is no need to export MIDI/WAV or edit tempo numbers by hand.

## First use

1. Build with `Scripts/build-virtual-conductor.sh` and open `.build/virtual-conductor/Virtual Conductor.app`.
2. Open and save your native `.mscz` score in MuseScore 4.7.6. Set its accompaniment mix as desired.
3. In Virtual Conductor, choose **MuseScore rehearsal… → Install / update MuseScore companion**.
4. In MuseScore, use **Plugins → Manage plugins → Reload plugins**, enable **Virtual Conductor**, then run it from the Plugins menu. Leave its small connection window open.
5. In Virtual Conductor, choose the saved score and **Prepare rehearsal**. Preparation checks the open score against the saved file and creates matching MIDI and WAV automatically.
6. Choose **Record interpretation…**, choose a passage and microphone, then record without accompaniment. Select the solo part and **Analyze take**, or use manual endpoints if needed.
7. Choose **Hear accompaniment**. Listen to the selected passage rendered with your timing. Beat-table edits are optional. A changed draft requires another preview.
8. Choose **Keep it**. The companion changes the open MuseScore score as one undoable action. The app adopts the preview's MIDI/WAV and retains your take and cadenza settings. Save in MuseScore when ready.

Recording another take or closing the recording window without Keep does not apply the draft to MuseScore. Keep leaves the native score unsaved so normal Save and Undo remain yours. If you edit or undo in MuseScore, save and prepare again to refresh the app.

## Supported first version

- Native scores with a straight 4/4 timeline. Timing can change inside held notes and rests.
- Visible, text-following tempo markings. Existing tempo text in the passage is replaced. The original effective tempo is restored at its end.
- Gradual tempo changes wholly inside the passage are removed. A gradual change crossing a passage boundary is refused rather than altering outside music.
- Requests have IDs and expire; Keep checks that the same score is selected and its musical content matches the prepared revision. It does not retry a failed Keep automatically.
- Export failure retains the prior rehearsal. Preparation and rendering run separate MuseScore processes for MIDI and WAV.

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
