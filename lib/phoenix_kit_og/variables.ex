defmodule PhoenixKitOG.Variables do
  use Gettext, backend: PhoenixKitOG.Gettext

  @moduledoc """
  Registry + resolver for module-exposed variables that templates can
  bind their slots to.

  ## Sources

  - **Global** — always available regardless of consumer module.
    Owned by this module (see `global/0`). Includes site host, site
    URL, site name, current page URL, current locale.
  - **Module-declared** — external PhoenixKit modules opt in by
    implementing two optional callbacks:

        def og_variables, do: [
          %{name: "post_title", type: :text, label: "Post title", description: "..."},
          %{name: "post_featured_image", type: :image, label: "Featured image"}
        ]

        def og_resolve(var_name, context)
        # context = %{module_key: "publishing", resource: post_map, conn: conn, language: "en"}

    `og_variables/0` declares the shape; `og_resolve/2` fetches the
    value at render time. Both are auto-discovered via
    `PhoenixKit.ModuleDiscovery`.

  Globals + module-declared variables are combined at assignment-time
  in the "wire slots" dropdown — the user sees one list per slot,
  scoped by matching type.
  """

  @type variable :: %{
          name: String.t(),
          type: :text | :image,
          label: String.t(),
          description: String.t()
        }

  # =========================================================================
  # Global variables — OG-module-owned, always available.
  # =========================================================================

  @globals [
    %{
      name: "site_host",
      type: :text,
      label: "Site host",
      description: "e.g. example.com"
    },
    %{
      name: "site_url",
      type: :text,
      label: "Site URL",
      description: "e.g. https://example.com"
    },
    %{
      name: "site_name",
      type: :text,
      label: "Site name",
      description: "From the project_title setting"
    },
    %{
      name: "page_url",
      type: :text,
      label: "Current page URL",
      description: "Full URL of the page carrying this OG image"
    },
    %{
      name: "page_locale",
      type: :text,
      label: "Current locale",
      description: "e.g. en, es-ES"
    }
  ]

  @spec global() :: [variable()]
  def global, do: @globals

  @doc """
  Translated label for one of the OG-owned global variables — literal
  `gettext/1` clauses so `mix gettext.extract` sees them (a `gettext(v.label)`
  over the `@globals` attribute would be invisible to the extractor).
  Returns `nil` for a name that isn't an OG global (e.g. a consumer
  module's own variable), so the caller can fall back to `v.label`.
  """
  @spec global_label(String.t()) :: String.t() | nil
  def global_label("site_host"), do: gettext("Site host")
  def global_label("site_url"), do: gettext("Site URL")
  def global_label("site_name"), do: gettext("Site name")
  def global_label("page_url"), do: gettext("Current page URL")
  def global_label("page_locale"), do: gettext("Current locale")
  def global_label(_), do: nil

  @doc "Translated description for an OG-owned global; `nil` otherwise."
  @spec global_description(String.t()) :: String.t() | nil
  def global_description("site_host"), do: gettext("e.g. example.com")
  def global_description("site_url"), do: gettext("e.g. https://example.com")
  def global_description("site_name"), do: gettext("From the project_title setting")
  def global_description("page_url"), do: gettext("Full URL of the page carrying this OG image")
  def global_description("page_locale"), do: gettext("e.g. en, es-ES")
  def global_description(_), do: nil

  @doc "Merged list — globals + everything a consumer module declares."
  @spec for_module(String.t()) :: [variable()]
  def for_module(module_key) when is_binary(module_key) do
    from_module = module_declared_vars(module_key)
    from_module ++ @globals
  end

  def for_module(_), do: @globals

  # =========================================================================
  # Resolution — turn a slot mapping into the values map the renderer
  # substitutes into `{{...}}`.
  # =========================================================================

  @doc """
  Given the slots a template uses, an assignment's `slot_mapping`
  (`%{slot_name => variable_name}`), and a resolution context,
  produces the substitution values map for the renderer.

  Missing wires (slot not in `slot_mapping`) or unknown variable names
  return nil for that slot — the renderer leaves `{{slot}}` visible,
  matching the workspace convention.
  """
  @spec resolve([PhoenixKitOG.Slots.t()], %{String.t() => String.t()}, map()) :: %{
          String.t() => String.t()
        }
  def resolve(slots, slot_mapping, context) do
    globals_values = resolve_globals(context)

    Enum.reduce(slots, %{}, fn %{name: slot_name}, acc ->
      case Map.get(slot_mapping, slot_name) do
        nil -> acc
        var_name -> put_resolved(acc, slot_name, var_name, context, globals_values)
      end
    end)
  end

  # =========================================================================
  # Internals
  # =========================================================================

  # A `custom:` prefix in the mapping means the assignment carries a
  # literal value the author typed in (or a media UUID they picked)
  # rather than a variable name to resolve. Pass it through verbatim.
  defp put_resolved(acc, slot_name, "custom:" <> value, _context, _globals_values),
    do: Map.put(acc, slot_name, value)

  defp put_resolved(acc, slot_name, var_name, context, globals_values) do
    if Map.has_key?(globals_values, var_name) do
      Map.put(acc, slot_name, globals_values[var_name])
    else
      case resolve_via_module(var_name, context) do
        {:ok, value} -> Map.put(acc, slot_name, to_string(value))
        :error -> acc
      end
    end
  end

  defp resolve_via_module(var_name, %{module_key: module_key} = context) do
    with mod when is_atom(mod) <- module_for_key(module_key),
         true <- function_exported?(mod, :og_resolve, 2),
         value when not is_nil(value) <- safe_apply(mod, :og_resolve, [var_name, context]) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp resolve_via_module(_, _), do: :error

  defp safe_apply(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    _ -> nil
  end

  @doc """
  Flat map of all `[[global]]` values, ready to merge into the
  substitution map. Prefers `conn` fields (real request context); if
  no conn is available, falls back to the Phoenix endpoint module
  (passed as `:endpoint`) so the editor can preview real values
  without a request.
  """
  @spec global_values(map()) :: %{String.t() => String.t()}
  def global_values(context \\ %{}) do
    conn = Map.get(context, :conn)
    endpoint = Map.get(context, :endpoint)

    %{
      "site_host" => host(conn, endpoint),
      "site_url" => site_url(conn, endpoint),
      "site_name" => project_title(),
      "page_url" => Map.get(context, :page_url, canonical_from_conn(conn)),
      "page_locale" => Map.get(context, :language, "") |> to_string()
    }
  end

  defp resolve_globals(ctx), do: global_values(ctx)

  defp host(%Plug.Conn{host: host}, _), do: host

  defp host(_, endpoint) when is_atom(endpoint) do
    endpoint.host()
  rescue
    _ -> ""
  end

  defp host(_, _), do: ""

  defp site_url(%Plug.Conn{scheme: scheme, host: host, port: port}, _) do
    port_suffix = if port in [80, 443, nil], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port_suffix}"
  end

  defp site_url(_, endpoint) when is_atom(endpoint) do
    endpoint.url()
  rescue
    _ -> ""
  end

  defp site_url(_, _), do: ""

  defp canonical_from_conn(%Plug.Conn{} = conn), do: site_url(conn, nil) <> conn.request_path
  defp canonical_from_conn(_), do: ""

  defp project_title do
    PhoenixKit.Settings.get_setting("project_title") |> to_string()
  rescue
    _ -> ""
  end

  # =========================================================================
  # Module discovery
  # =========================================================================

  defp module_declared_vars(module_key) do
    case module_for_key(module_key) do
      nil ->
        []

      mod ->
        if function_exported?(mod, :og_variables, 0),
          do: safe_apply(mod, :og_variables, []) || [],
          else: []
    end
  end

  # Consumer modules identify themselves by `module_key/0` (e.g.
  # `"publishing"`). Discovery scans all PhoenixKit-registered modules
  # for a matching key.
  defp module_for_key(module_key) do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.find(fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :module_key, 0) and
        safe_apply(mod, :module_key, []) == module_key
    end)
  rescue
    _ -> nil
  end
end
