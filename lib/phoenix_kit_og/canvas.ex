defmodule PhoenixKitOG.Canvas do
  @moduledoc """
  Pure helpers for manipulating a template's canvas JSON. The editor LV
  calls these on the in-memory canvas map; persistence is a separate
  `Templates.update/2` step.

  Canvas shape:

      %{
        "width" => 1200,
        "height" => 630,
        "background" => %{"type" => "color", "value" => "#0b1220"},
        "elements" => [%{"id" => "abc", "type" => "text", …}, …]
      }

  Element ids are short random strings — stable across reorders/edits
  so the editor can refer to them, but ephemeral (regenerated on
  duplication).
  """

  @canvas_width 1200
  @canvas_height 630

  @doc "The canonical empty canvas. Used when a new template is created."
  @spec blank() :: map()
  def blank do
    %{
      "width" => @canvas_width,
      "height" => @canvas_height,
      "background" => %{"type" => "color", "value" => "#0b1220"},
      "elements" => []
    }
  end

  @doc "Reads the elements list, defaulting to `[]` for legacy canvases."
  @spec elements(map()) :: [map()]
  def elements(canvas), do: Map.get(canvas, "elements", [])

  @doc "Replaces the elements list."
  @spec put_elements(map(), [map()]) :: map()
  def put_elements(canvas, elements), do: Map.put(canvas, "elements", elements)

  @doc "Looks up a single element by id."
  @spec get_element(map(), String.t()) :: map() | nil
  def get_element(canvas, id) when is_binary(id),
    do: Enum.find(elements(canvas), &(&1["id"] == id))

  @doc """
  Adds a new element at the end of the z-stack (rendered on top).

  Returns `{updated_canvas, new_element}` so the caller can immediately
  select the new id without recomputing it.
  """
  @spec add_element(map(), map()) :: {map(), map()}
  def add_element(canvas, attrs) when is_map(attrs) do
    element =
      attrs
      |> Map.put_new("id", gen_id())
      |> Map.put_new("x", 60)
      |> Map.put_new("y", 60)
      |> Map.put_new("width", 200)
      |> Map.put_new("height", 80)

    {put_elements(canvas, elements(canvas) ++ [element]), element}
  end

  @doc """
  Builds a fresh element struct for the given insert `kind`. Kinds:

  - `"text"` / `"text_var"` — text element, static content vs. an
    auto-named `{{TextN}}` slot placeholder.
  - `"image"` / `"image_var"` — image element, empty src vs.
    `{{ImageN}}`.
  - `"rect"` — rectangle.

  The caller passes the current canvas so the helper can pick a slot
  name that doesn't collide with existing slots.
  """
  @spec default_element(String.t(), map()) :: map()
  def default_element(kind, canvas \\ %{})

  def default_element("text", _canvas) do
    %{
      "id" => gen_id(),
      "type" => "text",
      "x" => 100,
      "y" => 240,
      "width" => 1000,
      "height" => 120,
      "text" => "Your text",
      "binding" => "",
      "font" => "Inter",
      "size" => 72,
      "weight" => 700,
      "color" => "#ffffff",
      "align" => "left",
      "valign" => "top",
      "underlay_color" => "dark",
      "underlay_opacity" => 0
    }
  end

  def default_element("text_var", canvas) do
    name = next_slot_name(canvas, "Text")

    "text"
    |> default_element(canvas)
    |> Map.put("text", "{{#{name}}}")
  end

  def default_element("image", _canvas) do
    %{
      "id" => gen_id(),
      "type" => "image",
      "x" => 60,
      "y" => 60,
      "width" => 160,
      "height" => 160,
      "src" => "",
      "fit" => "fill",
      "underlay_color" => "dark",
      "underlay_opacity" => 0
    }
  end

  def default_element("image_var", canvas) do
    name = next_slot_name(canvas, "Image")

    "image"
    |> default_element(canvas)
    |> Map.merge(%{
      "src" => "{{#{name}}}",
      "width" => 320,
      "height" => 320
    })
  end

  def default_element("rect", _canvas) do
    %{
      "id" => gen_id(),
      "type" => "rect",
      "x" => 100,
      "y" => 100,
      "width" => 400,
      "height" => 200,
      "fill" => "#1e293b",
      "stroke" => "",
      "stroke_width" => 0,
      "radius" => 12,
      "underlay_color" => "dark",
      "underlay_opacity" => 0
    }
  end

  # Website elements — text elements pre-filled with an OG **global**
  # reference (double-bracket syntax). Globals resolve automatically
  # from settings/context, so the author sees the real value in the
  # editor and never has to wire them at assignment time.
  def default_element("global:site_url", canvas),
    do: default_element("text", canvas) |> Map.put("text", "[[site_url]]")

  def default_element("global:site_host", canvas),
    do: default_element("text", canvas) |> Map.put("text", "[[site_host]]")

  def default_element("global:site_name", canvas),
    do: default_element("text", canvas) |> Map.put("text", "[[site_name]]")

  def default_element("global:page_url", canvas),
    do: default_element("text", canvas) |> Map.put("text", "[[page_url]]")

  def default_element("global:page_locale", canvas),
    do: default_element("text", canvas) |> Map.put("text", "[[page_locale]]")

  def default_element(_, canvas), do: default_element("text", canvas)

  @doc """
  Finds an unused slot name with the given prefix. Returns the bare
  prefix if it's free, otherwise appends the lowest unused numeric
  suffix — so a fresh canvas gets `Text`, a second `Text` insert gets
  `Text2`, and so on.

  Names stay descriptive rather than always carrying a numeric suffix,
  which reads better in the "Wire slots" list on the Assignments page.
  """
  @spec next_slot_name(map(), String.t()) :: String.t()
  def next_slot_name(canvas, prefix) when is_binary(prefix) do
    taken =
      canvas
      |> then(fn c -> if is_map(c), do: PhoenixKitOG.Slots.used(c), else: [] end)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    if MapSet.member?(taken, prefix) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find(fn n -> not MapSet.member?(taken, "#{prefix}#{n}") end)
      |> then(fn n -> "#{prefix}#{n}" end)
    else
      prefix
    end
  end

  defp strip_curly("{{" <> rest) do
    case String.split(rest, "}}", parts: 2) do
      [name, _] -> name
      _ -> rest
    end
  end

  defp strip_curly(v) when is_binary(v), do: v
  defp strip_curly(_), do: ""

  @doc """
  Updates a top-level canvas field (width, height, background). Values
  are coerced to their expected shape.
  """
  @spec update_canvas_field(map(), String.t(), any()) :: map()
  def update_canvas_field(canvas, "width", value),
    do: Map.put(canvas, "width", coerce_positive_int(value, 1200))

  def update_canvas_field(canvas, "height", value),
    do: Map.put(canvas, "height", coerce_positive_int(value, 630))

  def update_canvas_field(canvas, "background_type", value) when value in ["color", "image"] do
    bg = Map.get(canvas, "background", %{}) |> Map.put("type", value)
    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_value", value) when is_binary(value) do
    bg = Map.get(canvas, "background", %{}) |> Map.put("value", value)
    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_overlay_opacity", value) do
    opacity =
      value
      |> to_number()
      |> max(0)
      |> min(1)

    bg = Map.get(canvas, "background", %{}) |> Map.put("overlay_opacity", opacity)
    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_overlay_color", value)
      when value in ["dark", "light"] do
    bg = Map.get(canvas, "background", %{}) |> Map.put("overlay_color", value)
    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_fit", value)
      when value in ["fill", "contain", "stretch"] do
    bg = Map.get(canvas, "background", %{}) |> Map.put("fit", value)
    Map.put(canvas, "background", bg)
  end

  # Background source shape:
  #
  #   - "constant" — user supplies a media UUID / URL; stored in `value`.
  #   - "variable" — user supplies a slot name; wrapped into `{{name}}`
  #     and stored in `value` so the substitution pipeline treats it
  #     like any other slot.
  #
  # An explicit `value_mode` field carries the UI choice so we can
  # remember the mode across empty-value states (e.g. user switches to
  # "variable" but hasn't typed a name yet).
  def update_canvas_field(canvas, "background_value_mode", "constant") do
    bg = Map.get(canvas, "background", %{}) |> Map.put("value_mode", "constant")
    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_value_mode", "variable") do
    bg = Map.get(canvas, "background", %{})
    # Seed a descriptive default the first time the user flips to
    # Variable mode. `next_slot_name` picks the next free
    # `BackgroundImage[N]` — so a fresh canvas gets `BackgroundImage`,
    # a second `Variable` slot gets `BackgroundImage2`, etc.
    existing_name = Map.get(bg, "value_name")
    existing_value = Map.get(bg, "value", "")

    name =
      cond do
        is_binary(existing_name) and existing_name != "" ->
          existing_name

        is_binary(existing_value) and String.starts_with?(existing_value, "{{") ->
          strip_curly(existing_value)

        true ->
          next_slot_name(canvas, "BackgroundImage")
      end

    bg =
      bg
      |> Map.put("value_mode", "variable")
      |> Map.put("value_name", name)
      |> Map.put("value", "{{#{name}}}")

    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, "background_variable_name", value) when is_binary(value) do
    # Store the raw name for display, and materialize `{{name}}` into
    # `value` so downstream code (Slots.used, Svg renderer) sees the
    # canonical slot syntax.
    trimmed = String.trim(value)

    bg =
      canvas
      |> Map.get("background", %{})
      |> Map.put("value_mode", "variable")
      |> Map.put("value_name", trimmed)
      |> Map.put("value", if(trimmed == "", do: "", else: "{{#{trimmed}}}"))

    Map.put(canvas, "background", bg)
  end

  def update_canvas_field(canvas, _field, _value), do: canvas

  defp coerce_positive_int(v, default) do
    n = to_number(v) |> trunc()
    if n > 0, do: n, else: default
  end

  @doc """
  Updates one field on a single element. Coordinate + size fields
  (`x`/`y`/`width`/`height`) are coerced to numbers and clamped inside
  the canvas; everything else passes through.
  """
  @spec update_element(map(), String.t(), String.t(), any()) :: map()
  def update_element(canvas, id, field, value) do
    elements =
      Enum.map(elements(canvas), fn
        %{"id" => ^id} = el -> Map.put(el, field, coerce(field, value, el, canvas))
        el -> el
      end)

    put_elements(canvas, elements)
  end

  @doc """
  Bulk-applies `{x, y}` deltas to a list of element ids — fast path for
  drag operations that move several elements at once.
  """
  @spec move_elements(map(), [String.t()], number(), number()) :: map()
  def move_elements(canvas, ids, dx, dy) when is_list(ids) do
    elements =
      Enum.map(elements(canvas), fn el ->
        if el["id"] in ids do
          el
          |> Map.update("x", 0, &clamp_x(&1 + dx, el, canvas))
          |> Map.update("y", 0, &clamp_y(&1 + dy, el, canvas))
        else
          el
        end
      end)

    put_elements(canvas, elements)
  end

  @doc "Removes the given element ids."
  @spec delete_elements(map(), [String.t()]) :: map()
  def delete_elements(canvas, ids) when is_list(ids) do
    put_elements(canvas, Enum.reject(elements(canvas), &(&1["id"] in ids)))
  end

  @doc "Moves the given element to the top of the z-stack."
  @spec bring_to_front(map(), String.t()) :: map()
  def bring_to_front(canvas, id) do
    case Enum.split_with(elements(canvas), &(&1["id"] == id)) do
      {[el], rest} -> put_elements(canvas, rest ++ [el])
      _ -> canvas
    end
  end

  @doc "Moves the given element to the bottom of the z-stack."
  @spec send_to_back(map(), String.t()) :: map()
  def send_to_back(canvas, id) do
    case Enum.split_with(elements(canvas), &(&1["id"] == id)) do
      {[el], rest} -> put_elements(canvas, [el | rest])
      _ -> canvas
    end
  end

  @doc """
  Substitutes `{{slot}}` tokens in a text/stamp element. Unknown slots
  pass through unchanged (`{{name}}` stays visible), matching the
  workspace convention.

  Used by the editor preview; the SVG renderer calls `Slots.substitute`
  directly.
  """
  @spec resolve_text(map(), map()) :: String.t()
  def resolve_text(%{"type" => "text", "text" => t}, values) when is_binary(t),
    do: PhoenixKitOG.Slots.substitute(t, values)

  def resolve_text(%{"type" => "text", "binding" => b}, values)
      when is_binary(b) and b != "",
      do: PhoenixKitOG.Slots.substitute(b, values)

  def resolve_text(%{"type" => "stamp", "preset" => p}, values) when is_binary(p),
    do: PhoenixKitOG.Slots.substitute(p, values)

  def resolve_text(_, _), do: ""

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # 8-char alphanumeric, sufficient for collision-free ids within a single
  # canvas (~1000 elements would still be safe).
  defp gen_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64() |> binary_part(0, 8)
  end

  # Coordinate / size coercion + clamping. Other fields pass through unchanged.
  defp coerce(field, value, el, canvas) when field in ["x", "width"] do
    value |> to_number() |> clamp_x(el, canvas, field)
  end

  defp coerce(field, value, el, canvas) when field in ["y", "height"] do
    value |> to_number() |> clamp_y(el, canvas, field)
  end

  defp coerce("size", value, _el, _canvas), do: max(8, to_number(value))
  defp coerce("weight", value, _el, _canvas), do: to_number(value)
  defp coerce("radius", value, _el, _canvas), do: max(0, to_number(value))
  defp coerce("stroke_width", value, _el, _canvas), do: max(0, to_number(value))

  defp coerce("underlay_opacity", value, _el, _canvas),
    do: value |> to_number() |> max(0) |> min(1)

  defp coerce("underlay_color", v, _, _) when v in ["dark", "light"], do: v
  defp coerce("underlay_color", _, _, _), do: "dark"
  defp coerce(_field, value, _el, _canvas), do: value

  defp to_number(v) when is_number(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp clamp_x(value, el, canvas), do: clamp_x(value, el, canvas, "x")

  defp clamp_x(value, el, canvas, "x") do
    width = Map.get(el, "width", 0)
    canvas_width = Map.get(canvas, "width", @canvas_width)
    value |> max(0) |> min(canvas_width - width) |> trunc()
  end

  defp clamp_x(value, _el, canvas, "width") do
    canvas_width = Map.get(canvas, "width", @canvas_width)
    value |> max(1) |> min(canvas_width) |> trunc()
  end

  defp clamp_y(value, el, canvas), do: clamp_y(value, el, canvas, "y")

  defp clamp_y(value, el, canvas, "y") do
    height = Map.get(el, "height", 0)
    canvas_height = Map.get(canvas, "height", @canvas_height)
    value |> max(0) |> min(canvas_height - height) |> trunc()
  end

  defp clamp_y(value, _el, canvas, "height") do
    canvas_height = Map.get(canvas, "height", @canvas_height)
    value |> max(1) |> min(canvas_height) |> trunc()
  end
end
