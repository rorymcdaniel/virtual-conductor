# Virtual Conductor

Native offline macOS rehearsal app built with SwiftUI, AppKit, AVAudioEngine and Core Audio. Requires macOS 27.2 or later, macOS SDK 27.0 or later, and Swift 6.4 or later (validated with Xcode 27.1). The core library uses Swift 6 concurrency checking; the app remains in Swift 5 mode pending migration of audio-buffer transfers.

The compiler deployment target is 27.0, the highest accepted by the installed SDK; the app bundle and executable enforce the supported macOS 27.2 runtime minimum. Use the build script to validate the host and SDK minimums.

Follow a MIDI tempo map with a traced conducting pattern while playing a matching WAV accompaniment. Configure cadenza stops and cue prepared returns with a right-arrow pedal. Record and review a solo interpretation, then export its WAV and approved tempo CSV.

## Build and launch

```sh
Scripts/build-virtual-conductor.sh
open '.build/virtual-conductor/Virtual Conductor.app'
```

For the integrated **play → listen → keep** workflow, choose **MuseScore rehearsal…**. See [MuseScore setup and testing status](docs/musescore-rehearsal.md). The first version automates preparation, renders your timing for listening, and applies kept timing to the open MuseScore score with Undo.

Use **Load new exports…** to select a matching MIDI/WAV pair and optional matching MusicXML for live following and long-rest cues. Select one solo staff and a positive full-measure rest threshold. Re-export in MuseScore and use **Reread exports** after changes. Files and takes remain session-scoped. Manual export loading never alters those files. The MuseScore companion changes the open score only when you choose **Keep it**.

Space plays/pauses, H shows/hides controls, and Right Arrow resumes from a configured cadenza wait. Text entry and modal utilities block performance shortcuts. Output selection is app-local. Recording uses a separate input engine without monitoring; microphone permission is requested when enabling input.

Cadenza settings are stored in `~/Library/Application Support/VirtualConductor/cadenzas-v1.json`, keyed by exact MIDI SHA-256. Browser settings can be imported explicitly through the versioned JSON bridge. Changed MIDI does not inherit old boundaries.

## Live soloist following

Load matching MusicXML with the MIDI and accompaniment WAV, then choose **Live following…**. Select the solo staff and microphone, enable following, and add any explicit wait points by measure and beat. The dialog shows the expected concert pitch from MusicXML. Save and start playback using headphones. The tempo tolerance defaults to ±10% and is configurable globally.

Accompanied passages keep moving within that tolerance. Orchestral silence of at least one measure automatically enables free following through the written solo part, including extreme rubato and pauses. Returns use the planned tempo. Existing configured cadenzas take priority. **Right Arrow** releases an explicit wait or cues the return from a freely followed passage. Turning following off retains fixed playback and existing cadenza controls.

The performance display distinguishes **Waiting for you** from **Tracking lost**, including with controls hidden. Following needs a monophonic pitched solo staff and the existing linear 4/4 MusicXML mapping. Notes are interpreted in concert pitch, including MusicXML transposition. Waits must land on note attacks; rests and tied continuations cannot supply an entrance pitch.

Settings are stored in app preferences for the exact MIDI/MusicXML export pair; changed exports require checking and configuring following again. Live microphone samples stay in bounded memory and are not saved or transmitted. See [behavior, tests, and current limitations](docs/soloist-following.md), particularly recognition latency and real-instrument testing.

## Interpretation review

Choose a passage of up to 128 quarter beats, enable input and record up to 120 seconds. Analyze a monophonic solo part or set manual timing endpoints, review/edit each beat, and approve before exporting CSV. Edits revoke approval. Repeated pitches, sustained notes and rests can make alignment ambiguous. MuseScore remains the editable master. Connected rehearsals can preview and keep timing directly; the CSV workflow remains available for manually loaded exports.

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
