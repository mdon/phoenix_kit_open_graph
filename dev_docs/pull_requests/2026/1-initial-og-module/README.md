# PR #1: Initial phoenix_kit_og plugin — WYSIWYG OG editor + refine_og seam

**Author**: @mdon
**Reviewer**: Claude (Sonnet 5)
**Status**: Merged
**Commit**: `0c80693..88d6a8c` (merge `88d6a8c`), plus two follow-up direct-to-main
commits not part of a PR: `b147069` (lib upgrade), `5349371` (scaffolding + rename
`PhoenixKitOg` → `PhoenixKitOG`)
**Date**: 2026-07-03

## Goal

Ship the first version of `phoenix_kit_og`: an OpenGraph image template editor
(WYSIWYG SVG canvas) plus a hierarchical assignment system (`post → group →
default`) that binds a template to a scope inside a consumer module. Consumer
modules (starting with `phoenix_kit_publishing`) opt in via `refine_og/4`, which
swaps a rendered PNG into `og[:image]` at page-render time — pass-through on any
failure so a public post page can never crash on OG rendering.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_og.ex` | Module entrypoint — `refine_og/4` seam, `preview_og_image_url/3`, admin tabs, re-exported CRUD delegators |
| `lib/phoenix_kit_og/{templates,assignments}.ex` | CRUD contexts + hierarchy-walk resolution |
| `lib/phoenix_kit_og/canvas.ex` | Pure canvas-JSON helpers (add/move/resize/delete elements, coordinate clamping) |
| `lib/phoenix_kit_og/slots.ex`, `variables.ex` | `{{slot}}` / `[[global]]` scanning + substitution, module-variable registry |
| `lib/phoenix_kit_og/render/{cache,svg,rasterizer,placeholder}.ex` | SVG generation → PNG rasterization (resvg NIF/CLI, rsvg-convert, ImageMagick) → disk cache |
| `lib/phoenix_kit_og/web/{templates_live,assignments_live,editor_live*}.ex` | Admin LiveViews: template list, assignment CRUD + live preview, WYSIWYG editor |
| `lib/phoenix_kit_og/web/image_controller.ex` | Public `GET /og-image/:key` PNG endpoint |
| `lib/phoenix_kit_og/schemas/{template,assignment}.ex` | Ecto schemas backing `phoenix_kit_og_templates` / `_assignments` (migration V139, external to this repo) |

### Schema Changes

```elixir
# phoenix_kit_og_assignments — uniqueness via partial-index pair since
# Postgres treats NULL as distinct:
#   (module_key, scope_type) WHERE scope_uuid IS NULL
#   (module_key, scope_type, scope_uuid) WHERE scope_uuid IS NOT NULL
```

## Implementation Details

- **Hierarchy resolution** (`Assignments.resolve_template_with_mapping/2`) walks
  an ordered `[{scope_type, scope_uuid}]` list, most-specific first; `nil`
  scope_uuid on any non-`"default"` tier is skipped rather than matched.
- **Render pipeline is deterministic** — `Render.Svg.to_binary/2` must produce
  byte-identical output for identical input, since `Render.Cache`'s key hashes
  `(template_uuid, updated_at, canvas, values, module_key)`.
- **Media inlining** — the rasterizer can't fetch remote HTTP, so image `src`
  values (media UUIDs) are resolved to local file bytes and inlined as
  `data:` URLs; only falls back to a public URL string when local bytes aren't
  reachable.
- **Kill switch** — `enabled?/0` gates the seam; any resolution error also
  rescues to a pass-through so `refine_og/4` can never break a page render.

## Testing

- [x] Unit tests for pure logic (canvas ops, slots, SVG generation, cache
      hashing, errors dispatcher, schema changesets) — 79 tests, all passing.
- [ ] LiveView smoke tests — explicitly deferred; see AGENTS.md TODOs (blocked
      on a shared `LiveCase` + `Test.Endpoint`).
- [ ] DB-backed integration tests (Assignments partial-index constraint,
      render cache under Repo pressure) — explicitly deferred, same reason.
- [x] Migration tested on staging — out of scope for this repo (migration
      lives in the host app's `phoenix_kit` core, not here).

## Related

- Review feedback: [CLAUDE_REVIEW.md](./CLAUDE_REVIEW.md)
