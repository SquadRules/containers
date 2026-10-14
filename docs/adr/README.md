# Architecture Decision Records

This directory holds the [Architecture Decision Records
(ADRs)](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
for the `SquadRules/containers` repository. Each file captures one
architecturally significant decision: the context that motivated it, the
decision taken, and the consequences (trade-offs, follow-ups, constraints it
imposes on later work).

## Naming

Files are numbered sequentially in the order they are created:

```
NNNN-short-title.md
```

where `NNNN` is a zero-padded four-digit sequence number (e.g. `0001`,
`0014`). The title slug uses lowercase words separated by hyphens.

## Statuses

Each ADR carries a status in its header:

| Status       | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `proposed`   | Draft; not yet agreed.                                                  |
| `accepted`   | Agreed and implemented (or implementation in progress).                 |
| `deprecated` | Superseded by a later ADR; kept for the audit trail with a link forward.|
| `rejected`   | Considered and not taken; kept with the reason.                         |

When an ADR is superseded, its status is changed to `deprecated` and a
`Superseded by:` line is added pointing at the replacement. The replacement
records the supersession in its own header (`Supersedes:`).

## Proposing a new ADR

1. Copy the template at the bottom of this file into a new numbered file.
2. Fill in the header (title, date, status `proposed`) and the three sections.
3. Open a pull request — the ADR review is part of the PR review.
4. On merge, change the status to `accepted`.

## Modifying an existing ADR

An ADR is a point-in-time record. If the decision changes, write a new ADR
that supersedes the old one and mark the old one `deprecated`. If only the
context or consequences have evolved (the decision itself has not), append a
dated "Amendments" section at the bottom of the existing ADR rather than
rewriting the body.

## Template

```markdown
# NNNN — Title

- **Date:** YYYY-MM-DD
- **Status:** proposed | accepted | deprecated | rejected
- **Deciders:** <who was involved, e.g. @alice, @bob>

## Context

What is the issue or situation that motivates this decision? What forces are
at play? What constraints exist?

## Decision

What is the change that we're proposing and/or doing?

## Consequences

What becomes easier or more difficult to do because of this change? What
trade-offs were accepted? What follow-up work is expected?
```
