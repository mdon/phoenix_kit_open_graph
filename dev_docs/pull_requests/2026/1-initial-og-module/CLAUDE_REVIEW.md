# Claude review — PR #1 (initial phoenix_kit_og plugin)

Reviewed against `elixir:phoenix-thinking` and `elixir:ecto-thinking`. Read every
file under `lib/` (≈4,500 LOC across 22 modules) plus the existing test suite.
Two fixes applied and covered by a regression test; three findings documented
below but deliberately not fixed (rationale inline).

## BUG - CRITICAL: `/new` template editor leaks an orphaned row on every fresh page load

**File**: `lib/phoenix_kit_og/web/editor_live.ex` (`mount/3` → `load_or_create_template/2`, pre-fix)

LiveView `mount/3` runs twice for any full/fresh page load — once for the
disconnected (static HTML) render, once for the connected (WebSocket) render —
per the Phoenix "Iron Law" (`elixir:phoenix-thinking`: *no side-effecting work
in mount without a `connected?/1` guard*). `load_or_create_template(_params,
:new)` called `Templates.create/1` unconditionally in both passes, so:

- Typing `/admin/open-graph/new` directly, refreshing that URL, opening it in
  a new tab, or any prefetch/crawler hit → **two** blank `Template` rows
  inserted, one of which (from the disconnected render) is immediately
  orphaned — nobody ever sees or edits it, and it sits in the templates table
  forever.
- The in-app "New template" button (`push_navigate` from an already-connected
  `TemplatesLive`) does *not* trigger this — that flow only mounts once,
  connected — so the bug is easy to miss in normal click-through testing but
  fires on any fresh-load entry to the route.

**Fix applied**: `load_or_create_template/3` now takes the `socket` and only
calls `Templates.create/1` when `connected?(socket)` is true; the disconnected
pass gets an in-memory, non-persisted `%Template{canvas: Canvas.blank()}`
stand-in so the static render still has something to show.

**Not covered by an automated test** — this repo has no LiveView test harness
yet (`AGENTS.md` TODOs call out a shared `LiveCase` + `Test.Endpoint` as
blocked/future work, matching the project's own testing stance). Verifying
this fix end-to-end requires that harness; flagging here so it's on record
rather than silently assumed-tested.

## BUG - HIGH: OG images silently broken in every real deployment (hardcoded `localhost:4000`)

**File**: `lib/phoenix_kit_og/render/svg.ex:387` (pre-fix)

```elixir
defp resolve_image_href("/" <> _ = url), do: "http://localhost:4000" <> url
```

`get_public_url_by_uuid/1,2` in `phoenix_kit` core falls back to
`URLSigner.signed_url/3` for local storage (the default storage provider),
which returns a **host-relative** path (`/file/<uuid>/<variant>/<token>`) —
`Manager.public_url/2` for the `:local` provider always returns `nil` per
`deps/phoenix_kit/lib/modules/storage/providers/local.ex:156`. Any image
element whose local file bytes aren't reachable (S3/CDN-backed storage, a
missing local cache, etc.) hits this branch and got a hardcoded
`http://localhost:4000` prefix — correct only on the original author's dev
machine, broken on every staging/production host. Worse, the module's own
comment two lines above notes *"the rasterizer runs locally and can't fetch
remote HTTP URLs"* — so even the intended dev-only shortcut never actually
helped resvg render the image; it only changed a broken relative path into a
differently-broken absolute one.

**Fix applied**: treat a host-relative path as unresolved (return `""`),
matching how every other unresolvable href already degrades (falls back to
the solid background color / skips the image element) instead of guessing at
the deployment's origin.

**Test added**: `test/phoenix_kit_og/render/svg_test.exs` — new case under
"image elements" asserts a `/file/...`-shaped `src` never emits `localhost`
into the SVG and resolves to an empty href like any other unresolved image.

## IMPROVEMENT - MEDIUM: `Assignments.set/5` can raise on a concurrent double-save

**File**: `lib/phoenix_kit_og/assignments.ex:47-66`; `lib/phoenix_kit_og/schemas/assignment.ex`

`set/5` does a `get` then insert-or-update — a classic check-then-act race.
The DB enforces the real invariant via a partial unique index pair (module_key,
scope_type[, scope_uuid]), but `Assignment.changeset/2` never declares a
matching `unique_constraint/3`. If two inserts for the same scope race (e.g.
two admins editing the same assignment, or a network retry racing a first
successful save), the loser's `Repo.insert/1` raises `Ecto.ConstraintError`
instead of returning `{:error, changeset}` — crashing the LiveView process
instead of showing the friendly flash the rest of `do_save/2` is built to
display.

**Not fixed**: the assignments modal already disables its Save button via
`phx-disable-with` for the common single-click case, and reproducing the race
reliably needs either two concurrent admin sessions or DB-level integration
tests — both explicitly out of scope per this repo's current testing stance
(no DB-backed test setup yet, see `AGENTS.md` TODOs). Documenting so it isn't
mistaken for "already covered": the correct fix is a `unique_constraint/3` on
`:scope_uuid` naming the two V139 partial indexes, translated to a flash via
`Errors.message/1`'s existing `Ecto.Changeset` passthrough.

## NITPICK: `TemplatesLive` / `AssignmentsLive` query the DB directly in `mount/3`

**Files**: `lib/phoenix_kit_og/web/templates_live.ex:13-18`,
`lib/phoenix_kit_og/web/assignments_live.ex:35-59,315-321`

Same Iron Law as the CRITICAL finding above, but for *reads* rather than a
mutation: `Templates.list()`, `Assignments.list_for_module/1`, and the
publishing groups lookup all run unconditionally in `mount/3`, so a fresh page
load does each query twice (once per disconnected/connected pass). Low
severity — these are small admin-only tables, and unlike the `:new` editor
bug there's no data-integrity consequence, just a doubled read. Left
undocumented-as-fixed since guarding every assign with `connected?/1` here
would touch both LiveViews' full `mount/3` bodies for a purely cosmetic
efficiency gain; flagging so it's a deliberate call, not an oversight.

## Gate

- `mix test` — 79 tests, 0 failures (was 78 before the added regression test).
- `mix format` — clean.
- `mix compile --warnings-as-errors` — clean.
- `mix credo --strict` — pre-existing 7 refactoring / 16 design suggestions,
  unchanged before/after this review's diff (confirmed via `git stash`); none
  introduced by these fixes. `mix credo --strict` exits non-zero on this
  codebase independent of this PR (bitmask exit status for the Design +
  Refactoring categories) — a standing repo condition, not a regression.
- `mix dialyzer` — 9 pre-existing warnings (2 unreachable guard clauses in
  `assignments.ex`, 1 in `phoenix_kit_og.ex`, 2 unreachable pattern-match
  clauses, 2 `unknown_function` for `phoenix_kit_publishing`'s
  `Posts.list_posts/1` / `Groups.list_groups/1` — real at runtime, guarded via
  `Code.ensure_loaded?/1` + `function_exported?/2`, but invisible to
  Dialyzer's static PLT since that dependency isn't compiled into this repo).
  Confirmed via `git stash` that this exact warning set (line numbers aside)
  already exists on the unmodified code — `mix dialyzer` already exits
  non-zero on `main` independent of this PR. None of the 9 are new; the
  reviewed diff shifted one pre-existing warning's line number
  (`render/svg.ex:411` → `:417`) but didn't add or remove any.
