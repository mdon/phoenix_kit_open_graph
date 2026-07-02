defmodule PhoenixKitOg.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by `PhoenixKitOg.Templates`,
  `PhoenixKitOg.Assignments`, and the render pipeline) to translated,
  user-facing strings.

  Keeping UI copy in one place means every "not found" / "render failed"
  flash reads the same wording, and translations live in core's gettext
  backend rather than being scattered across LiveViews. Callers pattern-
  match on atoms (or tagged tuples for atoms with parameters);
  `message/1` wraps each mapping in `gettext/1` at the UI boundary.

  ## Supported reason shapes

    * plain atoms — `:not_found`, `:rasterizer_missing`,
      `:template_missing`, `:group_missing`
    * tagged tuples — `{:render_failed, reason}`
    * `Ecto.Changeset.t()` — passed through unchanged so callers can
      keep the changeset for `<.input>` rendering
    * strings — passed through unchanged (legacy / interpolated messages)
    * anything else — rendered as `"Unexpected error: <inspect>"` so
      nothing silently surfaces a raw struct or tuple

  ## Example

      iex> PhoenixKitOg.Errors.message(:rasterizer_missing)
      "Preview render needs the resvg NIF — check that the dep resolved on this build."
  """

  alias Ecto.Changeset

  @typedoc "Atoms returned by the public `PhoenixKitOg` API."
  @type error_atom ::
          :not_found
          | :rasterizer_missing
          | :template_missing
          | :group_missing
          | :render_failed

  @doc """
  Translates an error reason into a user-facing string via gettext.

  Use this at the UI boundary — typically inside `put_flash(:error, ...)`
  in a LiveView's `handle_event/3` clause. Context functions return
  raw atoms; the LV decides whether to surface the specific reason
  (via this helper) or a generic flash for unhandled shapes.
  """
  @spec message(term()) :: String.t() | Ecto.Changeset.t()
  def message(:not_found),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Not found.")

  def message(:rasterizer_missing),
    do:
      Gettext.gettext(
        PhoenixKitWeb.Gettext,
        "Preview render needs the resvg NIF — check that the dep resolved on this build."
      )

  def message(:template_missing),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Pick a template first.")

  def message(:group_missing),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Pick a publishing group.")

  def message({:render_failed, reason}),
    do:
      Gettext.gettext(
        PhoenixKitWeb.Gettext,
        "Preview render failed: %{reason}",
        reason: truncate(inspect(reason))
      )

  # Pass-through for shapes that already carry user-renderable content.
  def message(%Changeset{} = changeset), do: changeset
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    Gettext.gettext(
      PhoenixKitWeb.Gettext,
      "Unexpected error: %{reason}",
      reason: truncate(inspect(reason))
    )
  end

  # Truncate raw values that ride into translated strings so a large
  # blob doesn't end up in a flash. Keeps audit context (logs see the
  # full raw value) while bounding UI surface.
  @spec truncate(term()) :: String.t()
  defp truncate(value) do
    str = if is_binary(value), do: value, else: inspect(value)

    if String.length(str) > 100 do
      String.slice(str, 0, 100) <> "…"
    else
      str
    end
  end
end
