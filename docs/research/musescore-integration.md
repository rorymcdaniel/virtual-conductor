# MuseScore integration research

Researched 2026-10-28. Scope: remove manual entry of approved recorded tempo changes first; automate matching MIDI/WAV preparation second. This is a feasibility report and proposed workflow, not a claim that integration has been implemented.

## Baseline and evidence

The installed application is `/Applications/MuseScore 4.app`, version **4.7.6** (read from its `Contents/Info.plist`). `sw_vers` reports **macOS 15.6, build 24G84**. Target these installed versions and newer; no legacy compatibility layer is needed. The exact upstream tag is [v4.7.6](https://github.com/musescore/MuseScore/releases/tag/v4.7.6). Sources below are pinned to that tag wherever possible. The general command-line handbook explicitly warns that it was copied from MuseScore 3, so it is not sufficient evidence for current behavior. [Official CLI handbook](https://musescore.org/en/print/book/export/html/329750).

The parent agent also verified **Xcode 26.2 (17C52), macOS SDK 26.2** with `xcodebuild -version` and `xcrun --show-sdk-version`. The installed runtime floor is macOS 15.6; the SDK version does not imply that macOS 26.2 is installed.

Repository baseline: [README](../../README.md) describes matching MIDI/WAV exports, reviewed/approved interpretation CSV, session-scoped takes and MuseScore as editable master. It explicitly says users currently apply the tempo list and re-export themselves. There is no existing CONTEXT.md or ADR decision to supersede.

## Installed-runtime proof — 2026-10-29

Resumed after the OS upgrade. Local baseline: MuseScore 4.7.6, macOS 27.2, Xcode 27.1. [Evidence and next proof gate](https://github.com/rorymcdaniel/virtual-conductor/issues/1). The reproducible throwaway prototype is preserved on [prototype/musescore-tempo-proof](https://github.com/rorymcdaniel/virtual-conductor/tree/f703353/Sources/VirtualConductor/MuseScorePrototype), outside main.

A generated three-bar score contains C4 whole note, whole-bar rest, and D4 whole note. Native tempo objects inserted at quarter beats 0, 1, 5, 8 persist through native save/reopen. Independently parsed MIDI export reports microseconds per quarter 500000, 1000000, 666667, 500000 at those exact positions (120, 60, approximately 90, 120 BPM). Notes and rests remain unchanged. This validates TimeTick anchors inside sustained notes/rests for this fixture.

`endCmd(true)` rolls back all four markings. In the interactive application, all four markings are visible and grouped under “PROTOTYPE apply tempo”; one Undo removes them all and one Redo restores them all. CLI `cmd("undo")`/`cmd("redo")` did not change the exported score, so the automated rows are not evidence of interactive undo success. The GUI was checked separately with the same extension and synthetic score; the disposable GUI edits were discarded afterward.

A separate export of the edited native score produced a nonzero, stereo 44.1 kHz float32 WAV of 11.5 seconds. The MIDI tempo map spans 8.5 musical seconds; the WAV duration alone does not prove onset alignment or explain the additional tail. Audio fidelity and timing still require measured comparison.

**Runtime API mismatch:** `api.engraving.Element.TEMPO_TEXT` is a string in this installed macros runtime, while `newElement` expects a numeric ID. The prototype used enum ordering plus a returned-native-type guard to investigate feasibility. That is an experimental workaround, not a stable production contract. Resolve the mismatch before adopting a companion implementation. It initially returned a Tuplet under an incorrect offset, demonstrating why output inspection is essential.

No user score was opened or modified. The temporary extension was removed after validation. No application integration, live bridge, or preview/keep workflow has been implemented. Next: prove persistent companion communication and lifecycle, then competing tempo effects, boundary restoration, manual edits, repeats, snapshot identity, export fidelity, and preview equivalence. Only then turn the supported design into implementation tickets.

## Recommendation

Build a small MuseScore companion plugin/extension and a corresponding integration module in Virtual Conductor. The companion changes the **open native score through MuseScore's own editing API**, so layout/instruments/notation remain in MuseScore and the whole application of an interpretation is one undoable operation. Virtual Conductor owns recording, review, approval, score-version matching and automatic export refresh.

The preferred experience is a live local connection, with **Keep it** in Virtual Conductor applying the auditioned interpretation to MuseScore. The fallback, if persistent connections are unsuitable in the installed extension runtime, is one **Apply approved interpretation** action in MuseScore that reads the prepared request. That fallback removes manual tempo entry but falls short of the agreed normal workflow; evaluate it as an interim delivery, not the final usability target. The live connection is a proposal pending the runtime proof described below.

### Agreed product direction — 2026-10-29

The user should spend most of their time playing and practicing, rather than refining accompaniment tempos. The target user is moderately comfortable with modern technology but unfamiliar with MuseScore and audio recording tools. Success means they can record a passage, hear a useful accompaniment result, and keep it without handling exported files, entering tempo numbers, or navigating MuseScore editing tools.

Tempo changes are **visible and manually editable**. This is an accompaniment score, not a printed performance part; understanding and adjusting the tempo changes matters more than engraving appearance. Update the **working score with Undo and recovery**, rather than creating a separate interpreted score for each take.

### Agreed user workflow

1. Open the native score in MuseScore. Connect it to Virtual Conductor once; choose the solo reference and accompaniment mix once for that score.
2. **Prepare rehearsal** creates a coherent source snapshot and generates matching MIDI and WAV automatically. Virtual Conductor opens the pair without file-picker work.
3. **Play a passage freely, without accompaniment**, and record an interpretation. The musician establishes the timing rather than following the existing accompaniment.
4. **Hear the accompaniment follow it**, with an easy way to compare or retry. Detailed beat editing is optional. If analysis is uncertain, identify the specific passage needing attention and offer a simple correction or another take.
5. **Keep it** applies the auditioned interpretation to the working score in one undoable operation and refreshes the accompaniment automatically. Preserve the take and cadenza locations when only tempo changed.

The musical outcome is approved by listening and choosing Keep it; reviewing every beat is not a prerequisite. The current mandatory beat-review/CSV workflow is therefore a baseline to replace, not an acceptance criterion to preserve. Preview must precede committing the working score, and retry/discard must leave the kept interpretation intact. Engineering must validate that the preview represents the result that will be kept.

Unaccompanied recording is confirmed. For the first version, a kept interpretation applies identically on every repeat of the same written bars. Separate tempo interpretations per occurrence are out of scope; existing dynamics remain unchanged. The user's rationale is that repeats may differ in dynamics but rarely need different tempi. Keeping a take replaces existing tempo behavior within the selected passage, including ritardando and accelerando, while leaving the rest of the piece unchanged. These musical behavior decisions are confirmed; engineering owns integration, recovery, mapping and validation.

## What is technically supported

### Apply real tempo objects with undo

The installed-version source exposes `newElement`, `removeElement`, current-score access, and writable `tempo`, `tempoFollowText`, `text` and `visible` properties. It is therefore possible in principle to insert native tempo text and set playback separately from display. `Score.startCmd(name)` locks an undo transaction and `endCmd()` commits it; `endCmd(true)` rolls it back. This directly supports a single **Apply approved interpretation** undo action. [Plugin entry points](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/qmlpluginapi.h), [element properties](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/elements.h), [undo implementation](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/score.cpp).

The core tempo type is beats per second; the `TempoText` default is 2.0, and its relative update uses `BeatsPerSecond`. Map the app's quarter-note BPM to the correct internal units and independently verify with exported MIDI. Disable text-following when explicitly controlling numeric tempo, or use consistent text and numeric values. [TempoText implementation](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/dom/tempotext.cpp). This conversion needs an end-to-end test, particularly when the displayed beat unit is dotted or not a quarter note.

Cursor positioning is more capable than older plugin documentation suggests. `rewindToFraction` supports exact fractional positions and can create a `TimeTickAnchor` if its filter includes `TimeTick`. `Cursor.add` attaches generic elements to the current segment through an undoable add. This is a promising route for an approved beat inside a sustained note or rest without changing musical rhythm. It is **not yet verified** that tempo text on these generated anchors plays and survives save/reopen as intended. Do not silently snap an interpretation beat to a later note. [Cursor implementation](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/cursor.cpp).

### Local communication is plausible, not proven

The exact source contains WebSocket client/server APIs. The client accepts a URL or host/port configuration and defaults to localhost. Registration is conditional on `MUSE_MODULE_NETWORK_WEBSOCKET`; the installed bundle includes only a disabled developer example. These facts establish an integration candidate, not that an enabled persistent plugin can use it in this binary. [Client](https://github.com/musescore/MuseScore/blob/v4.7.6/src/framework/network/api/websocketapi.cpp), [API registration](https://github.com/musescore/MuseScore/blob/v4.7.6/src/framework/network/networkmodule.cpp), [bundled example](https://github.com/musescore/MuseScore/blob/v4.7.6/share/plugins/dev_test_websocket/dev_test_websocket.qml_disabled).

If available, have the companion connect to a Virtual Conductor server bound to loopback. Do not use the MuseScore server helper blindly: it listens on `QHostAddress::Any`. Add per-session pairing and request IDs so reconnect/retry cannot duplicate a tempo application. Keep the companion alive explicitly and test disconnect, score-tab switching and undo/redo. [Server implementation](https://github.com/musescore/MuseScore/blob/v4.7.6/src/framework/network/api/websocketserverapi.cpp).

An explicit companion action reading a local request is the lower-complexity fallback. Installation/activation and file-access capabilities still need an actual installed-runtime probe. AppleScript/UI click automation and direct rewriting of native files are not recommended first approaches: neither gives the documented score-edit transaction above, and external file changes introduce conflicts with the score already open in MuseScore.

### Automatic export works in a constrained local probe

The parent agent ran synthetic tests against the installed executable in `/tmp/vc-musescore-research` during this research. These are local empirical results, not upstream guarantees:

| Probe | Result |
| --- | --- |
| Native MSCZ to MIDI, separate direct process | Exit 0; MIDI produced |
| Native MSCZ to WAV, separate direct process | Exit 0; nonzero audio, stereo 44.1 kHz, 32-bit PCM, 220500 frames / 5 seconds |
| Native MSCZ batch job exporting MIDI then WAV | MIDI produced, then segmentation fault (exit 139) during WAV |
| MusicXML batch to MSCZ/MIDI/WAV with MuseScore Basic override | MSCZ/MIDI produced, then segmentation fault during WAV |
| Offscreen Qt mode | Unavailable in the installed bundle, which provides cocoa |

Use **one separate MuseScore process per export format**, sequentially, from the same immutable native score snapshot. Treat partial files, crashes and silence as failed preparation; retain the previous working pair. The observed failure is not proven to be solely a batch bug, but direct per-format exports are the successful measured path. The synthetic test does not verify Muse Sounds/VST fidelity, mixer behavior, repeats or the user's actual score.

Plugin `writeScore()` is another candidate, but it only supports the currently selected score and delegates to the interactive export scenario. Its name does not prove silent native saving or background audio export. Test any such use rather than assume it. [Plugin writeScore implementation](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/qmlpluginapi.cpp), [export helper](https://github.com/musescore/MuseScore/blob/v4.7.6/src/project/internal/engravingpluginapihelper.cpp).

The current installed help supports `--extension`, `--job`, `--sound-profile` and `--unroll-repeats`, but not the old handbook's `-p` plugin option. The installed batch extension example demonstrates `--extension` with a job; this should be explored if a simple action is preferable to a persistent companion. [Batch example](https://github.com/musescore/MuseScore/tree/v4.7.6/share/extensions/batch_example). Historical Muse Sounds CLI export failures were reported and closed upstream; they do not establish a current defect, but justify a real-score sound check. [Upstream issue 19160](https://github.com/musescore/MuseScore/issues/19160).

## Mapping and preservation requirements

These are proposed engineering requirements, informed by the API and current app behavior:

- **Written score position is different from performance position.** Export a score-position map at preparation time. Include rational tick/beat positions, measure identity, pickup handling and traversal occurrence. A displayed measure number alone is insufficient.
- **Repeated bars share one interpretation in version one.** Apply tempo changes to written positions so every occurrence uses the same interpretation; retain repeat notation and existing dynamics. Mapping still needs verification: `Cursor.utick` calls `RepeatList.tick2utick`, whose implementation returns the first matching traversal segment, not a complete map of every occurrence. Verify playback and exported timing across all passes, including the effective tempo when re-entering the passage. Pass-specific tempo editing and unrolling a separate interpreted copy are outside the agreed scope. [Cursor](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/api/v1/cursor.cpp), [repeat mapping](https://github.com/musescore/MuseScore/blob/v4.7.6/src/engraving/dom/repeatlist.cpp).
- **Preserve source identity.** Pair the request with score identity, snapshot hash/revision, passage boundaries and the approved take revision. Check all before editing. Applying again should replace the integration's own prior result, not stack duplicate markings.
- **Make visible markings genuinely editable.** A manual change to an applied marking must affect playback as the user expects; displaying text disconnected from its numeric playback tempo would not meet the agreed goal. Test the chosen text/numeric synchronization behavior and detection of manual edits before replacing an earlier interpretation.
- **Preserve scope.** The kept interpretation replaces existing tempo behavior within the selected passage, including ritardando and accelerando. Resolve competing playback effects there so the accompaniment follows the kept take. Preserve unrelated markings and all behavior outside that passage. Restore the original effective tempo after the selected passage and verify the remainder plays unchanged, including gradual changes crossing the boundary. Fermatas and other timing effects require explicit validation rather than assuming that adding tempo text is sufficient.
- **Preserve the musical document.** Retain notes, rests, articulations, layout, instrumentation, mixer and sound settings. Native editing via the companion is preferable to a MusicXML round-trip or reconstruction from MIDI.
- **Preserve the recording.** The current load/recording reset path must be separated from a linked score's export refresh. A successful refresh must not discard the take that generated it.
- **Preserve cadenza configuration across tempo-only updates.** Current cadenza identity uses the exact MIDI hash. Introduce score-position identity/migration for this path; do not blindly reuse settings if notes or structure changed.
- **Prepare the right two representations.** Ensure the solo reference notes remain available in MIDI while accompaniment WAV uses the desired solo mute/mixer configuration. Validate this experimentally; a matching filename is not evidence of matching performance content.

## Proof gates before promising one-click operation

1. On a disposable score in 4.7.6, apply several tempo objects, including a beat within a long note/rest; verify exported MIDI tempo events and WAV durations, save/reopen persistence, one undo, redo and rollback.
2. Test visible/hidden markings, existing tempo text and gradual changes, and restoration after a selected passage.
3. Prove companion lifecycle and local communication in the installed runtime; otherwise adopt the one-action local request fallback without blocking tempo automation.
4. Run separate MIDI/WAV export on a representative user score with its actual Muse Sounds/VST/mixer settings; compare audible output and timeline against GUI exports. Test a silent passage without treating intentional silence as total-export failure.
5. Prove pickup, meter changes, repeats/endings/jumps, and source-edited-during-recording handling. Verify the same kept interpretation on every occurrence of repeated bars, including re-entry tempo and passage-end restoration, without changing dynamics.
6. Exercise refresh failure/retry, pair publication, undo after refresh and retaining take/cadenza state.
7. Prove the listen-before-keeping loop: preview matches the kept result; retry/discard leaves the working score unchanged; straightforward takes need no beat-table review; uncertain alignment points to an actionable passage rather than requiring routine numerical editing.

The highest-value technical proof is **approved interpretation → native tempo changes with one undo**, followed by automatic re-export/refresh. The user-facing acceptance target is the complete **play → listen → keep** loop; tempo transfer alone does not satisfy it.

## Recommended skill workflow

The invoked ask-matt router recommends research feeding into `grill-with-docs` for product decisions in an existing repository. Keep that discussion about user-visible behavior; engineering owns API selection, mapping, recovery and validation. Use a bounded `prototype` detour for the installed-runtime proof gates above. Once those findings and product choices are settled, use `to-spec` and `to-tickets` for this multi-session feature, then `implement` with its TDD and code-review flow per ticket. This research does not authorize or create a finished implementation specification, GitHub tickets, or application changes. [Ask Matt skill](../../../../.agents/skills/ask-matt/SKILL.md).
