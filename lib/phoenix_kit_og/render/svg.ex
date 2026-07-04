defmodule PhoenixKitOG.Render.Svg do
  @moduledoc """
  Converts a canvas spec + binding values into a clean SVG string
  suitable for rasterization by `rsvg-convert` / librsvg.

  Why we generate fresh SVG instead of reusing the editor's HEEx output:

  - The editor uses `<foreignObject>` to embed HTML for ergonomic text
    layout. librsvg ignores `foreignObject`, so we generate native
    `<text>` + `<tspan>` here with manual word wrapping.
  - The editor renders a 60%-scaled preview; the rasterizer needs the
    full-size SVG (the canvas's intrinsic `width`/`height`).

  The output is **deterministic** — same canvas + values produce
  byte-identical SVG. That's load-bearing for cache-key hashing in
  `PhoenixKitOG.Render.Cache`.
  """

  alias PhoenixKitOG.{Canvas, Slots}

  @type context :: %{
          optional(:values) => %{String.t() => String.t()}
        }

  @doc """
  Renders the canvas to an SVG string.

  `context` carries the variable values used to substitute bindings
  (`{post.title}` etc.) and the consumer module key used to look up
  fallback example values.
  """
  @spec render(map(), context()) :: iodata()
  def render(canvas, context \\ %{}) when is_map(canvas) do
    width = Map.get(canvas, "width", 1200)
    height = Map.get(canvas, "height", 630)
    background = Map.get(canvas, "background", %{"type" => "color", "value" => "#0b1220"})

    [
      ~s|<?xml version="1.0" encoding="UTF-8"?>|,
      ~s|<svg xmlns="http://www.w3.org/2000/svg" |,
      ~s|width="#{width}" height="#{height}" |,
      ~s|viewBox="0 0 #{width} #{height}">|,
      render_background(background, width, height, context),
      Enum.map(Canvas.elements(canvas), &render_element(&1, context)),
      ~s|</svg>|
    ]
  end

  @doc """
  Render to a binary (the rasterizer pipes bytes via stdin). Convenience
  over `render/2 |> IO.iodata_to_binary/1`.
  """
  @spec to_binary(map(), context()) :: binary()
  def to_binary(canvas, context \\ %{}),
    do: canvas |> render(context) |> IO.iodata_to_binary()

  # =========================================================================
  # Background
  # =========================================================================

  defp render_background(%{"type" => "color", "value" => color}, w, h, _ctx) do
    ~s|<rect x="0" y="0" width="#{w}" height="#{h}" fill="#{escape(color)}"/>|
  end

  defp render_background(%{"type" => "image", "value" => src} = bg, w, h, ctx)
       when is_binary(src) and src != "" do
    resolved = Slots.substitute(src, ctx[:values] || %{})

    if String.starts_with?(resolved, "{{") or resolved == "" do
      # Unresolved slot — no href we can safely emit. Fall back to the
      # solid default color if declared, else the fixed dark bg.
      fallback = Map.get(bg, "value_fallback", "#0b1220")
      ~s|<rect x="0" y="0" width="#{w}" height="#{h}" fill="#{escape(fallback)}"/>|
    else
      href = resolve_image_href(resolved)

      if href == "" do
        ~s|<rect x="0" y="0" width="#{w}" height="#{h}" fill="#0b1220"/>|
      else
        overlay = Map.get(bg, "overlay_opacity", 0)
        overlay_hex = overlay_hex(bg)

        overlay_rect =
          if is_number(overlay) and overlay > 0,
            do:
              ~s|<rect x="0" y="0" width="#{w}" height="#{h}" fill="#{overlay_hex}" fill-opacity="#{overlay}"/>|,
            else: ""

        preserve = fit_to_preserve_aspect_ratio(Map.get(bg, "fit", "fill"))

        ~s|<image href="#{escape(href)}" x="0" y="0" width="#{w}" height="#{h}" preserveAspectRatio="#{preserve}"/>#{overlay_rect}|
      end
    end
  end

  defp render_background(_, w, h, _ctx),
    do: ~s|<rect x="0" y="0" width="#{w}" height="#{h}" fill="#0b1220"/>|

  defp overlay_hex(%{"overlay_color" => "light"}), do: "#ffffff"
  defp overlay_hex(_), do: "#000000"

  # Maps our friendly `fit` field to SVG's `preserveAspectRatio`.
  defp fit_to_preserve_aspect_ratio("contain"), do: "xMidYMid meet"
  defp fit_to_preserve_aspect_ratio("stretch"), do: "none"
  defp fit_to_preserve_aspect_ratio(_), do: "xMidYMid slice"

  # Element-level underlay — a translucent dark/light rect sized to the
  # element's bounds, drawn *before* the element. Off when opacity=0.
  defp element_underlay(%{"underlay_opacity" => o} = el) when is_number(o) and o > 0 do
    fill = if Map.get(el, "underlay_color") == "light", do: "#ffffff", else: "#000000"

    ~s|<rect x="#{el["x"]}" y="#{el["y"]}" width="#{el["width"]}" height="#{el["height"]}" fill="#{fill}" fill-opacity="#{o}"/>|
  end

  defp element_underlay(_), do: ""

  # =========================================================================
  # Elements
  # =========================================================================

  defp render_element(%{"type" => "text"} = el, ctx) do
    values = ctx[:values] || %{}
    text = Slots.substitute(el["text"] || el["binding"] || "", values)
    # Text underlays are drawn per line (hugging the text) rather than
    # over the whole bounding box — see `render_text_block`.
    render_text_block(el, text)
  end

  defp render_element(%{"type" => "stamp"} = el, ctx) do
    text = Slots.substitute(el["preset"] || "", ctx[:values] || %{})
    render_text_block(el, text)
  end

  defp render_element(%{"type" => "rect"} = el, _ctx) do
    fill = el["fill"] || "#1e293b"
    stroke = blank_to_none(el["stroke"])
    sw = el["stroke_width"] || 0
    radius = el["radius"] || 0

    rect =
      ~s|<rect x="#{el["x"]}" y="#{el["y"]}" width="#{el["width"]}" height="#{el["height"]}" rx="#{radius}" ry="#{radius}" fill="#{escape(fill)}" stroke="#{escape(stroke)}" stroke-width="#{sw}"/>|

    [element_underlay(el), rect]
  end

  defp render_element(%{"type" => "image"} = el, ctx) do
    values = ctx[:values] || %{}

    case Slots.substitute(el["src"] || "", values) do
      src when is_binary(src) and src != "" ->
        # After substitution the src may still be an un-resolved slot
        # (`{{background_image_1}}` with no wiring). Skip the element
        # rather than emit an `<image href="{{...}}"/>` that librsvg
        # would render as a broken image icon.
        if String.starts_with?(src, "{{") do
          []
        else
          href = resolve_image_href(src)
          preserve = fit_to_preserve_aspect_ratio(Map.get(el, "fit", "fill"))

          image_el =
            ~s|<image href="#{escape(href)}" x="#{el["x"]}" y="#{el["y"]}" width="#{el["width"]}" height="#{el["height"]}" preserveAspectRatio="#{preserve}"/>|

          [element_underlay(el), image_el]
        end

      _ ->
        []
    end
  end

  defp render_element(_, _), do: []

  # =========================================================================
  # Text block — native <text>/<tspan> with manual word wrap
  # =========================================================================

  defp render_text_block(el, text) when is_binary(text) do
    size = num(el["size"], 32)
    weight = num(el["weight"], 400)
    color = el["color"] || "#ffffff"
    # resvg searches system fonts via fontdb — append a widely-available
    # fallback so text renders even when the picked font (e.g. Inter)
    # isn't installed on the render host. DejaVu Sans ships on nearly
    # every Linux, sans-serif is the last-resort generic.
    font = with_font_fallback(el["font"] || "Inter")
    align = el["align"] || "left"
    valign = el["valign"] || "top"
    width = num(el["width"], 100)
    height = num(el["height"], size * 1.2)
    x = num(el["x"], 0)
    y = num(el["y"], 0)

    # Manual word wrap. We estimate average glyph advance at 55% of em —
    # right in the middle of common sans-serifs; close enough for OG
    # layout where overshoot truncates at the box edge rather than
    # overflowing.
    avg_glyph = size * 0.55
    max_chars_per_line = max(1, trunc(width / avg_glyph))
    lines = wrap_text(text, max_chars_per_line)

    line_height = size * 1.15
    block_height = line_height * length(lines)

    # First-line baseline based on vertical alignment of the block within
    # the element's box. SVG `dominant-baseline="hanging"` would simplify
    # but librsvg's support is patchy — explicit y arithmetic is safest.
    first_baseline =
      case valign do
        "top" -> y + size
        "middle" -> y + (height - block_height) / 2 + size
        "bottom" -> y + height - block_height + size
        _ -> y + size
      end

    {anchor, anchor_x} =
      case align do
        "left" -> {"start", x}
        "center" -> {"middle", x + width / 2}
        "right" -> {"end", x + width}
        _ -> {"start", x}
      end

    tspans =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        dy = if i == 0, do: 0, else: line_height
        ~s|<tspan x="#{anchor_x}" dy="#{dy}">#{escape(line)}</tspan>|
      end)

    # Glow filter — feGaussianBlur + feFlood + feComposite gives a
    # colored aura shaped like the (blurred) text alpha. Radius scales
    # with size so a caption gets a subtle halo and a headline a bold
    # one. `filter` is applied on the `<text>`; no filter markup is
    # emitted when the underlay is off.
    {filter_def, filter_attr} = text_glow_filter(el, size)

    [
      filter_def,
      ~s|<text x="#{anchor_x}" y="#{first_baseline}" |,
      filter_attr,
      ~s|font-family="#{escape(font)}" font-size="#{size}" font-weight="#{weight}" |,
      ~s|fill="#{escape(color)}" text-anchor="#{anchor}">|,
      tspans,
      ~s|</text>|
    ]
  end

  # Returns `{filter_defs, filter_attr}` for a text/stamp element. When
  # `underlay_opacity` is 0, both are empty and the text renders
  # unadorned. Otherwise the filter is emitted inline (resvg is happy
  # with filters outside `<defs>`) and the text element gets a matching
  # `filter=url(#...)` attribute.
  defp text_glow_filter(el, size) do
    opacity = Map.get(el, "underlay_opacity", 0)

    if is_number(opacity) and opacity > 0 do
      color = if Map.get(el, "underlay_color") == "light", do: "#ffffff", else: "#000000"
      # `stdDeviation` = ~10% of font size — visible halo without
      # overwhelming the glyphs. `feMerge` stacks the glow twice
      # underneath to intensify the aura before the crisp text lands
      # on top.
      std = size * 0.1
      id = "og-glow-#{el["id"] || Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

      filter_def =
        ~s|<filter id="#{id}" x="-30%" y="-30%" width="160%" height="160%">| <>
          ~s|<feGaussianBlur in="SourceAlpha" stdDeviation="#{std}" result="blur"/>| <>
          ~s|<feFlood flood-color="#{color}" flood-opacity="#{opacity}"/>| <>
          ~s|<feComposite in2="blur" operator="in" result="glow"/>| <>
          ~s|<feMerge>| <>
          ~s|<feMergeNode in="glow"/>| <>
          ~s|<feMergeNode in="glow"/>| <>
          ~s|<feMergeNode in="SourceGraphic"/>| <>
          ~s|</feMerge>| <>
          ~s|</filter>|

      {filter_def, ~s|filter="url(##{id})" |}
    else
      {"", ""}
    end
  end

  # =========================================================================
  # Word wrap — char-bucket heuristic
  # =========================================================================

  defp wrap_text("", _max), do: [""]

  defp wrap_text(text, max) do
    # Preserve user-inserted line breaks; wrap each line independently.
    text
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&wrap_line(&1, max))
    |> case do
      [] -> [""]
      lines -> lines
    end
  end

  defp wrap_line("", _max), do: [""]

  defp wrap_line(line, max) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce({[], ""}, fn word, {lines, current} ->
      candidate = if current == "", do: word, else: current <> " " <> word

      cond do
        String.length(candidate) <= max ->
          {lines, candidate}

        current == "" ->
          # Single word longer than the line — hard-break it.
          {lines ++ chunk_long_word(word, max), ""}

        true ->
          {lines ++ [current], word}
      end
    end)
    |> finalize_line()
  end

  defp finalize_line({lines, ""}), do: lines
  defp finalize_line({lines, current}), do: lines ++ [current]

  defp chunk_long_word(word, max) do
    word
    |> String.graphemes()
    |> Enum.chunk_every(max)
    |> Enum.map(&Enum.join/1)
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  defp blank_to_none(""), do: "none"
  defp blank_to_none(nil), do: "none"
  defp blank_to_none(v), do: v

  @font_fallbacks ["DejaVu Sans", "Liberation Sans", "Arial", "sans-serif"]

  defp with_font_fallback(font) when is_binary(font) do
    picked = String.split(font, ",", parts: 2) |> List.first() |> String.trim()
    [picked | @font_fallbacks] |> Enum.uniq() |> Enum.join(", ")
  end

  defp with_font_fallback(_), do: Enum.join(@font_fallbacks, ", ")

  defp num(v, _default) when is_number(v), do: v

  defp num(v, default) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp num(_, default), do: default

  # XML attribute escaping — the bare minimum.
  defp escape(nil), do: ""
  defp escape(value) when is_number(value), do: to_string(value)

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape(value), do: value |> to_string() |> escape()

  # Image href resolution. The rasterizer (resvg NIF / rsvg-convert)
  # runs locally and can't fetch remote HTTP URLs — it only reads bytes
  # from `data:` URLs or local files. So for anything with a media UUID
  # we resolve to the actual file bytes and inline them as a data URL.
  # HTTP URLs are kept as-is; the rasterizer will just skip them (used
  # by the pre-existing `refine_og` path where the URL is emitted into
  # `og.image` HTML, not into the SVG we rasterize).
  defp resolve_image_href("http://" <> _ = url), do: url
  defp resolve_image_href("https://" <> _ = url), do: url
  defp resolve_image_href("file://" <> _ = url), do: url
  defp resolve_image_href("data:" <> _ = url), do: url

  # A host-relative path (e.g. the signed local-storage fallback URL)
  # isn't fetchable by the rasterizer any more than a remote HTTP URL
  # is — it only reads `data:` URLs or local file bytes. Treat it as
  # unresolved so the caller falls back to its default background/
  # placeholder handling instead of guessing at the deployment's origin.
  defp resolve_image_href("/" <> _), do: ""

  defp resolve_image_href(uuid) when is_binary(uuid) do
    # Media UUID — prefer inlining the bytes as `data:` so resvg can
    # render the image; only fall back to the HTTP public URL when local
    # bytes aren't reachable (which resvg will silently skip, but at
    # least crawlers can still fetch if they read the raw href).
    case data_url_for_uuid(uuid) do
      {:ok, data_url} ->
        data_url

      :error ->
        case PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid, "medium") ||
               PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid) do
          url when is_binary(url) -> resolve_image_href(url)
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end

  defp resolve_image_href(_), do: ""

  # Try each variant in order until we find one whose bytes we can read
  # from a local bucket. `medium` is small enough to embed without
  # bloating the SVG for previews; `original` is the fallback when no
  # variant is available.
  defp data_url_for_uuid(uuid) do
    Enum.reduce_while(["medium", "original"], :error, fn variant, acc ->
      case read_local_bytes(uuid, variant) do
        {:ok, bytes, mime} -> {:halt, {:ok, encode_data_url(bytes, mime)}}
        :error -> {:cont, acc}
      end
    end)
  end

  defp read_local_bytes(uuid, variant) do
    with %{file_name: file_path, mime_type: mime} <-
           PhoenixKit.Modules.Storage.get_file_instance_by_name(uuid, variant),
         {:ok, local_path} <-
           PhoenixKit.Modules.Storage.Manager.get_local_file_path(file_path),
         {:ok, bytes} <- File.read(local_path) do
      {:ok, bytes, mime || "application/octet-stream"}
    else
      _ -> :error
    end
  end

  defp encode_data_url(bytes, mime) do
    "data:" <> mime <> ";base64," <> Base.encode64(bytes)
  end
end
