# Throwaway native tempo proof

Question: can installed MuseScore 4.7.6 apply native tempo changes inside sustained notes/rests, persist them, and export the intended MIDI timing?

Run from this branch on the development Mac:

```sh
python3 Sources/VirtualConductor/MuseScorePrototype/run.py
```

Uses a synthetic three-bar score, installs a uniquely named temporary extension, exports into a temporary directory, prints results, and removes the extension. Quit MuseScore first for deterministic batch behavior. No user scores are read. Python standard library only.

The numeric element-enum workaround is experimental and checked against the returned native type. Do not promote it into production without resolving the API mismatch. The prototype adds markings; it does not reconcile existing tempo effects or implement a bridge.

Measured verdict (2026-10-29): apply and rollback pass. Saved/reopened MIDI has tempo events at quarter beats 0, 1, 5, 8 with microseconds per quarter 500000, 1000000, 666667, 500000. Notes remain C4 and D4, with one whole-bar rest. CLI undo/redo commands have no effect; those rows deliberately record that limitation.

Interactive proof: install the same extension, enable it in Manage plugins, open synthetic.musicxml, and run PROTOTYPE tempo proof. All four markings appear. One Undo removes all four; one Redo restores all four. Observed in the real application, not inferred from the CLI. The temporary extension was removed after validation.

Still unproven: manual text-edit synchronization, live connection and reconnect, competing tempo effects, repeats, snapshot identity, preview equivalence, and real-score sound fidelity.
