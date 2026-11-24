# Virtual Conductor

Native offline macOS rehearsal app built with SwiftUI, AppKit, AVAudioEngine and Core Audio. Requires macOS 27.2 or later, macOS SDK 27.0 or later, and Swift 6.4 or later (validated with Xcode 27.1). The core library uses Swift 6 concurrency checking; the app remains in Swift 5 mode pending migration of audio-buffer transfers.

The compiler deployment target is 27.0, the highest accepted by the installed SDK; the app bundle and executable enforce the supported macOS 27.2 runtime minimum. Use the build script to validate the host and SDK minimums.

Follow a MIDI tempo map with a traced conducting pattern while playing a matching WAV accompaniment. Follow written cadenzas by microphone or cue improvised cadenzas with a right-arrow pedal. Record and review a solo interpretation, then export its WAV and approved tempo CSV.

## Build and launch

```sh
Scripts/build-virtual-conductor.sh
open '.build/virtual-conductor/Virtual Conductor.app'
```

For the integrated **play → listen → keep** workflow, choose **MuseScore rehearsal…**. See [MuseScore setup and testing status](docs/musescore-rehearsal.md). The first version automates preparation, renders your timing for listening, and applies kept timing to the open MuseScore score with Undo.

Use **Load new exports…** to select a matching MIDI/WAV pair and optional matching MusicXML for live following and long-rest cues. Both features use the same solo staff, which you can select in the main window or save in **Live following…**. Choose a positive full-measure threshold for long rests. Re-export in MuseScore and use **Reread exports** after changes. The app reopens the last successfully loaded exports at launch if they are still available, without starting playback or recording. Completed takes and timing edits save automatically on this Mac, with a history for each exact score. Manual export loading never alters those files. Choose **Keep it** to apply a recorded interpretation to the open score. Prepare again after relaunch to reestablish the link.

For explicit measure-and-beat changes that preserve written directions and check export freshness, see [Edit MuseScore playback tempos](docs/musescore-playback-tempo.md).

Space plays/pauses, H toggles a compact view with playback, Reset, and Start at measure, and Right Arrow resumes from a configured cadenza wait. Text entry and modal utilities block performance shortcuts. The app remembers explicitly selected output and microphone devices without changing system defaults. If a selected device is unavailable, reconnect or choose another in the app. Recording uses a separate input engine without monitoring; microphone permission is requested when enabling input.

To restart a passage, use **Start at measure → Go → Start**. Preparation plays the
preceding measures: start 72 with two preparation measures plays 70 and 71, then
continues into 72. The display and clicks follow those measures' tempo map. Only
the upbeat and any preparation before measure 1 are silent. Pause/Resume continues
from the paused position; Reset returns to the chosen start with preparation again.
See [starting at a measure](docs/start-at-measure.md).

Pedal passage settings are stored in `~/Library/Application Support/VirtualConductor/cadenzas-v1.json`, keyed by exact MIDI SHA-256. Browser settings can be imported explicitly through the versioned JSON bridge. Changed MIDI does not inherit old boundaries. Native cadenza boundaries accept subdivisions such as beat 1.5. The orchestra’s release can ring briefly after the boundary while the cadenza indicator waits for the pedal; see [cadenza handoff behavior](docs/cadenza-rubato-handoff.md).

## Recorded-performance timing

To prepare accompaniment that follows an existing performer's recording, use
the [recorded-performance tempo transfer process](docs/performance-tempo-transfer.md).
It creates a separate timed MuseScore score, horn-free accompaniment, and matching
exports for this app, with a local listening review and correctable landmarks.
WAV and matching MusicXML are the tested inputs; live following can remain off.

## Live soloist following

Load matching MusicXML with the MIDI and accompaniment WAV, then choose **Live following…**. Select the solo staff and microphone, enable following, and add any explicit wait points by measure and beat. Use **Check microphone** and play one steady note to confirm the selected input hears its concert pitch. The dialog also shows the expected concert pitch for each wait point. Save and start playback using headphones. The tempo tolerance defaults to ±10% and is configurable globally.

To change the default pace, open **Practice tempo…** beside **Start at measure**, enter a measure, beat and quarter-note BPM, and choose **Set tempo**. After pausing, **Use rehearsal start** targets the start of the passage and **Use last followed tempo** copies the most recent pace the orchestra confidently followed in this session. Each saved marking applies from that beat to the next tempo marking or the end. A local marking at the same beat takes precedence. Remove it in the same editor to hear the underlying tempo again.

The **Tempo map** in **Practice tempo…** shows the planned BPM for the whole piece. Click the line or a row to inspect a change by measure and beat. Orange diamonds mark local practice settings. The scrollable list includes the steps of gradual tempo changes. Selecting a location fills the editor. Choose **Set tempo** to save an edit.

Choose **Delete** on a tempo-map row to carry the preceding tempo until the next surviving change. For a gradual change, the arrow beside **Delete** also offers **Delete this entry and following tempo steps**, stopping before the next marking. Deletions save immediately for this rehearsal export. **Undo** reverses edits made while this editor is open, and **Restore deleted score entries** brings back the imported changes later. The opening beat always needs a tempo and can be edited directly.

Markings are saved on this Mac for the matching MIDI export. When a replacement export of the most recent rehearsal opens at score tempo, the Ready message tells you if the previous export had practice tempo edits. The conductor, clicks and accompaniment share the new pace, and live following applies its tolerance around it. Preparation that plays earlier measures uses the tempos in those measures. With matching MusicXML, the editor uses explicit score tempo marks and recognized tempo directions aligned with MIDI events. MIDI-only rehearsals use the exported tempo events, which can include individual steps in a gradual tempo change.

When MuseScore renders a written caesura as an extra bar of MIDI playback time, the conductor holds at the pause and resumes on the written beat. Practice starts, clicks, and following use the printed measure numbers. The importer checks the note positions again after accounting for the pause.

**Follow written cadenzas** is the default in Live following. For Strauss’s Second Horn Concerto, select **Corno Solo in Mib** and your microphone. The score supplies the orchestral release at measure 7, beat 1½ and the shared entrance at measure 13, beat 1. Play the written horn line with your own rubato and pauses. The orchestra listens for the return attack and resumes at the planned tempo. Use **Cue return** or **Right Arrow** for a manual entrance if tracking is uncertain.

**Live following → Free passages** lists the detected ranges. The app reads “Cadenza” or “Kadenz” directions during an orchestral rest. For an unlabelled passage it looks for at least two complete bars of orchestral silence containing at least three solo attacks, followed by an orchestral entrance. Enter a free passage there to specify other boundaries. If the solo rests at the return, the app counts the written rest at the planned tempo after the last note releases. If the solo holds a note across the return, use Right Arrow to choose the entrance.

For an improvised or personal cadenza, choose **Use pedal passages** in Live following and enter the start and return in **Pedal passages…**. Fixed playback also uses these saved stops. Switching modes preserves the saved beats. In written mode, a saved pedal passage starting in a detected cadenza and ending at its orchestral entrance yields to the score. Other saved pedal stops still apply. Accompanied passages keep moving within the global tempo tolerance. See [tempo confidence](docs/following-tempo-confidence.md).

The performance display distinguishes **Holding tempo**, **Waiting for you**, and **Tracking lost**, including with controls hidden. During accompanied playing, a mint **Holding tempo** means the app has recently matched a note and is keeping the current pace. A yellow **Holding tempo** means it is listening for the next matching note. **Tracking lost** appears in red. After preparation or a long written solo rest, the follower gives you 1.5 seconds from the entrance to establish a match. Small timing differences receive gentle position correction, separately limited from the established phrase tempo; see [natural following and rehearsal checks](docs/natural-following-recovery.md). Following needs a monophonic pitched solo staff and the existing linear 4/4 MusicXML mapping. Notes are interpreted in concert pitch, including MusicXML transposition. Waits must land on note attacks; rests and tied continuations cannot supply an entrance pitch.

Settings are stored in app preferences for the exact MIDI/MusicXML export pair; changed exports require checking and configuring following again. Bounded local problem reports save automatically. For hands-free passage review, set **Save following reports at measures** in **Live following…** to capture the preceding excerpt at each selected measure. Microphone audio is included only if **Include recent audio in diagnostics** is enabled before playing; nothing is uploaded. See [behavior, tests, and current limitations](docs/soloist-following.md), particularly recognition latency and real-instrument testing.

## Interpretation review

Choose a passage of up to 128 quarter beats, enable input and record up to 120 seconds. Analyze a monophonic solo part or set manual timing endpoints, review/edit each beat, and approve before exporting CSV. Edits revoke approval. Repeated pitches, sustained notes and rests can make alignment ambiguous. Live following and interpretation share sample-timed pitch/articulation analysis; see [beat detection checks and limits](docs/beat-detection-validation.md). MuseScore remains the editable master. Connected rehearsals can preview and keep timing directly; the CSV workflow remains available for manually loaded exports.

Read [rehearsal recovery and review](docs/rehearsal-recovery-and-review.md) for
saved-take history, detected-beat click playback, timing-source labels, and local
following diagnostics with optional audio and a reproducible replay command.

## Checks

```sh
swift build --product VirtualConductor -Xswiftc -warnings-as-errors
swift test
```

All bundled MIDI fixtures are generated synthetic material. Tests need no score exports, recordings, original project checkout or network. The opt-in device check requires existing microphone authorization and briefly meters input without retaining raw samples:

```sh
VC_DEVICE_CHECK=1 swift test --filter DeviceBindingTests
```

Golden fixtures originate from the prior browser implementation, independently of the Swift port. To regenerate them, pass a checkout containing `Sources/VirtualConductorPrototype`:

```sh
node Scripts/generate-conductor-fixtures.mjs /path/to/browser-project
```

## Repository scope

This repository contains the native application, tests, generated synthetic fixtures and build tooling. User music, takes, exports, settings, signing credentials and build artifacts are excluded. The original browser and accompaniment-practice applications remain in their separate project.

The local build is ad-hoc signed. Distribution signing/notarization and an open-source license will be chosen before public release. No third-party music assets are distributed here.
