defmodule PhoenixKitOG.Web.AssignmentsLive do
  @moduledoc """
  Assignments admin — the overview of every template binding + a
  single modal for creating **or** editing an assignment.

  Layout:

  - **Top**: header + "Assign template" button.
  - **Overview list**: every assignment (module-default row, per-group
    rows) with the template it points at + row actions (edit, remove).
  - **Assignment modal**: opened for both "new" and "edit". Carries
    scope, group (when scope=group), template, and the per-slot
    wiring dropdowns — all in one place. Local `@edit_state` holds
    the in-progress config until the user hits Save.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitOG.Gettext

  require Logger

  # Enables the shared MediaSelectorModal (uploads + validate stub +
  # handle_info delegator) so image slots can be filled by clicking
  # "Choose image" instead of pasting a UUID.
  use PhoenixKitWeb.Components.MediaBrowser.Embed

  alias PhoenixKitOG.{Assignments, Errors, Paths, Slots, Templates, Variables}

  # Publishing groups/posts helpers live in the phoenix_kit_publishing
  # plugin — guarded by `Code.ensure_loaded?/1` in each helper, but the
  # compiler still warns without an explicit `:no_warn_undefined`.
  @compile {:no_warn_undefined,
            [PhoenixKit.Modules.Publishing.Posts, PhoenixKit.Modules.Publishing.Groups]}

  @consumer "publishing"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("OpenGraph — Assignments"))
     |> assign(:consumer, @consumer)
     |> assign(:editing_id, nil)
     |> assign(:edit_state, blank_edit_state())
     |> assign(:show_media_selector, false)
     |> assign(:media_selection_mode, :single)
     |> assign(:media_selected_uuids, [])
     |> assign(:media_slot_target, nil)
     |> assign(:preview_url, nil)
     |> assign(:preview_error, nil)
     |> assign(:preview_loading, false)
     |> assign(:preview_group_slug, nil)
     |> assign(:preview_post_uuid, nil)
     |> assign(:preview_posts, [])
     |> assign(
       :global_values,
       Variables.global_values(%{
         endpoint: socket.endpoint,
         language: socket.assigns[:current_locale] || ""
       })
     )
     |> load()}
  end

  # =========================================================================
  # Modal open / close
  # =========================================================================

  @impl true
  def handle_event("open_new", _params, socket) do
    default_template_uuid =
      case socket.assigns.templates do
        [first | _] -> first.uuid
        _ -> nil
      end

    edit_state = %{
      scope: "default",
      group_uuid: nil,
      template_uuid: default_template_uuid,
      slot_mapping: %{}
    }

    {:noreply,
     socket
     |> assign(:editing_id, "new")
     |> assign(:edit_state, edit_state)
     |> auto_pick_preview_source(nil)
     |> refresh_preview()}
  end

  def handle_event("open_edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.assignments, &(&1.uuid == id)) do
      nil ->
        {:noreply, socket}

      a ->
        edit_state = %{
          scope: a.scope_type,
          group_uuid: a.scope_uuid,
          template_uuid: a.template_uuid,
          slot_mapping: a.slot_mapping || %{}
        }

        {:noreply,
         socket
         |> assign(:editing_id, id)
         |> assign(:edit_state, edit_state)
         |> auto_pick_preview_source(a.scope_uuid)
         |> refresh_preview()}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_id, nil)
     |> assign(:preview_url, nil)
     |> assign(:preview_error, nil)
     |> assign(:preview_loading, false)}
  end

  # =========================================================================
  # In-modal field changes — all edits stay local to `@edit_state` and
  # only hit the DB when the user clicks Save.
  # =========================================================================

  def handle_event("edit_change_scope", %{"scope" => scope}, socket) do
    edit_state =
      socket.assigns.edit_state
      |> Map.put(:scope, scope)
      |> Map.put(:group_uuid, if(scope == "default", do: nil, else: nil))

    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  def handle_event("edit_change_group", %{"group_uuid" => uuid}, socket) do
    edit_state = Map.put(socket.assigns.edit_state, :group_uuid, normalize(uuid))
    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  def handle_event("edit_change_template", %{"template_uuid" => uuid}, socket) do
    edit_state = Map.put(socket.assigns.edit_state, :template_uuid, normalize(uuid))
    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  # `variable` is the raw dropdown value:
  #  - "" → clear the mapping
  #  - "__custom__" → seed a `custom:` entry so the row switches to the
  #    text-input mode (kept empty until the author types).
  #  - "var_name" → wire straight to that variable.
  def handle_event("edit_wire_slot", %{"slot" => slot, "variable" => variable}, socket) do
    stored =
      case variable do
        "" -> ""
        "__custom__" -> "custom:"
        v -> v
      end

    mapping = put_or_delete(socket.assigns.edit_state.slot_mapping || %{}, slot, stored)
    edit_state = Map.put(socket.assigns.edit_state, :slot_mapping, mapping)
    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  # Custom text entry — updates the `custom:...` payload as the user
  # types.
  def handle_event(
        "edit_wire_slot_custom",
        %{"slot" => slot, "value" => value},
        socket
      ) do
    mapping = Map.put(socket.assigns.edit_state.slot_mapping || %{}, slot, "custom:" <> value)
    edit_state = Map.put(socket.assigns.edit_state, :slot_mapping, mapping)
    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  # Image slot media pick — opens the shared MediaSelectorModal.
  def handle_event("open_slot_media_picker", %{"slot" => slot}, socket) do
    {:noreply,
     socket
     |> assign(:media_slot_target, slot)
     |> assign(:show_media_selector, true)}
  end

  # Preview data source — user changes the group. Auto-pick a post
  # from that group's listing.
  def handle_event("change_preview_group", %{"group_slug" => slug}, socket) do
    posts = list_publishing_posts(slug)
    post_uuid = pick_default_post_uuid(posts)

    {:noreply,
     socket
     |> assign(:preview_group_slug, normalize(slug))
     |> assign(:preview_posts, posts)
     |> assign(:preview_post_uuid, post_uuid)
     |> refresh_preview()}
  end

  def handle_event("change_preview_post", %{"post_uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:preview_post_uuid, normalize(uuid))
     |> refresh_preview()}
  end

  def handle_event("clear_slot_custom", %{"slot" => slot}, socket) do
    mapping = Map.put(socket.assigns.edit_state.slot_mapping || %{}, slot, "custom:")
    edit_state = Map.put(socket.assigns.edit_state, :slot_mapping, mapping)
    {:noreply, socket |> assign(:edit_state, edit_state) |> refresh_preview()}
  end

  # =========================================================================
  # Save — creates or updates depending on editing_id
  # =========================================================================

  def handle_event("save_edit", _params, socket) do
    st = socket.assigns.edit_state

    cond do
      is_nil(st.template_uuid) ->
        {:noreply, put_flash(socket, :error, Errors.message(:template_missing))}

      st.scope == "group" and is_nil(st.group_uuid) ->
        {:noreply, put_flash(socket, :error, Errors.message(:group_missing))}

      true ->
        do_save(socket, st)
    end
  end

  # =========================================================================
  # Row actions (remove only — edit opens the modal above)
  # =========================================================================

  def handle_event("remove_assignment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.assignments, &(&1.uuid == id)) do
      nil ->
        {:noreply, socket}

      a ->
        case Assignments.clear(a.module_key, a.scope_type, a.scope_uuid, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, gettext("Assignment removed.")) |> load()}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Could not remove the assignment."))
             |> load()}
        end
    end
  end

  # =========================================================================
  # Media picker callbacks (MediaSelectorModal → parent LV)
  # =========================================================================

  @impl true
  def handle_info({:media_selected, file_uuids}, socket) do
    file_uuid = List.first(file_uuids || [])
    slot = socket.assigns.media_slot_target

    if is_binary(file_uuid) and is_binary(slot) do
      mapping =
        Map.put(socket.assigns.edit_state.slot_mapping || %{}, slot, "custom:" <> file_uuid)

      edit_state = Map.put(socket.assigns.edit_state, :slot_mapping, mapping)

      {:noreply,
       socket
       |> assign(:edit_state, edit_state)
       |> close_media_picker()
       |> refresh_preview()}
    else
      {:noreply, close_media_picker(socket)}
    end
  end

  def handle_info({:media_selector_closed}, socket), do: {:noreply, close_media_picker(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[PhoenixKitOG.AssignmentsLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # =========================================================================
  # Save internals
  # =========================================================================

  defp do_save(socket, st) do
    scope_uuid = if st.scope == "default", do: nil, else: st.group_uuid
    opts = actor_opts(socket)

    with {:ok, assignment} <-
           Assignments.set(@consumer, st.scope, scope_uuid, st.template_uuid, opts),
         {:ok, _} <-
           Assignments.update_slot_mapping(assignment, st.slot_mapping || %{}, opts) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Assignment saved."))
       |> assign(:editing_id, nil)
       |> load()}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, Errors.message(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp close_media_picker(socket) do
    socket
    |> assign(:show_media_selector, false)
    |> assign(:media_slot_target, nil)
  end

  # =========================================================================
  # State loading
  # =========================================================================

  defp load(socket) do
    socket
    |> assign(:templates, Templates.list())
    |> assign(:assignments, Assignments.list_for_module(@consumer))
    |> assign(:groups, list_publishing_groups())
    |> assign(:module_variables, Variables.for_module(@consumer))
  end

  # Renders the current template with the current slot mapping using
  # the same pipeline production does. Custom values pass through
  # verbatim (via `Variables.resolve`'s `custom:` handling); wired
  # module-vars are resolved against the picked preview post; unwired
  # slots fall back to friendly placeholders so the preview is always
  # readable.
  defp refresh_preview(socket) do
    st = socket.assigns.edit_state
    template = Enum.find(socket.assigns.templates, &(&1.uuid == st.template_uuid))

    if is_nil(template) do
      socket |> assign(preview_url: nil, preview_error: nil, preview_loading: false)
    else
      canvas = template.canvas
      slots = if is_map(canvas), do: Slots.used(canvas), else: []
      mapping = st.slot_mapping || %{}

      # Look up the picked post so module vars (`post_title`,
      # `post_featured_image`, …) resolve to real data.
      resource =
        Enum.find(
          socket.assigns.preview_posts,
          &(&1[:uuid] == socket.assigns.preview_post_uuid)
        )

      context = %{
        module_key: @consumer,
        resource: resource,
        conn: nil,
        language: socket.assigns[:current_locale] || ""
      }

      wired = Variables.resolve(slots, mapping, context)
      globals = socket.assigns.global_values

      values =
        slots
        |> Enum.reduce(%{}, fn %{name: name, type: type}, acc ->
          cond do
            Map.has_key?(wired, name) -> Map.put(acc, name, wired[name])
            type == :image -> Map.put(acc, name, PhoenixKitOG.Render.Placeholder.data_url())
            true -> Map.put(acc, name, "Sample #{name}")
          end
        end)
        |> Map.merge(globals, fn _k, v1, _v2 -> v1 end)

      # Wrap the template so the render pipeline treats every edit as
      # a fresh input — the cache key hashes the canvas so unchanged
      # renders are instant, but changes get a new URL.
      %PhoenixKitOG.Schemas.Template{} = template
      render_template = %{template | updated_at: DateTime.utc_now()}

      # Render OFF the LV process: refresh_preview fires on EVERY modal
      # field change, and a synchronous rasterize (up to the 5s backend
      # timeout) would freeze the whole modal. cancel_async supersedes an
      # in-flight render so a rapid sequence of changes only completes the
      # last one.
      socket
      |> assign(:preview_loading, true)
      |> cancel_async(:preview)
      |> start_async(:preview, fn ->
        PhoenixKitOG.Render.render_url(render_template, %{values: values})
      end)
    end
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, url}}, socket) do
    {:noreply, assign(socket, preview_url: url, preview_error: nil, preview_loading: false)}
  end

  def handle_async(:preview, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       preview_url: nil,
       preview_error: preview_error_message(reason),
       preview_loading: false
     )}
  end

  def handle_async(:preview, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       preview_url: nil,
       preview_error: preview_error_message({:render_failed, reason}),
       preview_loading: false
     )}
  end

  # Preview errors are a small subset of the atoms `Render.render_url/2`
  # returns. Route the specific one we know about through `Errors`;
  # anything else gets the generic wrapper so no raw tuple leaks into
  # the UI.
  defp preview_error_message(:rasterizer_missing), do: Errors.message(:rasterizer_missing)
  defp preview_error_message(reason), do: Errors.message({:render_failed, reason})

  # Called when the modal opens — picks the preview group + post so
  # something meaningful renders immediately. `preferred_group_uuid`
  # comes from the assignment being edited when scope=group; nil for a
  # fresh new-flow.
  defp auto_pick_preview_source(socket, preferred_group_uuid) do
    groups = socket.assigns.groups

    # Prefer the assignment's own group; else pick the first group
    # that actually has posts (avoids landing on an empty group).
    initial_group =
      if preferred_group_uuid do
        Enum.find(groups, &(&1["uuid"] == preferred_group_uuid))
      else
        Enum.find(groups, fn g -> list_publishing_posts(g["slug"]) != [] end) ||
          List.first(groups)
      end

    slug = initial_group && initial_group["slug"]
    posts = if slug, do: list_publishing_posts(slug), else: []
    post_uuid = pick_default_post_uuid(posts)

    socket
    |> assign(:preview_group_slug, slug)
    |> assign(:preview_posts, posts)
    |> assign(:preview_post_uuid, post_uuid)
  end

  defp list_publishing_posts(nil), do: []

  defp list_publishing_posts(slug) when is_binary(slug) do
    if Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Posts) and
         function_exported?(PhoenixKit.Modules.Publishing.Posts, :list_posts, 1) do
      PhoenixKit.Modules.Publishing.Posts.list_posts(slug)
    else
      []
    end
  rescue
    _ -> []
  end

  # Priority order: first published, then draft, then anything else.
  # `nil` if the group has no posts at all.
  defp pick_default_post_uuid(posts) when is_list(posts) do
    by_status = fn status ->
      Enum.find(posts, fn p -> post_status(p) == status end)
    end

    hit = by_status.("published") || by_status.("draft") || List.first(posts)
    hit && hit[:uuid]
  end

  defp post_status(post) do
    (post[:metadata] && post[:metadata][:status]) ||
      (post[:metadata] && post[:metadata]["status"]) ||
      post[:status] ||
      "unknown"
  end

  defp post_title(post) do
    (post[:metadata] && post[:metadata][:title]) ||
      (post[:metadata] && post[:metadata]["title"]) ||
      post[:title] ||
      post[:slug] ||
      gettext("(untitled)")
  end

  defp list_publishing_groups do
    if Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Groups) and
         function_exported?(PhoenixKit.Modules.Publishing.Groups, :list_groups, 1) do
      PhoenixKit.Modules.Publishing.Groups.list_groups("active")
    else
      []
    end
  rescue
    _ -> []
  end

  defp blank_edit_state do
    %{scope: "default", group_uuid: nil, template_uuid: nil, slot_mapping: %{}}
  end

  defp normalize(""), do: nil
  defp normalize(nil), do: nil
  defp normalize(v) when is_binary(v), do: v

  defp put_or_delete(map, key, "") when is_map(map), do: Map.delete(map, key)
  defp put_or_delete(map, key, value) when is_map(map), do: Map.put(map, key, value)

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-4 py-6 space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("OpenGraph assignments")}</h1>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext(
              "Every template binding is listed below. Most-specific wins — a per-group assignment overrides the module default."
            )}
          </p>
        </div>
        <button
          type="button"
          phx-click="open_new"
          class="btn btn-primary btn-sm"
          disabled={@templates == []}
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" />
          {gettext("Assign template")}
        </button>
      </div>

      <%= if @templates == [] do %>
        <div class="rounded-lg border border-warning/30 bg-warning/5 px-4 py-3 text-sm">
          {gettext("Create a template first on the")}
          <.link navigate={Paths.templates()} class="link link-primary">
            {gettext("Templates")}
          </.link>
          {gettext("page.")}
        </div>
      <% end %>

      <.assignments_list assignments={@assignments} groups={@groups} />

      <.edit_modal
        show={@editing_id != nil}
        is_new={@editing_id == "new"}
        state={@edit_state}
        templates={@templates}
        groups={@groups}
        module_variables={@module_variables}
        preview_url={@preview_url}
        preview_error={@preview_error}
        preview_group_slug={@preview_group_slug}
        preview_posts={@preview_posts}
        preview_post_uuid={@preview_post_uuid}
      />

      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="og-assignments-media-selector-modal"
        show={@show_media_selector}
        mode={@media_selection_mode}
        selected_uuids={@media_selected_uuids}
        file_type_filter={:image}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />
    </div>
    """
  end

  # =========================================================================
  # Overview list
  # =========================================================================

  attr(:assignments, :list, required: true)
  attr(:groups, :list, required: true)

  defp assignments_list(assigns) do
    ~H"""
    <section class="space-y-2">
      <%= if @assignments == [] do %>
        <div class="rounded-lg border border-base-300 bg-base-100 px-4 py-8 text-center">
          <.icon name="hero-arrows-pointing-in" class="w-8 h-8 mx-auto text-base-content/30" />
          <p class="mt-2 text-sm text-base-content/60">
            {gettext("No assignments yet.")}
          </p>
          <p class="text-xs text-base-content/50 mt-1">
            {gettext(~S|Click "Assign template" above to link a template to the module or a group.|)}
          </p>
        </div>
      <% else %>
        <ul class="divide-y divide-base-300 rounded-lg border border-base-300 bg-base-100 overflow-hidden">
          <li :for={a <- @assignments}>
            <.assignment_row assignment={a} groups={@groups} />
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  attr(:assignment, :map, required: true)
  attr(:groups, :list, required: true)

  defp assignment_row(assigns) do
    template = assigns.assignment.template

    slots =
      if template && is_map(template.canvas),
        do: Slots.used(template.canvas),
        else: []

    assigns =
      assigns
      |> assign(:template, template)
      |> assign(:slots, slots)

    ~H"""
    <div class="px-4 py-3 flex items-center justify-between gap-3 hover:bg-base-200/50">
      <div class="flex-1 min-w-0">
        <p class="font-medium truncate">{scope_label(@assignment, @groups)}</p>
        <p class="text-xs text-base-content/60 mt-0.5">
          {gettext("Template:")} <span class="font-medium text-base-content/80">
            {(@template && @template.name) || gettext("(none)")}
          </span>
          <span :if={@slots != []} class="ml-2">
            · {wired_count(@assignment.slot_mapping || %{}, @slots)}/{length(@slots)} {gettext(
              "slots wired"
            )}
          </span>
        </p>
      </div>
      <div class="flex items-center gap-1">
        <button
          type="button"
          phx-click="open_edit"
          phx-value-id={@assignment.uuid}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" /> {gettext("Edit")}
        </button>
        <button
          type="button"
          phx-click="remove_assignment"
          phx-value-id={@assignment.uuid}
          phx-disable-with={gettext("Removing…")}
          data-confirm={gettext("Remove this assignment?")}
          class="btn btn-ghost btn-xs text-error"
          title={gettext("Remove")}
        >
          <.icon name="hero-trash" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  # =========================================================================
  # Edit / new modal
  # =========================================================================

  attr(:show, :boolean, required: true)
  attr(:is_new, :boolean, required: true)
  attr(:state, :map, required: true)
  attr(:templates, :list, required: true)
  attr(:groups, :list, required: true)
  attr(:module_variables, :list, required: true)
  attr(:preview_url, :string, default: nil)
  attr(:preview_error, :string, default: nil)
  attr(:preview_group_slug, :string, default: nil)
  attr(:preview_posts, :list, default: [])
  attr(:preview_post_uuid, :string, default: nil)

  defp edit_modal(assigns) do
    selected_template =
      Enum.find(assigns.templates, &(&1.uuid == assigns.state.template_uuid))

    slots =
      if selected_template && is_map(selected_template.canvas),
        do: Slots.used(selected_template.canvas),
        else: []

    assigns =
      assigns
      |> assign(:selected_template, selected_template)
      |> assign(:slots, slots)

    ~H"""
    <dialog id="og-assign-modal" class={["modal", @show && "modal-open"]} open={@show}>
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between mb-3">
          <div>
            <h3 class="font-bold text-lg">
              {if @is_new, do: gettext("Assign template for…"), else: gettext("Edit assignment")}
            </h3>
            <p class="text-xs text-base-content/60 mt-0.5">
              {gettext(
                "Pick what this assignment applies to, choose a template, and wire its slots — save when you're done."
              )}
            </p>
          </div>
          <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-circle btn-ghost">
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <div class="space-y-3">
          <div>
            <label class="label py-0.5">
              <span class="label-text text-xs font-medium">{gettext("Applies to")}</span>
            </label>
            <form phx-change="edit_change_scope">
              <select name="scope" class="select select-bordered select-sm w-full">
                <option value="default" selected={@state.scope == "default"}>
                  {gettext("Whole Publishing module (default)")}
                </option>
                <option value="group" selected={@state.scope == "group"}>
                  {gettext("A specific Publishing group")}
                </option>
              </select>
            </form>
          </div>

          <div :if={@state.scope == "group"}>
            <label class="label py-0.5">
              <span class="label-text text-xs font-medium">{gettext("Group")}</span>
            </label>
            <form phx-change="edit_change_group">
              <select name="group_uuid" class="select select-bordered select-sm w-full">
                <option value="">{gettext("— pick a group —")}</option>
                <option
                  :for={g <- @groups}
                  value={g["uuid"]}
                  selected={@state.group_uuid == g["uuid"]}
                >
                  {g["name"] || g["slug"]}
                </option>
              </select>
            </form>
            <p :if={@groups == []} class="text-xs text-warning mt-1">
              {gettext("No active publishing groups found.")}
            </p>
          </div>

          <div>
            <label class="label py-0.5">
              <span class="label-text text-xs font-medium">{gettext("Template")}</span>
            </label>
            <form phx-change="edit_change_template">
              <select name="template_uuid" class="select select-bordered select-sm w-full">
                <option value="">{gettext("— pick a template —")}</option>
                <option
                  :for={t <- @templates}
                  value={t.uuid}
                  selected={@state.template_uuid == t.uuid}
                >
                  {t.name}
                </option>
              </select>
            </form>
          </div>

          <.modal_slot_wiring
            :if={@selected_template}
            slots={@slots}
            slot_mapping={@state.slot_mapping || %{}}
            variables={@module_variables}
          />

          <.preview_panel
            :if={@selected_template}
            url={@preview_url}
            error={@preview_error}
            loading={@preview_loading}
            groups={@groups}
            group_slug={@preview_group_slug}
            posts={@preview_posts}
            post_uuid={@preview_post_uuid}
          />
        </div>

        <div class="modal-action">
          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            phx-click="save_edit"
            phx-disable-with={gettext("Saving…")}
            class="btn btn-primary btn-sm"
          >
            {if @is_new, do: gettext("Create assignment"), else: gettext("Save")}
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_edit">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr(:url, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:groups, :list, default: [])
  attr(:group_slug, :string, default: nil)
  attr(:posts, :list, default: [])
  attr(:post_uuid, :string, default: nil)

  defp preview_panel(assigns) do
    ~H"""
    <div class="pt-2 border-t border-base-300">
      <div class="flex items-center justify-between mb-2 gap-2">
        <h4 class="text-xs font-semibold text-base-content/70 uppercase tracking-wide">
          {gettext("Preview")}
        </h4>
        <span class="text-[10px] text-base-content/40">
          {gettext("Pick a real post to preview against its data.")}
        </span>
      </div>

      <div class="grid grid-cols-2 gap-2 mb-2">
        <form phx-change="change_preview_group">
          <label class="label py-0.5">
            <span class="label-text text-[10px] uppercase tracking-wide text-base-content/50">
              {gettext("Group")}
            </span>
          </label>
          <select name="group_slug" class="select select-bordered select-xs w-full">
            <option value="">{gettext("— none —")}</option>
            <option
              :for={g <- @groups}
              value={g["slug"]}
              selected={@group_slug == g["slug"]}
            >
              {g["name"] || g["slug"]}
            </option>
          </select>
        </form>

        <form phx-change="change_preview_post">
          <label class="label py-0.5">
            <span class="label-text text-[10px] uppercase tracking-wide text-base-content/50">
              {gettext("Post")}
            </span>
          </label>
          <select
            name="post_uuid"
            class="select select-bordered select-xs w-full"
            disabled={@posts == []}
          >
            <%= if @posts == [] do %>
              <option value="">{gettext("— no posts in group —")}</option>
            <% else %>
              <option value="">{gettext("— pick a post —")}</option>
              <option
                :for={p <- @posts}
                value={p[:uuid]}
                selected={@post_uuid == p[:uuid]}
              >
                {post_option_label(p)}
              </option>
            <% end %>
          </select>
        </form>
      </div>

      <%= cond do %>
        <% @loading -> %>
          <div class="flex items-center justify-center gap-2 py-6 text-xs text-base-content/50">
            <span class="loading loading-spinner loading-sm"></span>
            <span>{gettext("Rendering…")}</span>
          </div>
        <% @error -> %>
          <div class="rounded-md border border-error/30 bg-error/5 px-3 py-2 text-xs text-error">
            {@error}
          </div>
        <% @url -> %>
          <img
            src={@url}
            alt={gettext("OG preview")}
            class="w-full rounded-lg border-2 border-base-300 shadow-sm"
            loading="lazy"
          />
          <p class="text-xs text-base-content/50 mt-1">
            {gettext(
              "Wired variables resolve against the selected post; custom values pass through verbatim; unwired image slots get a stand-in."
            )}
          </p>
        <% true -> %>
          <div class="rounded-md border border-base-300 bg-base-200/50 px-3 py-6 text-center text-xs text-base-content/50">
            {gettext("Preview appears once a template is selected.")}
          </div>
      <% end %>
    </div>
    """
  end

  defp post_option_label(post) do
    status = post_status(post)
    title = post_title(post)

    badge =
      case status do
        "published" -> ""
        "draft" -> " " <> gettext("(draft)")
        other when is_binary(other) -> " (#{other})"
        _ -> ""
      end

    "#{title}#{badge}"
  end

  attr(:slots, :list, required: true)
  attr(:slot_mapping, :map, required: true)
  attr(:variables, :list, required: true)

  defp modal_slot_wiring(assigns) do
    ~H"""
    <div class="pt-2 border-t border-base-300">
      <h4 class="text-xs font-semibold text-base-content/70 uppercase tracking-wide mb-2">
        {gettext("Wire template slots")}
      </h4>
      <%= if @slots == [] do %>
        <p class="text-xs text-base-content/50">
          {gettext(~S|This template has no {{slots}} — nothing to wire.|)}
        </p>
      <% else %>
        <ul class="space-y-2">
          <li :for={slot <- @slots}>
            <.slot_row
              slot={slot}
              value={Map.get(@slot_mapping, slot.name)}
              variables={compatible_variables(@variables, slot.type)}
            />
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  # One row per template slot. Grid columns give every row the same
  # label width so the arrows line up regardless of slot-name length.
  attr(:slot, :map, required: true)
  attr(:value, :string, default: nil)
  attr(:variables, :list, required: true)

  defp slot_row(assigns) do
    is_custom = is_binary(assigns.value) and String.starts_with?(assigns.value, "custom:")
    custom_value = if is_custom, do: String.replace_prefix(assigns.value, "custom:", ""), else: ""

    dropdown_value =
      cond do
        is_binary(assigns.value) and String.starts_with?(assigns.value, "custom:") -> "__custom__"
        is_binary(assigns.value) -> assigns.value
        true -> ""
      end

    assigns =
      assigns
      |> assign(:is_custom, is_custom)
      |> assign(:custom_value, custom_value)
      |> assign(:dropdown_value, dropdown_value)

    ~H"""
    <div class="grid grid-cols-[10rem_auto_1fr] items-start gap-2">
      <span class="badge badge-outline gap-1 justify-start truncate mt-1">
        <span class="text-xs text-base-content/50">{slot_type_label(@slot.type)}</span>
        <span class="font-mono text-xs truncate">{@slot.name}</span>
      </span>
      <span class="text-base-content/40 mt-1.5">→</span>
      <div class="space-y-1">
        <form phx-change="edit_wire_slot">
          <input type="hidden" name="slot" value={@slot.name} />
          <select name="variable" class="select select-bordered select-sm w-full">
            <option value="">{gettext("— Not wired —")}</option>
            <optgroup label={gettext("Variables")}>
              <option
                :for={v <- @variables}
                value={v.name}
                selected={@dropdown_value == v.name}
              >
                {PhoenixKitOG.Variables.global_label(v.name) || v.label}
              </option>
            </optgroup>
            <option value="__custom__" selected={@is_custom}>
              {if @slot.type == :image,
                do: gettext("Custom (paste a URL or pick a media file)"),
                else: gettext("Custom text…")}
            </option>
          </select>
        </form>

        <%= if @is_custom do %>
          <%= if @slot.type == :image do %>
            <.slot_custom_media slot={@slot.name} value={@custom_value} />
          <% else %>
            <form phx-change="edit_wire_slot_custom">
              <input type="hidden" name="slot" value={@slot.name} />
              <input
                type="text"
                name="value"
                value={@custom_value}
                phx-debounce="200"
                placeholder={gettext("Literal text (or {{name}} / [[name]])")}
                class="input input-bordered input-sm w-full font-mono text-xs"
              />
            </form>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:slot, :string, required: true)
  attr(:value, :string, default: "")

  defp slot_custom_media(assigns) do
    preview =
      case assigns.value do
        "" -> nil
        nil -> nil
        v -> media_preview_url(v)
      end

    assigns = assign(assigns, :preview, preview)

    ~H"""
    <div class="space-y-1">
      <%= if @preview do %>
        <img
          src={@preview}
          alt=""
          class="w-full max-h-24 object-contain rounded border border-base-300"
          loading="lazy"
        />
      <% end %>
      <div class="flex items-center gap-1">
        <form phx-change="edit_wire_slot_custom" class="flex-1">
          <input type="hidden" name="slot" value={@slot} />
          <input
            type="text"
            name="value"
            value={@value}
            phx-debounce="200"
            placeholder={gettext("Media UUID or URL")}
            class="input input-bordered input-sm w-full font-mono text-xs"
          />
        </form>
        <button
          type="button"
          phx-click="open_slot_media_picker"
          phx-value-slot={@slot}
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-photo" class="w-3 h-3 mr-1" /> {gettext("Choose")}
        </button>
        <button
          :if={@value != ""}
          type="button"
          phx-click="clear_slot_custom"
          phx-value-slot={@slot}
          class="btn btn-ghost btn-sm text-error"
          title={gettext("Clear")}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  # Reuses the storage helper publishing's editor uses so the assignments
  # UI shows the same thumbnails as the rest of the admin.
  defp media_preview_url(nil), do: nil
  defp media_preview_url(""), do: nil
  defp media_preview_url("http://" <> _ = url), do: url
  defp media_preview_url("https://" <> _ = url), do: url
  defp media_preview_url("/" <> _ = url), do: url
  defp media_preview_url("data:" <> _ = url), do: url

  defp media_preview_url(uuid) when is_binary(uuid) do
    PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid, "medium") ||
      PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid)
  rescue
    _ -> nil
  end

  defp media_preview_url(_), do: nil

  # =========================================================================
  # Helpers
  # =========================================================================

  defp scope_label(%{scope_type: "default"}, _groups),
    do: gettext("Whole Publishing module (default)")

  defp scope_label(%{scope_type: "group", scope_uuid: uuid}, groups) do
    case Enum.find(groups, &(&1["uuid"] == uuid)) do
      %{"name" => name} when is_binary(name) and name != "" ->
        gettext("Group: %{name}", name: name)

      %{"slug" => slug} when is_binary(slug) ->
        gettext("Group: %{name}", name: slug)

      _ ->
        gettext("Group: %{name}", name: uuid || "?")
    end
  end

  defp scope_label(%{scope_type: type, scope_uuid: uuid}, _groups),
    do: "#{type}: #{uuid || "—"}"

  defp wired_count(mapping, slots) do
    slot_names = Enum.map(slots, & &1.name) |> MapSet.new()

    mapping
    |> Map.keys()
    |> Enum.count(&MapSet.member?(slot_names, &1))
  end

  defp compatible_variables(variables, slot_type) do
    Enum.filter(variables, &(&1.type == slot_type))
  end

  defp slot_type_label(:text), do: "T"
  defp slot_type_label(:image), do: "\u{1F5BC}"
  defp slot_type_label(_), do: "?"
end
