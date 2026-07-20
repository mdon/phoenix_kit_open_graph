# PR #1 follow-up

Triage of [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md) (the initial-module review),
folded into the 2026-07-20 quality sweep (this module's first).

## Fixed (pre-existing — verified present in the tree)

- ~~BUG-CRITICAL `/new` editor leaks an orphaned template row on every fresh
  load~~ — verified: `editor_live.ex` `load_or_create_template/3` only calls
  `Templates.create/1` under `connected?(socket)`; the disconnected pass gets
  an in-memory `%Template{}` stand-in. Now pinned by a test (see Batch 1).
- ~~BUG-HIGH hardcoded `http://localhost:4000` in `render/svg.ex`~~ — verified:
  a host-relative href resolves to `""` (unresolved), no `localhost` literal
  remains; the review's `svg_test.exs` case pins it.

## Fixed (Batch 1 — 2026-07-20, this sweep)

- ~~IMPROVEMENT-MEDIUM `Assignments.set/5` raises on a concurrent double-save~~
  — the deferred fix is done: `Assignment.changeset/2` now declares the two
  V152 partial-index `unique_constraint`s, so a race returns `{:error, changeset}`
  (routed to a flash by `AssignmentsLive.do_save`'s existing changeset branch)
  instead of raising `Ecto.ConstraintError`.

## Skipped (with rationale)

- **NITPICK: `TemplatesLive`/`AssignmentsLive` read the DB directly in `mount/3`**
  (doubled on the disconnected+connected pass) — left as-is per the review's
  own reasoning: small admin-only tables, no data-integrity consequence (unlike
  the `:new` editor mutation which WAS fixed), and guarding every read assign
  with `connected?/1` touches both full `mount/3` bodies for a cosmetic gain.
  Surfaced here rather than silently carried.

## Verification

- The two applied fixes re-verified present by grep + the sweep's test run.
- Full sweep gate: 84 tests / 0 failures, 5×/5 stable; `mix format` clean;
  `mix compile --warnings-as-errors` clean; `mix credo --strict` unchanged from
  the pre-sweep standing baseline (7 refactoring + 16 design suggestions —
  a repo condition, not a regression); `mix dialyzer`'s 9 pre-existing warnings
  unchanged.

## Open

None.
