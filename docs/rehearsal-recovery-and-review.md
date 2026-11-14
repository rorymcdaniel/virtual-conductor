# Rehearsal recovery and review

## Accepted scope

The owner requested all three recommendations, integrated and ready to try:

- Automatically save completed recorded takes and timing edits, associate them
  with their exact score, and restore/select earlier attempts after relaunch or
  score changes. A new take must not overwrite an earlier take. Surface storage
  errors and preserve the in-memory take. Do not delete recordings automatically.
- Save a local, bounded recent live-following diagnostic snapshot with enough
  observations and score context to replay recognition. Audio excerpts are
  optional and require enabling capture before playing. Snapshots remain usable
  after stopping; saving must not alter transport. Include a reproducible replay
  command and test it against generated input.
- Hear detected beats over the original take, with a downbeat accent and click
  level control. Keep original samples unchanged and prevent mixed clipping.
  Distinguish timing at recognized attacks, timing inferred between them,
  estimated final releases, and manual edits. Preserve existing accompaniment
  preview and approval behavior.

## Delivery checks

Verify storage round trips, score isolation, previous-take selection, atomic
metadata updates, failed/corrupt saves, delayed capture ownership, click timing
and level, inferred-beat labels, bounded diagnostic capture, audio opt-in,
replay determinism, and existing live transport behavior. Run the full suite,
review changes, merge a PR, then build and verify the Applications installation.

## Using the features

**Record interpretation** now saves each completed take automatically. **Saved
takes for this score** selects an earlier attempt. Analysis, manual endpoints,
beat edits, and approval are saved with that take. Reopening the same exact MIDI
restores the newest completed take; choosing an earlier attempt keeps its own
edits. **Show files** reveals the local library; **Export WAV** remains the way
to get a conventional audio file. A kept interpretation carries the current
take into the newly timed score's library as well. Earlier score versions keep
their own histories. Saving a new take never overwrites an earlier take.

Enable **Hear detected beats over take** and press **Play take** after analysis
or creating a manual draft. The click-level slider controls the overlay, with
higher clicks on downbeats. Changing the option or level stops playback; press
Play take again. The final boundary click can extend playback by 35 ms. The
listening copy is normalized if needed to avoid clipping; original samples are
unchanged. **Adjust beat timing** labels recognized attacks, timing inferred
from the phrase, estimated releases, and manual timing. These labels describe
the source of timing, not calibrated confidence. Manually simplifying a map
marks its timing as manual. Restoring a take requires hearing a fresh accompaniment
preview before **Keep it** becomes available.

**Save following report** on the main window saves recent live-following evidence
without stopping playback. **Show report** reveals it. **Include recent audio in
diagnostics** is off by default; enable it before starting if a recent microphone
excerpt would help. Turning it off clears the in-memory audio excerpt. Reports
contain up to 3,000 recognition decisions (about 30 seconds), up to 200 lifecycle
and interruption notices, and, when enabled, up to 15 seconds of contiguous audio.
An interruption clears the audio excerpt rather than splicing separated moments.
The last report can still be saved after stopping; starting another performance
begins a fresh capture. Nothing is uploaded.

Problem reports now also save automatically after tracking loss, an audio
interruption, three seconds holding for uncertain evidence, or two seconds at a
tempo limit. At most three automatic reports are saved per performance, at least
30 seconds apart. They include up to 3,000 playback commands in addition to the
recognition decisions. **Show report** opens the latest saved report from this
performance. A failed write preserves a frozen snapshot in memory for **Save
following report** to retry, even after starting another performance. That unsaved
snapshot does not survive quitting the app.

The installed app includes a replay tool:

```sh
'/Applications/Virtual Conductor.app/Contents/MacOS/FollowingReplay' '/path/to/Following-UUID/report.json' --audio
```

From the repository, the equivalent commands are:

```sh
swift run FollowingReplay '/path/to/Following-UUID/report.json'
swift run FollowingReplay '/path/to/Following-UUID/report.json' --audio
```

The first command re-evaluates each recognition decision with its captured phrase
context, and each playback command with its captured controller context. It
reports changed matches, tempo estimates, and playback commands. It returns exit code 2
for changed results, 1 for an invalid report, and 0 for identical results. The
optional audio pass runs today's detector over the saved excerpt afresh. This
replays recognition, not full audio transport or physical device latency. A
report includes score notes, tempo context, recognized pitches, input levels,
phase, timing, and interruption reasons; it should be shared only deliberately.

## Storage and practical limits

Data stays under `~/Library/Application Support/VirtualConductor/`: `Takes/v1`
contains lossless Float32 PCM and atomic JSON metadata, and `Diagnostics` contains
saved reports and optional WAV excerpts. Takes and manually saved reports are not
automatically pruned. `Diagnostics/Automatic` retains the newest 12 automatic
reports; copy a report elsewhere or save manually to keep it indefinitely.
Take audio is immutable; only the small metadata file is replaced when
editing. Incomplete/corrupt records are retained and reported. Retry save and WAV
export are available when storage fails. A failed late completion from an earlier
score remains in memory for retry/export. Existing tests use isolated libraries.

Completed takes survive normal quit and relaunch. Recording still in progress,
or a save that has not completed when the process crashes, is not guaranteed to
survive. If storage is unavailable, resolve the visible save warning or export
before quitting. Reports are versioned, with playback-state validation before
replay; they are diagnostic evidence, not an archival interchange standard.

Generated tests cover click positions and final boundaries, amplitude limits,
timing-source labels, multiple takes, relaunch, score isolation, delayed capture
ownership, failed late saves, corrupt metadata/audio, optional bounded audio,
round-trip replay, and invalid replay state. Real-instrument listening and
physical microphone latency remain untested.

## Verification on 2026-11-12

The warnings-as-errors suite passed 124 tests, with one opt-in hardware check
skipped. The focused release suite passed 33 tests. The saved-report command
replayed 3,000 decisions with zero changed results and re-analyzed 1,497 pitched
frames from a generated audio excerpt. Existing timing/transport tests remain
passing. Both standards and specification reviews cleared after recovery,
corrupt-file handling, and test-isolation fixes.

A native UI smoke check loaded two generated saved takes, selected an earlier
take, edited and saved a beat, started playback with detected beats, and verified
all four timing-source labels. It exposed and fixed a no-op field commit that
incorrectly changed timing provenance. The original rehearsal selection was
restored and only the generated UI-test takes were removed from the app library.
