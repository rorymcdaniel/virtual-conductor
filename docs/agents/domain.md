# Domain docs

## Before exploring

Read the root `CONTEXT.md` and any ADRs in `docs/adr/` relevant to
the area being explored.

If these files do not exist, proceed silently. The domain-modeling
skill creates them lazily as terms and decisions are resolved.

## Layout

This repository uses a single-context layout:

- `CONTEXT.md`: domain terminology and glossary.
- `docs/adr/`: architecture decision records.

## Vocabulary

Use the terms defined in `CONTEXT.md` in issue titles, proposals,
hypotheses, and test names. If a needed concept is missing, reconsider
the term or note the gap for domain modeling.

## ADR conflicts

Explicitly flag any proposal that contradicts an existing ADR.
Identify the ADR and explain why its decision should be reconsidered.
