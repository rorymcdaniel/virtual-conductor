## Collaboration

Treat the user as a technically minded product owner. Focus questions and
grilling on product decisions: user needs, behavior, scope, priorities,
tradeoffs, and acceptance criteria.

Ask only one question at a time and wait for the user's answer before asking
the next. This invariant also applies to skill-led interviews and grilling.

Own engineering decisions and execution, including architecture,
implementation, testing, and technical validation. Resolve routine technical
choices independently, explaining material consequences in product terms.
When the user suggests a technical approach, evaluate it and incorporate it
where appropriate.

Use the Matt Pocock skill workflows to define the product clearly before
implementation and maintain sound software engineering practices throughout.

## Delivery philosophy

This is a personal, noncritical tool used by its owner. Deliver integrated
features ready for the owner to try. Use prototypes when they help engineering,
but carry useful results into the app rather than stopping at a proof.
Document untested behavior and known limitations; incomplete real-world
validation alone is not a reason to withhold a usable feature. Run practical
checks and preserve the owner's music and recordings.

The product should let the owner spend time playing their instrument instead
of operating the tool. Development should let the owner spend time using the
tool instead of managing its construction. Own implementation and follow-through;
ask about product decisions only when necessary.

## Git workflow

The user owns product decisions; agents own engineering, including Git
workflows. Choose direct commits to main, feature branches, or pull requests
according to the change's risk and review needs without routine approval.

Include all pending repository work, including pre-existing changes, after
reviewing it. Split changes into coherent commits by purpose. Preserve work
from other sessions and keep secrets and generated artifacts excluded.

At task completion, commit all intended changes and leave a clean working
tree. Keep main current: fetch the remote, integrate completed work into main,
and push main when ready. Respect branch protection and required checks; if
integration is blocked or a PR remains pending, report that explicitly rather
than claiming main is current. Verify the final branch, working-tree status,
and local/remote synchronization before finishing.

## Agent skills

### Issue tracker

Use GitHub Issues for this repo. Read `docs/agents/issue-tracker.md`
before reading or writing tickets.

### Triage labels

Use the five default triage labels. Read `docs/agents/triage-labels.md`
when triaging issues.

### Domain docs

Use a single-context layout. Read `docs/agents/domain.md` before
exploring the codebase.
