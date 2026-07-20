defmodule PhoenixKitOG.Web.EditorLive do
  @moduledoc """
  The OG template editor — WYSIWYG SVG canvas on the left, element
  library + property panel on the right.

  ## Interaction model

  - **Click element** on canvas → select (sets `:selected_id`).
  - **Click empty canvas** → deselect.
  - **Add buttons** in the toolbar push elements at default positions.
  - **Drag**: handled by the `PhoenixKitOGCanvas` JS hook (inline
    `<script>`, registered on `window.PhoenixKitHooks`). During drag the
    hook applies an SVG transform locally and only pushes a final
    `move_element` event on pointer-up — so we don't roundtrip on every
    pixel.
  - **Resize**: 8 corner/edge handles around the selected element.
    Same hook handles the pointer math.
  - **Keyboard**: arrows nudge by 1px (10px with Shift); `Delete`
    removes the selection; `Escape` deselects; `Ctrl+S` saves.
  - **Bindings dropdown**: text elements expose a binding picker in the
    property panel. Selecting one writes the token (e.g. `{post.title}`)
    into the `binding` field; preview mode substitutes its example.

  ## Save semantics

  Changes are autosaved on a 800ms debounce. Manual save via `Ctrl+S`
  or the "Save" button flushes immediately. A header pill shows
  saved / saving / unsaved state.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitOG.Gettext

  # Sets up the file-upload allowlist + `validate` event stub + parent
  # `handle_info` delegator for MediaSelectorModal to work. Zero
  # boilerplate on our side.
  use PhoenixKitWeb.Components.MediaBrowser.Embed

  require Logger

  alias PhoenixKitOG.{Canvas, Errors, Paths, Slots, Templates, Variables}
  alias PhoenixKitOG.Schemas.Template

  @impl true
  def mount(params, _session, socket) do
    case load_or_create_template(params, socket.assigns.live_action, socket) do
      {:ok, template} ->
        canvas = ensure_canvas(template.canvas)

        {:ok,
         socket
         |> assign(
           :page_title,
           gettext("OpenGraph — %{name}", name: template.name || gettext("Editor"))
         )
         |> assign(:template, template)
         |> assign(:canvas, canvas)
         |> assign(:selected_id, nil)
         |> assign(:slots, Slots.used(canvas))
         |> assign(:preview?, false)
         |> assign(:show_preview_modal, false)
         |> assign(:preview_url, nil)
         |> assign(:preview_error, nil)
         |> assign(:preview_loading, false)
         |> assign(:save_state, :saved)
         |> assign(:autosave_timer, nil)
         |> assign(:show_media_selector, false)
         |> assign(:media_selection_mode, :single)
         |> assign(:media_selected_uuids, [])
         |> assign(:media_selector_target, nil)
         |> assign(
           :global_values,
           Variables.global_values(%{
             endpoint: socket.endpoint,
             language: socket.assigns[:current_locale] || ""
           })
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, Errors.message(:not_found))
         |> push_navigate(to: Paths.templates())}
    end
  end

  # =========================================================================
  # Events — toolbar / element library
  # =========================================================================

  @impl true
  def handle_event("insert", %{"kind" => kind}, socket) do
    element = Canvas.default_element(kind, socket.assigns.canvas)
    {canvas, _} = Canvas.add_element(socket.assigns.canvas, element)

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> assign(:selected_id, element["id"])
     |> mark_dirty()}
  end

  def handle_event("update_canvas", %{"field" => field, "value" => value}, socket) do
    canvas = Canvas.update_canvas_field(socket.assigns.canvas, field, value)

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  # =========================================================================
  # Media picker — opens the shared MediaSelectorModal for a field.
  #
  # `target` says where the picked UUID should land:
  #   - "background_value" → canvas.background.value
  #   - "element_src"      → the currently selected element's `src`
  # =========================================================================

  def handle_event("open_media_picker", %{"target" => target}, socket) do
    {:noreply,
     socket
     |> assign(:media_selector_target, target)
     |> assign(:show_media_selector, true)}
  end

  def handle_event("clear_media_field", %{"target" => "background_value"}, socket) do
    canvas = Canvas.update_canvas_field(socket.assigns.canvas, "background_value", "")

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  def handle_event("clear_media_field", %{"target" => "element_src"}, socket) do
    case socket.assigns.selected_id do
      nil ->
        {:noreply, socket}

      id ->
        canvas = Canvas.update_element(socket.assigns.canvas, id, "src", "")

        {:noreply,
         socket
         |> assign(:canvas, canvas)
         |> mark_dirty()}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, assign(socket, :selected_id, nil)}
  end

  def handle_event("delete_selected", _params, socket) do
    case socket.assigns.selected_id do
      nil ->
        {:noreply, socket}

      id ->
        {:noreply,
         socket
         |> assign(:canvas, Canvas.delete_elements(socket.assigns.canvas, [id]))
         |> assign(:selected_id, nil)
         |> mark_dirty()}
    end
  end

  def handle_event("bring_to_front", _params, socket) do
    if id = socket.assigns.selected_id do
      {:noreply,
       socket
       |> assign(:canvas, Canvas.bring_to_front(socket.assigns.canvas, id))
       |> mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_to_back", _params, socket) do
    if id = socket.assigns.selected_id do
      {:noreply,
       socket
       |> assign(:canvas, Canvas.send_to_back(socket.assigns.canvas, id))
       |> mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, assign(socket, :preview?, !socket.assigns.preview?)}
  end

  # Preview button — renders the CURRENT canvas (with in-memory edits,
  # not the last-saved template) through the PNG pipeline and opens a
  # modal with social-card mockups.
  def handle_event("open_preview", _params, socket) do
    %PhoenixKitOG.Schemas.Template{} = base_template = socket.assigns.template

    template = %{
      base_template
      | canvas: socket.assigns.canvas,
        updated_at: DateTime.utc_now()
    }

    values =
      Map.merge(
        socket.assigns.global_values,
        placeholder_slot_values(socket.assigns.slots)
      )

    # Rasterization can take up to the 5s backend timeout — run it OFF
    # the LiveView process so the modal opens instantly with a spinner
    # instead of blocking every other event on this socket. cancel_async
    # supersedes any in-flight render (rapid re-clicks don't queue).
    {:noreply,
     socket
     |> assign(
       show_preview_modal: true,
       preview_loading: true,
       preview_url: nil,
       preview_error: nil
     )
     |> cancel_async(:preview)
     |> start_async(:preview, fn ->
       PhoenixKitOG.Render.render_url(template, %{values: values})
     end)}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :show_preview_modal, false)}
  end

  # =========================================================================
  # Events — property panel
  # =========================================================================

  # phx-change variant: forms in the property panel carry `el_id`, `field`,
  # and `value` as hidden+visible inputs. The hidden field name is `el_id`
  # (not `id`) so the HTML form element id doesn't get clobbered.
  def handle_event(
        "update_prop",
        %{"el_id" => id, "field" => field, "value" => value},
        socket
      ) do
    canvas = Canvas.update_element(socket.assigns.canvas, id, field, value)

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  # Variable-name variant — the property panel shows the bare `name`
  # inside static `{{` / `}}` decorations; this wraps the typed value
  # into the canonical slot syntax before writing.
  def handle_event(
        "update_prop_variable",
        %{"el_id" => id, "field" => field, "value" => value},
        socket
      ) do
    wrapped = if value == "", do: "", else: "{{#{String.trim(value)}}}"
    canvas = Canvas.update_element(socket.assigns.canvas, id, field, wrapped)

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  # Image-source mode toggle in the property panel. Constant clears the
  # slot value so the media picker reappears; Variable seeds a fresh
  # `{{ImageN}}` slot name using `next_slot_name` so we don't collide
  # with an existing slot.
  def handle_event("set_image_mode", %{"el_id" => id, "mode" => "constant"}, socket) do
    canvas = Canvas.update_element(socket.assigns.canvas, id, "src", "")

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  def handle_event("set_image_mode", %{"el_id" => id, "mode" => "variable"}, socket) do
    name = Canvas.next_slot_name(socket.assigns.canvas, "Image")
    canvas = Canvas.update_element(socket.assigns.canvas, id, "src", "{{#{name}}}")

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  def handle_event("update_template_name", %{"name" => name}, socket) do
    template = socket.assigns.template

    case Templates.update(template, %{"name" => name}, actor_opts(socket)) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:page_title, gettext("OpenGraph — %{name}", name: template.name))}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, gettext("Could not rename template."))}
    end
  end

  # =========================================================================
  # Events — from JS hook (drag / resize finalized)
  # =========================================================================

  # Drag end → JS hook pushes the final {x, y} delta applied to the
  # selected element(s). We do the clamp here so the canvas store is
  # authoritative.
  def handle_event("move_element", %{"id" => id, "dx" => dx, "dy" => dy}, socket) do
    canvas = Canvas.move_elements(socket.assigns.canvas, [id], to_number(dx), to_number(dy))

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  # Resize end → JS hook pushes the final {x, y, width, height}.
  # Update width/height BEFORE x/y — the x-clamp reads element width
  # to compute the max-x bound, so applying old width there would let
  # a resize that shrinks the element leave x pinned to an old
  # constraint.
  def handle_event("resize_element", %{"id" => id} = params, socket) do
    canvas =
      socket.assigns.canvas
      |> Canvas.update_element(id, "width", params["width"])
      |> Canvas.update_element(id, "height", params["height"])
      |> Canvas.update_element(id, "x", params["x"])
      |> Canvas.update_element(id, "y", params["y"])

    {:noreply,
     socket
     |> assign(:canvas, canvas)
     |> mark_dirty()}
  end

  # =========================================================================
  # Events — keyboard
  # =========================================================================

  def handle_event("nudge", %{"key" => key, "shift" => shift?}, socket) do
    case socket.assigns.selected_id do
      nil ->
        {:noreply, socket}

      id ->
        step = if shift?, do: 10, else: 1
        {dx, dy} = nudge_delta(key, step)

        canvas = Canvas.move_elements(socket.assigns.canvas, [id], dx, dy)

        {:noreply,
         socket
         |> assign(:canvas, canvas)
         |> mark_dirty()}
    end
  end

  def handle_event("save_now", _params, socket), do: do_save(socket)

  # =========================================================================
  # Autosave plumbing
  # =========================================================================

  @impl true
  def handle_info(:autosave, socket), do: do_save(socket)

  # MediaSelectorModal → parent: user confirmed a selection.
  def handle_info({:media_selected, file_uuids}, socket) do
    file_uuid = List.first(file_uuids || [])
    target = socket.assigns.media_selector_target

    cond do
      is_nil(file_uuid) or is_nil(target) ->
        {:noreply, close_media_selector(socket)}

      target == "background_value" ->
        canvas =
          Canvas.update_canvas_field(socket.assigns.canvas, "background_value", file_uuid)

        {:noreply,
         socket
         |> assign(:canvas, canvas)
         |> close_media_selector()
         |> mark_dirty()}

      target == "element_src" and is_binary(socket.assigns.selected_id) ->
        canvas =
          Canvas.update_element(
            socket.assigns.canvas,
            socket.assigns.selected_id,
            "src",
            file_uuid
          )

        {:noreply,
         socket
         |> assign(:canvas, canvas)
         |> close_media_selector()
         |> mark_dirty()}

      true ->
        {:noreply, close_media_selector(socket)}
    end
  end

  def handle_info({:media_selector_closed}, socket), do: {:noreply, close_media_selector(socket)}

  # Catch-all: this LV arms an :autosave timer and attaches MediaBrowser
  # hooks, so a late/stray message must not crash it with FunctionClauseError.
  def handle_info(msg, socket) do
    Logger.debug("[PhoenixKitOG.EditorLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
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
       preview_error: preview_error_message({:render_crashed, reason}),
       preview_loading: false
     )}
  end

  # =========================================================================
  # Preview helpers
  # =========================================================================

  # Placeholder values so unwired slots don't render as `{{name}}` in
  # the preview. Text slots get `"Sample <name>"`; image slots point
  # at the shared stand-in graphic (light-gray square with corner
  # arrows) so the layout is legible before any wiring.
  defp placeholder_slot_values(slots) do
    stand_in = PhoenixKitOG.Render.Placeholder.data_url()

    Enum.reduce(slots, %{}, fn
      %{name: name, type: :text}, acc -> Map.put(acc, name, "Sample #{name}")
      %{name: name, type: :image}, acc -> Map.put(acc, name, stand_in)
      _, acc -> acc
    end)
  end

  # Preview errors flow through `Errors.message/1` so the copy stays
  # aligned with the rest of the UI. Route the known atom through the
  # dispatcher; anything else gets the generic wrapper so a raw tuple
  # never leaks into the modal.
  defp preview_error_message(:rasterizer_missing), do: Errors.message(:rasterizer_missing)
  defp preview_error_message(reason), do: Errors.message({:render_failed, reason})

  defp close_media_selector(socket) do
    socket
    |> assign(:show_media_selector, false)
    |> assign(:media_selector_target, nil)
  end

  defp do_save(socket) do
    if socket.assigns.autosave_timer, do: Process.cancel_timer(socket.assigns.autosave_timer)

    case Templates.update(
           socket.assigns.template,
           %{"canvas" => socket.assigns.canvas},
           # Autosaves happen on a timer, not a user click — mark them
           # `mode: "auto"` in the activity feed so manual saves stay
           # distinguishable.
           Keyword.put(actor_opts(socket), :mode, "auto")
         ) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:save_state, :saved)
         |> assign(:autosave_timer, nil)}

      {:error, _cs} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Save failed — please retry."))
         |> assign(:save_state, :error)}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp mark_dirty(socket) do
    if socket.assigns.autosave_timer, do: Process.cancel_timer(socket.assigns.autosave_timer)
    timer = Process.send_after(self(), :autosave, 800)

    socket
    |> assign(:save_state, :dirty)
    |> assign(:autosave_timer, timer)
    |> assign(:slots, Slots.used(socket.assigns.canvas))
  end

  # =========================================================================
  # Loading
  # =========================================================================

  # `mount/3` runs once for the disconnected (static HTML) render and
  # again for the connected (WebSocket) render. Only create the row on
  # the connected pass — otherwise every fresh visit to `/new` (a full
  # page load, not a `push_navigate` from an already-connected LV)
  # leaves an orphaned blank template behind from the disconnected
  # render nobody ever sees.
  defp load_or_create_template(_params, :new, socket) do
    if connected?(socket) do
      name = "Untitled #{System.unique_integer([:positive])}"
      # The actor is threaded later on the first save. Activity feed
      # shows an anonymous `template.created` for the initial insert.
      Templates.create(%{"name" => name, "canvas" => Canvas.blank()})
    else
      {:ok, %Template{canvas: Canvas.blank()}}
    end
  end

  defp load_or_create_template(%{"uuid" => uuid}, :edit, _socket) do
    case Templates.get(uuid) do
      nil -> {:error, :not_found}
      %Template{} = t -> {:ok, t}
    end
  end

  defp ensure_canvas(canvas) when is_map(canvas) and map_size(canvas) > 0, do: canvas
  defp ensure_canvas(_), do: Canvas.blank()

  defp nudge_delta("ArrowLeft", step), do: {-step, 0}
  defp nudge_delta("ArrowRight", step), do: {step, 0}
  defp nudge_delta("ArrowUp", step), do: {0, -step}
  defp nudge_delta("ArrowDown", step), do: {0, step}
  defp nudge_delta(_, _), do: {0, 0}

  defp to_number(v) when is_number(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  # =========================================================================
  # Render — delegated to a colocated template for sanity
  # =========================================================================

  @impl true
  def render(assigns) do
    PhoenixKitOG.Web.EditorLive.Template.render(assigns)
  end
end
