defmodule PhoenixKitOG do
  @moduledoc """
  OpenGraph template + hierarchical assignment plugin for PhoenixKit.

  See `AGENTS.md` for the high-level architecture. The integration seam
  with `phoenix_kit_publishing` is `refine_og/4` — publishing's
  `Web.Controller.build_og_data/4` calls it when this module is loaded.

  ## Module callbacks

  Implements `PhoenixKit.Module` so the host app's discovery picks this
  up automatically — no config line. Settings key: `phoenix_kit_og_enabled`.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitOG.{Assignments, Render, Slots, Templates, Variables}

  # ===========================================================================
  # Required PhoenixKit.Module callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "phoenix_kit_og"

  @impl PhoenixKit.Module
  def module_name, do: "OpenGraph"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("phoenix_kit_og_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module(
      "phoenix_kit_og_enabled",
      true,
      module_key()
    )
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module(
      "phoenix_kit_og_enabled",
      false,
      module_key()
    )
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: "0.1.1"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "OpenGraph",
      icon: "hero-share",
      description: "OpenGraph image templates + assignment per module/group/post"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      %Tab{
        id: :admin_phoenix_kit_og,
        label: "OpenGraph",
        icon: "hero-share",
        path: "open-graph",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitOG.Web.TemplatesLive, :index}
      },
      %Tab{
        id: :admin_phoenix_kit_og_templates,
        label: "Templates",
        icon: "hero-rectangle-stack",
        path: "open-graph",
        priority: 651,
        level: :admin,
        permission: module_key(),
        # Highlight on any /admin/open-graph URL that isn't the
        # Assignments subtab — so the list page, `/new`, and
        # `/:uuid/edit` all light Templates up, but Assignments keeps
        # its own subtab active.
        match: fn path ->
          String.starts_with?(path, "/admin/open-graph") and
            not String.starts_with?(path, "/admin/open-graph/assignments")
        end,
        parent: :admin_phoenix_kit_og,
        live_view: {PhoenixKitOG.Web.TemplatesLive, :index}
      },
      %Tab{
        id: :admin_phoenix_kit_og_assignments,
        label: "Assignments",
        icon: "hero-arrows-pointing-in",
        path: "open-graph/assignments",
        priority: 652,
        level: :admin,
        permission: module_key(),
        parent: :admin_phoenix_kit_og,
        live_view: {PhoenixKitOG.Web.AssignmentsLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_og]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitOG.Routes

  # ===========================================================================
  # Public API — the publishing seam
  # ===========================================================================

  @doc """
  The seam `phoenix_kit_publishing` calls. Walks the hierarchy, picks the
  winning template, and would (in Phase 3) substitute a rendered-image URL
  into `og[:image]`.

  Today it's a pass-through: if no template wins, return `og` unchanged.
  When a template wins, it still returns `og` unchanged but logs the
  resolution — once the renderer ships, this is where we swap `og[:image]`
  for the rendered URL.

  The seam contract: return a map with the same keys (`:title`,
  `:description`, `:image`, `:url`, `:locale`, `:type`). Anything else is
  ignored by publishing's HTML renderer.
  """
  @spec refine_og(map(), Plug.Conn.t() | nil, map(), String.t() | nil) :: map()
  def refine_og(og, conn, post, language) when is_map(og) do
    # Kill switch — when the admin flips the module off, publishing
    # keeps its own per-post OG image (featured image + override)
    # untouched. No template lookup, no render attempt.
    #
    # When enabled, the per-post OG override fields don't bypass the
    # plugin; they feed into it. `og_resolve` on the publishing side
    # reads them first when resolving `post_title`,
    # `post_featured_image`, etc., so authors set preferences here and
    # the plugin renders with them.
    if enabled?() do
      render_and_swap(og, conn, post, language)
    else
      og
    end
  rescue
    # Resolution failures must never crash a public post page render.
    _ -> og
  end

  @doc """
  Returns `{:ok, url}` with the OG-plugin-generated image for a post,
  or `:none` when no template resolves. Used by publishing's editor to
  render a "what the plugin will produce" preview alongside the manual
  OG-image override.
  """
  @spec preview_og_image_url(map(), Plug.Conn.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | :none
  def preview_og_image_url(post, conn, language) do
    with true <- enabled?(),
         hierarchy = publishing_hierarchy_for(post),
         {:ok, template, slot_mapping} <-
           Assignments.resolve_template_with_mapping("publishing", hierarchy),
         values = resolve_values(template, slot_mapping, conn, post, language),
         {:ok, path} <- Render.render_url(template, %{values: values}) do
      {:ok, absolutize(conn, path)}
    else
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp render_and_swap(og, conn, post, language) do
    hierarchy = publishing_hierarchy_for(post)

    with {:ok, template, slot_mapping} <-
           Assignments.resolve_template_with_mapping("publishing", hierarchy),
         values = resolve_values(template, slot_mapping, conn, post, language),
         {:ok, path} <- Render.render_url(template, %{values: values}) do
      og
      |> Map.put(:image, absolutize(conn, path))
      |> Map.put(:image_width, Map.get(template.canvas, "width", 1200))
      |> Map.put(:image_height, Map.get(template.canvas, "height", 630))
      |> Map.put(:image_type, "image/png")
    else
      :none -> og
      {:error, _reason} -> og
    end
  end

  # Merges the slot mapping with the resolver context into the
  # `%{"slot_name" => "value"}` map the SVG renderer substitutes. The
  # returned map also includes all `[[global]]` values so the renderer
  # can resolve both bracket styles from the same map.
  defp resolve_values(template, slot_mapping, conn, post, language) do
    slots = Slots.used(template.canvas)

    context = %{
      module_key: "publishing",
      resource: post,
      conn: conn,
      language: language,
      page_url: Map.get(post || %{}, :url) || Map.get(post || %{}, "url")
    }

    wired = Variables.resolve(slots, slot_mapping, context)
    globals = Variables.global_values(context)
    Map.merge(globals, wired)
  end

  defp absolutize(_conn, "http" <> _ = url), do: url

  defp absolutize(%Plug.Conn{} = conn, "/" <> _ = path) do
    port_suffix = if conn.port in [80, 443, nil], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port_suffix}#{path}"
  end

  defp absolutize(_, path), do: path

  # Builds the publishing hierarchy from a post map. Order is most-specific
  # first so `Assignments.resolve_template/2` walks it in priority order.
  # The "default" tier always trails — it matches the module-wide assignment
  # whose `scope_uuid` is NULL.
  defp publishing_hierarchy_for(post) when is_map(post) do
    [
      {"post", Map.get(post, :uuid)},
      {"group", get_in(post, [:metadata, :group_uuid])},
      {"default", nil}
    ]
  end

  # ===========================================================================
  # Re-exports — thin delegators so consumers import a single module
  # ===========================================================================

  defdelegate list_templates, to: Templates, as: :list
  defdelegate get_template(uuid), to: Templates, as: :get
  defdelegate create_template(attrs), to: Templates, as: :create
  defdelegate update_template(template, attrs), to: Templates, as: :update
  defdelegate delete_template(template), to: Templates, as: :delete

  defdelegate list_assignments(module_key), to: Assignments, as: :list_for_module

  defdelegate set_assignment(module_key, scope_type, scope_uuid, template_uuid),
    to: Assignments,
    as: :set

  defdelegate clear_assignment(module_key, scope_type, scope_uuid),
    to: Assignments,
    as: :clear

  defdelegate resolve_template(module_key, hierarchy), to: Assignments
end
