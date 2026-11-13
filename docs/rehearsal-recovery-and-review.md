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
