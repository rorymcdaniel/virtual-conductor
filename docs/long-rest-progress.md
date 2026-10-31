# Long Rest Cues progress

## Authority and delivery

Source: `/Users/rory/.codex/handoffs/virtual-conductor/` HANDOFF.md, document.mdx, tasks.json and decisions.json (read 2026-10-30). The answered decision requires a counter throughout qualifying rests. Cancelled decisions remain closed. Constant 4/4, single selected staff, containing-beat cue; no following, pickups or repeat expansion. Owner performs final UAT. Draft PR delivery only; no merges, auto-merge or ready-for-review changes. No Chopin execution APIs.

## Recovery

Fetched origin. Main and origin/main: `bac300f6c940bb2ad5def48eebf2753afb98fcc6`. Main is clean and preserved.

- Export: `0b3fe56e8cbfaa64dde6db498f3e1b06b1a54c2a`, draft PR #2.
- Reader: `88d78d5298da6f2c1203c32ff2fde9c5ae347fcb`, draft PR #3.
- Retained integration: `51181b704559b6e00a90239f6164147ccb6dbe22`, contains both slices.
- Recovered schedule: `228157f8a19d8b9693909baa1061b4abb57be3a5`, already committed and pushed; reused intact, including 13 tests and synthetic fixtures.
- New local integration: `970150c16bd70b7a1e8507f9c0734d7bbe31c82d` merges schedule into retained integration, retaining original ancestry.

Inspected all three retained run checkouts (b8daddcd, 133185a4, 72b0adc7), all local/remote branches, and the vc-tempo-proof worktree. No uncommitted source/setup/display work survived. Untracked .atomic recovery/todo records remain untouched in retained checkouts. Historical approvals and tests are prior evidence, not newly executed checks. The obsolete merge authorization in a todo is superseded by the exported handoff.

## Current work

Integration branch `codex/long-rest-cues`, isolated checkout `/Users/rory/Code/virtual-conductor-long-rest`.

- Export/reader/schedule: recovered; independent musical and technical reviews passed (`ready: true`).
- Setup: implemented at `b569a16bd5cd49c6d841456d1dd087400a6191a2`, repaired at `e88f9c0`, independently approved.
- Display: implemented at `c4f4035`, independently approved and exercised in the native app.
- Final musical/code reviews followed by independent integration verification: all `ready: true` on source `10230a18c6bf6bfe7338a071bd77fe2ede018fe1`.
- Full recovered `swift test`: 60 tests, 1 existing opt-in device skip, zero failures (2026-10-30).

## Verification and limitations

Technical reviews, final checks, actual MuseScore export and native playback completed. Native file-dialog confirmation remains unverified under automation; verified direct-file loading is available. Owner instrument-playing readability and physical audio-device UAT remain pending. Draft delivery is recorded below.

## Recovered slice review evidence

Reviewed base `bac300f6c940bb2ad5def48eebf2753afb98fcc6` and candidate `970150c16bd70b7a1e8507f9c0734d7bbe31c82d`.

- `vc-musical-reviewer`: parser and schedule `ready: true`; 28 targeted tests passed in independent `/tmp/vc-musical-review-build`. Verified selected-staff voice union, sustained notes, threshold boundaries, eight-measure denominator, quarter-34 cue/34.5 entrance, and trailing rests.
- `vc-code-reviewer`: export, parser and schedule each `ready: true`; 37 targeted tests and `git diff --check` passed in independent `/tmp/vc-review-recovered-build`. No actionable defects; reviewed matching bundle propagation and atomic replacement failure paths.
- Coordinator: complete recovered suite passed 60 tests (one opt-in device skip). Log `/tmp/vc-recovered-tests.log`.
- Native export initial attempt: MuseScore CLI exited 40 before output from an initial synthetic fixture; only startup message logged. This is not export validation. Fixture implementer investigating bounded exports independently without closing the owner's MuseScore.

These approvals do not cover forthcoming setup/display, native app UI, or final integration.

## Setup and native fixture

- Setup `b569a16bd5cd49c6d841456d1dd087400a6191a2`: eight targeted tests passed; full suite 68 tests, one opt-in device skip; warnings-as-errors app build passed. Staff selection, threshold, bare imports, unsupported mapping, replacement, stale results and Keep covered.
- Actual MuseScore mapping probe exposed final MIDI quarter 35.95 versus MusicXML 36. Last solo attack 34.5/off 35.9229167; final accompaniment off 35.9479167 at 480 PPQN. Mapping accepts articulated final-measure tails, requires bidirectional attack compatibility, and rejects extra/missing whole measures. Native probe then verified 2 staves, 8 full rests, cue 34 and entrance 34.5. Temporary probe removed; regression retained in setup tests.
- Synthetic fixture tooling committed at `1349bc9505e7563eb5622f2bc383cb9e6b35efe8`. Two successful actual MuseScore export runs; final bundle `/tmp/vc-long-rest-fixture-final/long-rest.{mscz,mid,wav,musicxml}`. Source/native hashes unchanged; WAV readable stereo 44.1 kHz with render tail. See `docs/long-rest-fixture.md`.
- Native accessibility and screenshot tools now work. Owner's existing unsaved MuseScore score was observed only; it was not changed or closed. Native Virtual Conductor playback remains pending.

## Setup review repair and display

Both independent setup reviews returned `ready: false` for base `1349bc9505e7563eb5622f2bc383cb9e6b35efe8` to `b569a16bd5cd49c6d841456d1dd087400a6191a2`: an unrelated MIDI sustain could validate a missing solo attack. Musical reviewer removed the Solo track from the real fixture and reproduced the false acceptance. Coordinator removed the unproven continuation exception and added a sustaining-accompaniment/missing-entrance regression; nine setup tests passed (`/tmp/vc-mapping-repair.log`). Cross-staff ties lacking matching attack evidence now conservatively disable mapping rather than guessing. Final re-review pending.

Display committed `c4f403573584478ad419d7e991c65d606c4a1d80`: six targeted display tests, full suite 74 tests/one device skip, warnings-as-errors build passed before mapping repair. Uses transport snapshot/current tempo map, no independent clock; counter ends at entrance, beat-wide cue remains visible for on-beat entrances, paused/interrupted counter freezes and cue clears, cadenza wait clears overlay. Final native verification pending.

## Final reviews and native import investigation

Final musical and code reviewers independently approved `e88f9c0735a5f8bb7d2646dae8dee9b37aae5122` (setup/display/final each `ready: true`) after the mapping repair; each ran 75 tests, zero failures, one optional device skip. Independent actual-export probe accepted the real bundle and verified musical positions. Subsequent picker-only deltas also received delta reviews, but native testing did not establish them as fixes.

Native CUA reproduced a file-dialog confirmation stall: valid generated MIDI selected, confirmation disabled or becoming disabled without a validation/completion callback. The original type filter, no filter, and asynchronous panel presentation all reproduced it. Instrumentation established readable file, correct public.midi-audio type, canChooseFiles=true, actual selected URL, active/key visible panel with normal frame; it did not establish a source-code cause. Speculative filter/presentation changes are being reverted; temporary DEBUG-vcpanel instrumentation removed. This remains an unverified native dialog path, not a claimed repaired defect. Existing direct MIDI/WAV command-line loading is being extended with optional matching MusicXML for usable playback verification and owner trial.

Independent integration verifier checked `428e359f5aa1665455677adfec00e14812698cc0`: 75 tests with warnings-as-errors, one device skip, zero failures; product build and diff check passed. Production core/setup/display probe verified actual fixture, counters, partial ninth measure, cue/entrance boundaries, threshold/staff changes, prep/transport state suppression and missing-solo MIDI rejection; all manifest hashes matched. Native picker/playback was explicitly outside this verifier's executed scope. Final source delta must be reviewed and verified again before delivery.

## Final technical acceptance

Tested source candidate: `10230a18c6bf6bfe7338a071bd77fe2ede018fe1`; baseline `bac300f6c940bb2ad5def48eebf2753afb98fcc6`.

- Final code reviewer: setup, display, integrated code `ready: true`; reviewed all source on e88, then verified only final delta is optional third MusicXML launch argument, with original picker restored. No open findings.
- Final musical reviewer: setup, display, final musical review `ready: true`; same final delta reviewed, no musical impact. Native fixture probe verified eight full rests, q34 cue/q34.5 entrance and rejected missing solo attack.
- Independent integration verifier after reviews: `ready: true`; exact final-source `swift test --scratch-path /tmp/vc-final-independent-build -Xswiftc -warnings-as-errors`: 75 tests, one opt-in device skip, zero failures. Exact product warnings-as-errors build, diff check, recompiled actual-export probe and all manifest hashes passed. Logs `/tmp/vc-final-independent-tests-10230a1.log`, `/tmp/vc-final-independent-app-build-10230a1.log`, `/tmp/vc-independent-probe-10230a1.log`.
- Coordinator release bundle built and ad-hoc signed using `Scripts/build-virtual-conductor.sh`. App `/Users/rory/Code/virtual-conductor-long-rest/.build/virtual-conductor/Virtual Conductor.app`. Matching fixture `/tmp/vc-long-rest-fixture-final`.
- Native app launched through MIDI/WAV/MusicXML arguments, explicitly selected Solo and threshold8. Observed preparation without count; screenshots at count1/8,4/8,8/8, measure9 Beat3 cue and cue cleared. Clean-mode pause froze2/8; full-screen counter/center measure/conductor visible separately; resume and reset/replay exercised. Screenshots are in the Codex session. Exact cue/entrance boundary correctness comes from automated probes, not screenshot wall-time labels.
- No new native companion Keep mutation, audible-quality, microphone, real-score or soloist-readability claim. File-dialog confirmation stalled under CUA; diagnosis did not establish source cause, so original picker retained. Direct-file route is usable. No owner music or recordings changed.
- Owner trial and launch command are in `docs/musescore-rehearsal.md`; fixture generation in `docs/long-rest-fixture.md`.

Delivery preserves draft PR #2 and #3 and all recovered implementation ancestry. Main remains at the baseline. No PR merge, auto-merge, ready-for-review change or Chopin lifecycle action is authorized or performed.
