# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-07-04

### Added
- WYSIWYG SVG canvas editor for OpenGraph image templates — text, image, rect,
  and stamp elements, with `{{slot}}` (consumer-wired) and `[[global]]`
  (site_url, site_host, site_name, page_url, page_locale) variable syntax
- Hierarchical template assignment system (e.g. `post → group → default`);
  admin modal for CRUD plus live preview against a real published resource
- SVG → PNG rendering pipeline (`Render.render_url/2`): prefers the `:resvg`
  NIF, falls back to the `resvg` CLI, `rsvg-convert`, or ImageMagick; disk
  cache keyed by a SHA-256 of `(template, canvas, values, module_key)`
- `refine_og/4` integration seam for consumer modules — kill-switch via
  `enabled?/0`, pass-through on any resolution error or missing template so a
  public page render can never crash on OG rendering
- `preview_og_image_url/3` for consumer editors to show "what the plugin will
  produce" without swapping the live OG image
- `GET /phoenix_kit/og-image/:key` image controller — `image/png` without a
  charset suffix (Telegram drops previews on binary MIME with a text charset),
  30-day immutable cache headers, configurable cache directory
- Consumer opt-in via two callbacks on the consumer's `PhoenixKit.Module`
  implementation: `og_variables/0` (declares available variables) and
  `og_resolve/2` (fetches values at render time); first consumer wired up is
  `phoenix_kit_publishing`
- Activity logging for template and assignment CRUD
- Admin dashboard integration: OpenGraph overview tab plus Templates and
  Assignments subtabs
- `phoenix_kit_og_templates` and `phoenix_kit_og_assignments` schemas
  (migration V139), with a partial-unique-index pair so Postgres NULL
  `scope_uuid` (module-wide default) and per-scope assignments don't collide

### Fixed
- The template editor's `/new` route no longer leaks an orphaned template row
  on every fresh page load — creation is now gated on `connected?/1` since
  LiveView mounts twice (disconnected + connected) for a full page load
- `Render.Svg` no longer hardcodes `http://localhost:4000` for host-relative
  image sources (e.g. the signed local-storage fallback URL); it now degrades
  the same way any other unresolvable image href does
