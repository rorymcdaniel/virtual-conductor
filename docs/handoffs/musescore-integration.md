Current status: the integration has moved into the app. Follow [setup and testing status](../musescore-rehearsal.md). The owner prefers integrated features ready to try, with unconfirmed behavior documented. The historical proof-gate sequence below is no longer a release prerequisite.

# MuseScore integration: historical handoff

Resumed at the user's request on 2026-10-29. The first native-tempo proof is complete; see the research report's “Installed-runtime proof” section and GitHub issue #1. Historical sections below describe the original pause; use the newer measured findings when they differ. Next work is persistent companion communication and the remaining proof gates.

## Prompt for the next session

Resume the MuseScore integration design and feasibility work in this repository. Read `AGENTS.md`, `docs/agents/domain.md`, and `docs/research/musescore-integration.md` first. Read any CONTEXT.md and relevant ADRs if they now exist. The research report is the authoritative record of the agreed product behavior, primary-source findings, local experiments, and proof gates; do not repeat the product interview or overturn those decisions by treating earlier recommendations as user preferences.

The user's central goal is to spend time playing and practicing, not hours refining accompaniment tempos. The agreed experience is **play freely → listen → keep**. The report's “Agreed product direction” and “Agreed user workflow” sections contain the settled decisions. The final decision, confirmed immediately before pausing, is that keeping a take replaces tempo behavior inside the selected passage, including ritardando/accelerando, while leaving the rest of the piece unchanged. This has now been recorded in the report.

Treat the user as a technically minded product owner. Own engineering choices, implementation, testing, and validation. Ask only material unresolved product questions discovered by evidence. The existing workflow's mandatory beat review is not a requirement to preserve: listening and choosing Keep it is the agreed normal approval path.

## Where we stopped

- Primary-source research and the initial product clarification are complete. The next step is a bounded integration proof against the installed MuseScore runtime, not another general research pass.
- No companion plugin, live bridge, preview workflow, or application integration has been implemented. No feature specification or implementation tickets were created in this conversation.
- No user score was modified. Experiments used a synthetic score. No application code was changed for this work.
- The report distinguishes source-confirmed capabilities from locally tested exports and unproven proposals. Preserve that distinction; a source API is not proof that the installed plugin runtime supports the desired complete workflow.

## Next actions after resuming

1. Inspect the current working tree and recheck installed macOS, SDK, and MuseScore versions. The report records historical observations, not a promise that the environment is unchanged. The user permits targeting the installed OS/SDK and newer only, with macOS as the sole platform. `docs/research/macos-26-2-upgrade.md` is separate related research; its existence does not mean an OS upgrade happened.
2. Read the prototype skill and build a disposable integration proof following its isolation/preservation conventions. Start with visible editable native tempo changes, including a beat inside a sustained note/rest, one Undo/Redo operation, save/reopen, and correct MIDI playback tempo. Do not experiment on the user's working score.
3. Prove the companion's installed-runtime communication and lifecycle. A one-action command inside MuseScore is a possible interim fallback, not proof that the final novice-friendly workflow is complete.
4. Follow the report's remaining proof gates: existing tempo effects and boundary restoration, repeat traversal, snapshot identity, export fidelity, and retaining takes/cadenza settings. Prototype listening before Keep it: preview must match the result kept, while discarding a preview leaves the working score unchanged. Select the preview implementation as an engineering decision.
5. Fold measured results into the research. Once the architecture is supported by the proof, use the repository's spec/ticket flow for a multi-session implementation. Read `docs/agents/issue-tracker.md` before ticket access; specs and tickets belong in GitHub Issues. Avoid publishing speculative tickets before the proof resolves the critical unknowns.

## Useful implementation entry points

- `Sources/ConductorCore/Interpretation.swift`: beat alignment, current 4/4 passage coordinates, tempo CSV and passage-end tempo restoration.
- `Sources/ConductorCore/MIDI.swift`: parser currently rejects non-4/4 meter; linear MIDI time alone is not a written-score/repeat map.
- `Sources/VirtualConductor/RecordingModel.swift`: current take/approval lifecycle and CSV export.
- `Sources/VirtualConductor/PerformanceModel.swift`: loading new exports resets recording state; linked refresh must retain the take.
- `Sources/VirtualConductor/CadenzaSettings.swift`: settings currently tied to exact MIDI hash; tempo-only refresh needs deliberate preservation.

These are navigation hints, not a substitute for reading the current code.

## Experiment artifacts and workspace state

Synthetic export inputs/results may still exist at `/tmp/vc-musescore-research`. They are disposable and may disappear; the durable findings are in the research report. Separate native-score MIDI and WAV processes succeeded, whereas multi-output batches crashed. Actual score sound/mixer fidelity and the complete integration remain unverified.

At handoff, branch was `main`, HEAD `0366a1cc5451f171eb4839dde8153c1cf39420fa`. `git status --short` showed untracked `AGENTS.md` and `docs/`, including other work. No commit was made. Preserve those files; do not assume all untracked material belongs to this feature or stage the entire tree blindly. The prior research subagent is finished; the saved report is sufficient to resume without its context.

## Suggested skills

- `ask-matt`: already used to choose research → product clarification → prototype → spec/tickets → implementation. Resume at the prototype stage rather than restarting the interview.
- `prototype`: for the bounded runnable integration proof; read its actual instructions before creating the prototype.
- `research`: only for specific remaining primary-source gaps; its workflow requires a background research agent.
- `domain-modeling`: if new domain terms or consequential decisions need glossary/ADR records; keep implementation detail out of the glossary.
- `to-spec`, `to-tickets`: after the proof, for the multi-session build. Locate their skill files if absent from the catalog.
- `implement`, `tdd`, `code-review`: for subsequent implementation, not as evidence that implementation is already authorized or complete in this paused session.

Read skills from their SKILL.md files using available tools. Only delegate where the user or an applicable skill calls for it. Keep the research's agreed product choices intact and report material technical limitations in terms of their effect on the musician's workflow.
