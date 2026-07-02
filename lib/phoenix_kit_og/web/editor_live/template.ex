defmodule PhoenixKitOg.Web.EditorLive.Template do
  @moduledoc """
  HEEx render template for the OG editor. Split out from the LV module
  so the event-handler code stays scannable.

  The layout is:

      ┌───────────────────────────────────────────────────┐
      │  Toolbar: name | save state | add buttons | save   │
      ├──────────────────────────────┬────────────────────┤
      │                              │  Element library   │
      │       SVG canvas (1200×630)  │  Selected props    │
      │       — drag, select, etc.   │  Bindings dropdown │
      │                              │  Z-order controls  │
      └──────────────────────────────┴────────────────────┘
  """

  use PhoenixKitWeb, :html

  alias Phoenix.LiveView.JS
  alias PhoenixKitOg.{Canvas, Paths}

  # Canvas displays at 75% of intrinsic in the layout. The SVG itself
  # carries the 1200×630 viewBox so the JS hook can convert client
  # pointer coords to canvas units regardless of CSS scale.
  @display_scale 0.6

  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:elements, fn -> Canvas.elements(assigns.canvas) end)
      |> assign_new(:selected, fn ->
        assigns.selected_id && Canvas.get_element(assigns.canvas, assigns.selected_id)
      end)
      |> assign(:display_scale, @display_scale)

    ~H"""
    <div
      id="phoenix-kit-og-editor"
      phx-hook="PhoenixKitOgEditor"
      phx-window-keydown="nudge"
      phx-key="ArrowUp"
      class="w-full h-[calc(100vh-8rem)] flex flex-col bg-base-200"
    >
      <.toolbar
        template={@template}
        save_state={@save_state}
        preview?={@preview?}
        selected={@selected}
      />

      <div class="flex-1 flex overflow-hidden">
        <.canvas_pane
          canvas={@canvas}
          elements={@elements}
          selected_id={@selected_id}
          preview?={@preview?}
          display_scale={@display_scale}
          global_values={@global_values}
        />

        <.right_panel selected={@selected} slots={@slots} canvas={@canvas} />
      </div>

      <.editor_hook_script />

      <%!-- Media picker modal (shared with the publishing editor pattern):
           when open, hosts the full MediaBrowser inside a modal; user
           confirms → parent gets {:media_selected, [uuid]}. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="og-media-selector-modal"
        show={@show_media_selector}
        mode={@media_selection_mode}
        selected_uuids={@media_selected_uuids}
        file_type_filter={:image}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.preview_modal
        show={@show_preview_modal}
        url={@preview_url}
        error={@preview_error}
        global_values={@global_values}
      />
    </div>
    """
  end

  # =========================================================================
  # Preview modal — renders the current template as a PNG and embeds it
  # in mockups of the popular platforms.
  # =========================================================================
  attr :show, :boolean, required: true
  attr :url, :string, default: nil
  attr :error, :string, default: nil
  attr :global_values, :map, required: true

  defp preview_modal(assigns) do
    assigns =
      assigns
      |> assign_new(:site_host, fn -> Map.get(assigns.global_values, "site_host", "example.com") end)
      |> assign_new(:site_name, fn -> Map.get(assigns.global_values, "site_name", "Example Site") end)
      |> assign_new(:sample_title, fn -> "Sample Post Title" end)
      |> assign_new(:sample_desc, fn ->
        "This is a sample post description — the way readers will see the intro before they click through."
      end)

    ~H"""
    <dialog id="og-preview-modal" class={["modal", @show && "modal-open"]} open={@show}>
      <div class="modal-box max-w-5xl w-full">
        <div class="flex items-start justify-between mb-3">
          <div>
            <h3 class="font-bold text-lg">{gettext("Social card preview")}</h3>
            <p class="text-xs text-base-content/60 mt-0.5">
              {gettext(
                "How this template will appear when shared. Slot values here are placeholder previews — real posts substitute their own values at render time."
              )}
            </p>
          </div>
          <button type="button" phx-click="close_preview" class="btn btn-sm btn-circle btn-ghost">
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <%= if @error do %>
          <div class="rounded-md border border-error/30 bg-error/5 px-4 py-3 text-sm text-error">
            {@error}
          </div>
        <% end %>

        <%= if @url do %>
          <div class="space-y-4">
            <%!-- Raw rendered image --%>
            <details class="rounded-lg border border-base-300 bg-base-200/50" open>
              <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium">
                {gettext("Rendered image (1200 × 630)")}
              </summary>
              <div class="p-3">
                <img
                  src={@url}
                  alt="OG preview"
                  class="w-full rounded border border-base-300 shadow-sm"
                  loading="lazy"
                />
              </div>
            </details>

            <%!-- Platform mockups --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.platform_card
                platform="Facebook"
                :let={_}
              >
                <.fb_card
                  image={@url}
                  title={@sample_title}
                  description={@sample_desc}
                  host={@site_host}
                />
              </.platform_card>

              <.platform_card platform="X (Twitter)" :let={_}>
                <.twitter_card
                  image={@url}
                  title={@sample_title}
                  description={@sample_desc}
                  host={@site_host}
                />
              </.platform_card>

              <.platform_card platform="LinkedIn" :let={_}>
                <.linkedin_card
                  image={@url}
                  title={@sample_title}
                  description={@sample_desc}
                  host={@site_host}
                />
              </.platform_card>

              <.platform_card platform="Discord / Slack" :let={_}>
                <.discord_card
                  image={@url}
                  title={@sample_title}
                  description={@sample_desc}
                  host={@site_host}
                  site_name={@site_name}
                />
              </.platform_card>
            </div>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_preview">{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  attr :platform, :string, required: true
  slot :inner_block, required: true

  defp platform_card(assigns) do
    ~H"""
    <div class="space-y-2">
      <p class="text-xs font-semibold text-base-content/70 uppercase tracking-wide">{@platform}</p>
      <div class="rounded-lg border border-base-300 bg-base-100 overflow-hidden">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Facebook desktop link card — big image, then title/description/host
  # in a subdued strip below.
  attr :image, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :host, :string, required: true

  defp fb_card(assigns) do
    ~H"""
    <div>
      <img src={@image} alt="" class="w-full aspect-[1.91/1] object-cover" />
      <div class="bg-[#f0f2f5] px-3 py-2 border-t border-base-300">
        <p class="text-[10px] uppercase text-neutral-500 truncate">{@host}</p>
        <p class="text-sm font-semibold text-neutral-900 leading-snug line-clamp-2">{@title}</p>
        <p class="text-xs text-neutral-500 leading-snug line-clamp-2 mt-0.5">{@description}</p>
      </div>
    </div>
    """
  end

  attr :image, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :host, :string, required: true

  defp twitter_card(assigns) do
    ~H"""
    <div class="border border-neutral-300 rounded-2xl overflow-hidden">
      <img src={@image} alt="" class="w-full aspect-[1.91/1] object-cover" />
      <div class="bg-white px-3 py-2 border-t border-neutral-200">
        <p class="text-xs text-neutral-500">{@host}</p>
        <p class="text-sm text-neutral-900 leading-snug line-clamp-2">{@title}</p>
      </div>
    </div>
    """
  end

  attr :image, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :host, :string, required: true

  defp linkedin_card(assigns) do
    ~H"""
    <div>
      <img src={@image} alt="" class="w-full aspect-[1.91/1] object-cover" />
      <div class="bg-white px-3 py-2 border-t border-neutral-200">
        <p class="text-sm font-semibold text-neutral-900 leading-snug line-clamp-2">{@title}</p>
        <p class="text-xs text-neutral-500 mt-1 truncate">{@host}</p>
      </div>
    </div>
    """
  end

  attr :image, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :host, :string, required: true
  attr :site_name, :string, required: true

  defp discord_card(assigns) do
    ~H"""
    <div class="bg-[#2b2d31] p-3 border-l-4 border-l-[#5865f2]">
      <p class="text-[11px] text-[#f2f3f5]/70">{@site_name}</p>
      <p class="text-sm text-[#00a8fc] font-semibold leading-snug line-clamp-1 mt-0.5">{@title}</p>
      <p class="text-xs text-[#dbdee1] mt-1 line-clamp-3">{@description}</p>
      <img src={@image} alt="" class="w-full rounded mt-2 aspect-[1.91/1] object-cover" />
    </div>
    """
  end

  # =========================================================================
  # Toolbar
  # =========================================================================

  defp toolbar(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4 px-4 py-2 bg-base-100 border-b border-base-300">
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <.link navigate={Paths.templates()} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" />
        </.link>
        <form phx-change="update_template_name" class="flex-1 min-w-0">
          <input
            type="text"
            name="name"
            value={@template.name}
            class="input input-ghost input-sm w-full font-semibold text-base"
            placeholder={gettext("Untitled template")}
          />
        </form>
        <.save_pill state={@save_state} />
      </div>

      <div class="flex items-center gap-1">
        <.insert_menu />

        <div class="divider divider-horizontal mx-0" />

        <button
          type="button"
          phx-click="open_preview"
          class="btn btn-ghost btn-sm"
          title={gettext("Preview in social cards")}
        >
          <.icon name="hero-eye" class="w-4 h-4 mr-1" />
          {gettext("Preview")}
        </button>

        <button
          type="button"
          phx-click="save_now"
          phx-disable-with={gettext("Saving…")}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-bookmark" class="w-4 h-4 mr-1" /> {gettext("Save")}
        </button>
      </div>
    </header>
    """
  end

  # ==============================================================
  # Insert dropdown — replaces the flat toolbar buttons. Grouped so
  # the "static vs variable" split is one click away for each element
  # kind. Wraps `<details class="dropdown">` so it closes on outside
  # click automatically; each item pushes the insert event and removes
  # the `open` attribute so the menu collapses.
  # ==============================================================
  defp insert_menu(assigns) do
    ~H"""
    <details
      id="insert-menu"
      class="dropdown"
      phx-click-away={JS.remove_attribute("open", to: "#insert-menu")}
    >
      <summary class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Insert…")}
      </summary>
      <ul class="dropdown-content menu bg-base-100 rounded-box shadow-lg z-10 w-64 p-2 mt-1">
        <li class="menu-title">
          <span>{gettext("Text")}</span>
        </li>
        <li>
          <a phx-click={insert_and_close("text")}>
            <.icon name="hero-bars-3-bottom-left" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Static text")}</div>
              <div class="text-xs text-base-content/50">
                {gettext("You type the content.")}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("text_var")}>
            <.icon name="hero-variable" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Text variable")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|A {{TextN}} slot to wire later.|)}
              </div>
            </div>
          </a>
        </li>

        <li class="menu-title mt-1">
          <span>{gettext("Image")}</span>
        </li>
        <li>
          <a phx-click={insert_and_close("image")}>
            <.icon name="hero-photo" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Static image")}</div>
              <div class="text-xs text-base-content/50">
                {gettext("Paste a media UUID or URL.")}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("image_var")}>
            <.icon name="hero-variable" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Image variable")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|An {{ImageN}} slot to wire later.|)}
              </div>
            </div>
          </a>
        </li>

        <li class="menu-title mt-1">
          <span>{gettext("Shape")}</span>
        </li>
        <li>
          <a phx-click={insert_and_close("rect")}>
            <.icon name="hero-rectangle-group" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Rectangle")}</div>
              <div class="text-xs text-base-content/50">
                {gettext("Solid fill, optional stroke, rounded corners.")}
              </div>
            </div>
          </a>
        </li>

        <li class="menu-title mt-1">
          <span>{gettext("Website")}</span>
        </li>
        <li>
          <a phx-click={insert_and_close("global:site_url")}>
            <.icon name="hero-globe-alt" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Site URL")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|Auto-fills from the site config — no wiring needed.|)}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("global:site_host")}>
            <.icon name="hero-server" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Site host")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|Pre-filled with {{site_host}}.|)}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("global:site_name")}>
            <.icon name="hero-identification" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Site name")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|Pre-filled with {{site_name}}.|)}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("global:page_url")}>
            <.icon name="hero-link" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Page URL")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|Pre-filled with {{page_url}} — the URL of the post/page.|)}
              </div>
            </div>
          </a>
        </li>
        <li>
          <a phx-click={insert_and_close("global:page_locale")}>
            <.icon name="hero-language" class="w-4 h-4" />
            <div class="flex-1">
              <div>{gettext("Page locale")}</div>
              <div class="text-xs text-base-content/50">
                {gettext(~S|Pre-filled with {{page_locale}}.|)}
              </div>
            </div>
          </a>
        </li>
      </ul>
    </details>
    """
  end

  # Pushes the insert event AND removes the details `open` attribute so
  # the dropdown collapses back after the click.
  defp insert_and_close(kind) do
    JS.push("insert", value: %{"kind" => kind})
    |> JS.remove_attribute("open", to: "#insert-menu")
  end

  defp save_pill(assigns) do
    {label, class} =
      case assigns.state do
        :saved -> {"Saved", "text-success"}
        :dirty -> {"Unsaved changes", "text-warning"}
        :saving -> {"Saving…", "text-info"}
        :error -> {"Save failed", "text-error"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:class, class)

    ~H"""
    <span class={["text-xs font-medium", @class]}>{@label}</span>
    """
  end

  # =========================================================================
  # Canvas pane (left)
  # =========================================================================

  defp canvas_pane(assigns) do
    assigns =
      assigns
      |> assign(:canvas_width, Map.get(assigns.canvas, "width", 1200))
      |> assign(:canvas_height, Map.get(assigns.canvas, "height", 630))
      |> assign(:background, Map.get(assigns.canvas, "background", %{}))

    ~H"""
    <main class="flex-1 overflow-auto bg-base-200 p-8 flex flex-col items-center gap-4">
      <%!-- Editor is JS-driven — no drag, no resize, no keyboard shortcuts
           without it. Show a persistent warning when the hook hasn't set
           `data-pk-og-hook-ready="true"` on the wrapper (either JS
           disabled, the bundle didn't load, or the hook errored on
           mount). Also cover the classic no-JS case with `<noscript>`. --%>
      <noscript>
        <div class="rounded-lg border border-error/40 bg-error/10 text-error px-4 py-2 text-sm max-w-2xl">
          {gettext(
            "JavaScript is disabled — the template editor needs it for dragging, resizing, and saving. Enable JS and reload."
          )}
        </div>
      </noscript>

      <div
        id="og-editor-js-warning"
        role="alert"
        hidden
        class="rounded-lg border border-warning/40 bg-warning/10 text-warning-content px-4 py-2 text-sm max-w-2xl"
      >
        {gettext(
          "Editor JavaScript hasn't loaded — dragging, resizing, and keyboard shortcuts are disabled. Try a hard refresh (Ctrl+Shift+R)."
        )}
      </div>

      <div
        id="og-canvas-wrapper"
        class="bg-base-100 shadow-xl rounded"
        style={"width: #{round(@canvas_width * @display_scale)}px; height: #{round(@canvas_height * @display_scale)}px;"}
      >
        <svg
          id="og-canvas-svg"
          phx-hook="PhoenixKitOgCanvas"
          data-canvas-width={@canvas_width}
          data-canvas-height={@canvas_height}
          data-selected-id={@selected_id || ""}
          data-preview={if @preview?, do: "true", else: "false"}
          viewBox={"0 0 #{@canvas_width} #{@canvas_height}"}
          xmlns="http://www.w3.org/2000/svg"
          class="w-full h-full block cursor-default select-none"
          phx-click="deselect"
        >
          <%!-- Checker pattern: stand-in for any unresolved image
               (empty src, an unwired `{{ slot }}`, or a lookup miss).
               Two 20×20 tiles → classic transparency-grid look. --%>
          <defs>
            <pattern
              id="pk-og-checker"
              x="0"
              y="0"
              width="40"
              height="40"
              patternUnits="userSpaceOnUse"
            >
              <rect width="40" height="40" fill="#e5e7eb" />
              <rect width="20" height="20" fill="#f8fafc" />
              <rect x="20" y="20" width="20" height="20" fill="#f8fafc" />
            </pattern>
          </defs>

          <%!-- Background: solid color, or image + optional dark overlay --%>
          <.background
            background={@background}
            canvas_width={@canvas_width}
            canvas_height={@canvas_height}
          />

          <%!-- Elements --%>
          <.element
            :for={el <- @elements}
            element={el}
            preview?={@preview?}
            global_values={@global_values}
          />

          <%!-- Selection outline + resize handles, only when selected --%>
          <% selected_el = find_element(@elements, @selected_id) %>
          <.selection :if={not @preview? and selected_el} el={selected_el} />
        </svg>
      </div>
    </main>
    """
  end

  defp find_element(_elements, nil), do: nil
  defp find_element(elements, id), do: Enum.find(elements, &(&1["id"] == id))

  # Editor-side background renderer. When bg is image + slot-like src,
  # falls back to the solid color so the editor doesn't leak `{{...}}`.
  attr :background, :map, required: true
  attr :canvas_width, :any, required: true
  attr :canvas_height, :any, required: true

  defp background(assigns) do
    type = Map.get(assigns.background, "type", "color")
    value = Map.get(assigns.background, "value", "#0b1220")
    overlay = Map.get(assigns.background, "overlay_opacity", 0)
    overlay_fill = overlay_fill(Map.get(assigns.background, "overlay_color", "dark"))
    fit = Map.get(assigns.background, "fit", "fill")

    assigns =
      assigns
      |> assign(:type, type)
      |> assign(:value, value)
      |> assign(:overlay, overlay)
      |> assign(:overlay_fill, overlay_fill)
      |> assign(:image_href, resolve_editor_image_href(value))
      |> assign(:preserve_aspect_ratio, fit_to_preserve_aspect_ratio(fit))

    ~H"""
    <%= cond do %>
      <% @type == "image" and @image_href -> %>
        <image
          href={@image_href}
          x="0"
          y="0"
          width={@canvas_width}
          height={@canvas_height}
          preserveAspectRatio={@preserve_aspect_ratio}
        />
      <% @type == "image" -> %>
        <%!-- Image type selected but the source hasn't resolved yet
             (empty or `{{slot}}`). Fill with the checker so the author
             sees the "no image yet" affordance and can still preview
             overlay strength. --%>
        <rect
          x="0"
          y="0"
          width={@canvas_width}
          height={@canvas_height}
          fill="url(#pk-og-checker)"
        />
      <% true -> %>
        <rect
          x="0"
          y="0"
          width={@canvas_width}
          height={@canvas_height}
          fill={if @type == "color", do: @value, else: "#0b1220"}
        />
    <% end %>
    <%!-- Overlay tint sits above the background regardless of whether
         the image resolved to a real href or the checker placeholder,
         so the author can dial in strength before the actual image is
         wired. --%>
    <rect
      :if={@type == "image" and @overlay > 0}
      x="0"
      y="0"
      width={@canvas_width}
      height={@canvas_height}
      fill={@overlay_fill}
      fill-opacity={@overlay}
    />
    """
  end

  defp overlay_fill("light"), do: "#ffffff"
  defp overlay_fill(_), do: "#000000"

  # In the editor we can only render a background image if the src
  # resolves right now — a slot placeholder or empty string falls back
  # to the solid-color path.
  # Maps our friendly `fit` field to SVG's `preserveAspectRatio`.
  # `fill`   = cover (crop to fully cover, keep aspect).
  # `contain` = fit inside (letterbox if aspect differs, keep aspect).
  # `stretch` = distort to exact bounds.
  defp fit_to_preserve_aspect_ratio("contain"), do: "xMidYMid meet"
  defp fit_to_preserve_aspect_ratio("stretch"), do: "none"
  defp fit_to_preserve_aspect_ratio(_), do: "xMidYMid slice"

  defp resolve_editor_image_href(nil), do: nil
  defp resolve_editor_image_href(""), do: nil
  defp resolve_editor_image_href("{{" <> _), do: nil
  defp resolve_editor_image_href("http://" <> _ = v), do: v
  defp resolve_editor_image_href("https://" <> _ = v), do: v
  defp resolve_editor_image_href("/" <> _ = v), do: v
  defp resolve_editor_image_href("data:" <> _ = v), do: v

  defp resolve_editor_image_href(uuid) when is_binary(uuid) do
    # Use the shared storage helper so we get the correctly-signed URL
    # for this media file — same call publishing uses for featured
    # images. Falls back to nil (→ solid-color background) if the file
    # can't be resolved, which is safer than emitting a broken href.
    PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid, "medium") ||
      PhoenixKit.Modules.Storage.get_public_url_by_uuid(uuid)
  rescue
    _ -> nil
  end

  defp resolve_editor_image_href(_), do: nil

  # ---- Element renderers — Phoenix.Component functions called with
  # ---- `<.element ... />` so HEEx's change-tracking metadata is present.

  attr :element, :map, required: true
  attr :preview?, :boolean, required: true
  attr :global_values, :map, default: %{}

  defp element(assigns) do
    type = assigns.element["type"]
    assigns = assign(assigns, :type, type)

    case type do
      "text" -> text_element(assigns)
      "image" -> image_element(assigns)
      "rect" -> rect_element(assigns)
      "stamp" -> stamp_element(assigns)
      _ -> ~H""
    end
  end

  defp text_element(assigns) do
    el = assigns.element

    # `{{...}}` slots stay visible in the editor so the author sees
    # which slot goes where — they resolve at render time from the
    # assignment mapping. `[[...]]` globals resolve NOW using the
    # `@global_values` map (site host, page URL, etc.) so the author
    # sees the real value they'll ship.
    raw_text =
      case el do
        %{"binding" => b} when is_binary(b) and b != "" -> b
        %{"text" => t} -> t || ""
        _ -> ""
      end

    text = PhoenixKitOg.Slots.substitute(raw_text, assigns.global_values || %{})

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:outer_style, text_outer_style(el))
      |> assign(:inner_style, text_inner_style(el))
      |> assign(:span_style, text_highlight_style(el))

    ~H"""
    <g
      data-pk-og-element={@element["id"]}
      phx-click="select"
      phx-value-id={@element["id"]}
      class="cursor-pointer"
    >
      <rect
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
        fill="transparent"
      />
      <foreignObject
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
      >
        <div xmlns="http://www.w3.org/1999/xhtml" style={@outer_style}>
          <div style={@inner_style}>
            <span style={@span_style}>{@text}</span>
          </div>
        </div>
      </foreignObject>
    </g>
    """
  end

  # Checker-pattern stand-in for an image element with no resolvable
  # source. Same visual for both blank `src` and un-wired `{{slot}}`.
  #
  # Emits a per-instance `<pattern>` whose `x`/`y` match the rect's
  # position so the tiling starts with a complete tile at the top-
  # left. A wrapping `<g transform>` would achieve the same visual
  # but breaks the JS drag/resize hook, which reads bounds from the
  # inner rect (expecting canvas-space coords, not local ones).
  attr :id, :string, required: true
  attr :x, :any, required: true
  attr :y, :any, required: true
  attr :width, :any, required: true
  attr :height, :any, required: true
  attr :label, :string, required: true

  defp image_placeholder(assigns) do
    assigns = assign(assigns, :pattern_id, "pk-og-checker-#{assigns.id}")

    ~H"""
    <pattern
      id={@pattern_id}
      x={@x}
      y={@y}
      width="40"
      height="40"
      patternUnits="userSpaceOnUse"
    >
      <rect width="40" height="40" fill="#e5e7eb" />
      <rect width="20" height="20" fill="#f8fafc" />
      <rect x="20" y="20" width="20" height="20" fill="#f8fafc" />
    </pattern>
    <rect
      x={@x}
      y={@y}
      width={@width}
      height={@height}
      fill={"url(##{@pattern_id})"}
      stroke="#cbd5e1"
      stroke-width="2"
      stroke-dasharray="6 4"
    />
    <text
      x={@x + @width / 2}
      y={@y + @height / 2}
      fill="#475569"
      font-size="22"
      font-weight="500"
      text-anchor="middle"
      dominant-baseline="middle"
      style="user-select: none; pointer-events: none;"
    >
      {@label}
    </text>
    """
  end

  # Empty `src` → generic "Image" hint. `{{slot}}` → surface the slot
  # name (`{{background}}`) so the author sees what they've typed.
  defp placeholder_label(src) when is_binary(src) do
    cond do
      src == "" -> "Image"
      String.starts_with?(src, "{{") -> src
      true -> "Image"
    end
  end

  defp placeholder_label(_), do: "Image"

  # Shared underlay renderer — drops a translucent dark/light rect
  # beneath the element so text stays legible even over a busy image
  # background. Attached as the first child of every element's `<g>`.
  attr :element, :map, required: true

  defp underlay(assigns) do
    opacity = Map.get(assigns.element, "underlay_opacity", 0)

    if is_number(opacity) and opacity > 0 do
      fill = overlay_fill(Map.get(assigns.element, "underlay_color", "dark"))
      assigns = assigns |> assign(:opacity, opacity) |> assign(:fill, fill)

      ~H"""
      <rect
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
        fill={@fill}
        fill-opacity={@opacity}
        pointer-events="none"
      />
      """
    else
      ~H""
    end
  end

  defp image_element(assigns) do
    assigns = assign(assigns, :src, image_src(assigns.element["src"]))

    ~H"""
    <g
      data-pk-og-element={@element["id"]}
      phx-click="select"
      phx-value-id={@element["id"]}
      class="cursor-pointer"
    >
      <.underlay element={@element} />
      <%= if @src do %>
        <image
          href={@src}
          x={@element["x"]}
          y={@element["y"]}
          width={@element["width"]}
          height={@element["height"]}
          preserveAspectRatio={fit_to_preserve_aspect_ratio(@element["fit"])}
        />
      <% else %>
        <.image_placeholder
          id={@element["id"]}
          x={@element["x"]}
          y={@element["y"]}
          width={@element["width"]}
          height={@element["height"]}
          label={placeholder_label(@element["src"])}
        />
      <% end %>
    </g>
    """
  end

  defp rect_element(assigns) do
    ~H"""
    <g
      data-pk-og-element={@element["id"]}
      phx-click="select"
      phx-value-id={@element["id"]}
      class="cursor-pointer"
    >
      <.underlay element={@element} />
      <rect
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
        rx={@element["radius"] || 0}
        ry={@element["radius"] || 0}
        fill={@element["fill"] || "#1e293b"}
        stroke={blank_to_none(@element["stroke"])}
        stroke-width={@element["stroke_width"] || 0}
      />
    </g>
    """
  end

  defp stamp_element(assigns) do
    el = assigns.element
    raw_text = Map.get(el, "preset", "")
    text = PhoenixKitOg.Slots.substitute(raw_text, assigns.global_values || %{})

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:outer_style, text_outer_style(el))
      |> assign(:inner_style, text_inner_style(el))
      |> assign(:span_style, text_highlight_style(el))

    ~H"""
    <g
      data-pk-og-element={@element["id"]}
      phx-click="select"
      phx-value-id={@element["id"]}
      class="cursor-pointer"
    >
      <rect
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
        fill="transparent"
      />
      <foreignObject
        x={@element["x"]}
        y={@element["y"]}
        width={@element["width"]}
        height={@element["height"]}
      >
        <div xmlns="http://www.w3.org/1999/xhtml" style={@outer_style}>
          <div style={@inner_style}>
            <span style={@span_style}>{@text}</span>
          </div>
        </div>
      </foreignObject>
    </g>
    """
  end

  # ---- Selection outline + resize handles ----

  attr :el, :map, required: true

  defp selection(assigns) do
    ~H"""
    <%!-- Wrapping the outline + drag overlay + 8 handles in one group means
         the JS drag hook can apply a single `translate(dx dy)` transform to
         this group during drag and it follows the element 1:1. --%>
    <g data-pk-og-selection={@el["id"]}>
      <g pointer-events="none">
        <rect
          x={@el["x"]}
          y={@el["y"]}
          width={@el["width"]}
          height={@el["height"]}
          fill="none"
          stroke="#38bdf8"
          stroke-width="2"
          stroke-dasharray="6 4"
        />
      </g>
      <%!-- Drag affordance overlay: covers the selected element so the JS hook
           intercepts pointer-down for moving. --%>
      <rect
        data-pk-og-drag-handle={@el["id"]}
        x={@el["x"]}
        y={@el["y"]}
        width={@el["width"]}
        height={@el["height"]}
        fill="transparent"
        class="cursor-move"
        pointer-events="all"
      />
      <.handle el={@el} position="nw" cx={@el["x"]} cy={@el["y"]} />
      <.handle el={@el} position="n" cx={@el["x"] + @el["width"] / 2} cy={@el["y"]} />
      <.handle el={@el} position="ne" cx={@el["x"] + @el["width"]} cy={@el["y"]} />
      <.handle
        el={@el}
        position="e"
        cx={@el["x"] + @el["width"]}
        cy={@el["y"] + @el["height"] / 2}
      />
      <.handle
        el={@el}
        position="se"
        cx={@el["x"] + @el["width"]}
        cy={@el["y"] + @el["height"]}
      />
      <.handle
        el={@el}
        position="s"
        cx={@el["x"] + @el["width"] / 2}
        cy={@el["y"] + @el["height"]}
      />
      <.handle el={@el} position="sw" cx={@el["x"]} cy={@el["y"] + @el["height"]} />
      <.handle el={@el} position="w" cx={@el["x"]} cy={@el["y"] + @el["height"] / 2} />
    </g>
    """
  end

  attr :el, :map, required: true
  attr :position, :string, required: true
  attr :cx, :any, required: true
  attr :cy, :any, required: true

  defp handle(assigns) do
    cursor =
      case assigns.position do
        "nw" -> "nwse-resize"
        "se" -> "nwse-resize"
        "ne" -> "nesw-resize"
        "sw" -> "nesw-resize"
        "n" -> "ns-resize"
        "s" -> "ns-resize"
        "e" -> "ew-resize"
        "w" -> "ew-resize"
      end

    assigns = assign(assigns, :cursor, cursor)

    ~H"""
    <rect
      data-pk-og-resize-handle={@el["id"]}
      data-position={@position}
      x={@cx - 6}
      y={@cy - 6}
      width="12"
      height="12"
      fill="#38bdf8"
      stroke="#ffffff"
      stroke-width="2"
      style={"cursor: #{@cursor}"}
      pointer-events="all"
    />
    """
  end

  # =========================================================================
  # Right panel — element library / property panel
  # =========================================================================

  defp right_panel(assigns) do
    ~H"""
    <aside class="w-80 bg-base-100 border-l border-base-300 overflow-y-auto p-4 space-y-4">
      <.slots_panel slots={@slots} />
      <hr class="border-base-300" />
      <%= if @selected do %>
        <.property_panel selected={@selected} canvas={@canvas} />
      <% else %>
        <.template_props canvas={@canvas} />
      <% end %>
    </aside>
    """
  end

  # Small at-a-glance list of slot names the author has typed into the
  # template so far. Each chip shows type ({text} or {image}) so the
  # author sees the type an image src slot will inherit vs a text slot.
  defp slots_panel(assigns) do
    ~H"""
    <section class="space-y-2">
      <header class="flex items-center justify-between">
        <h3 class="text-xs font-semibold text-base-content/70 uppercase tracking-wide">
          {gettext("Slots used")}
        </h3>
        <span class="text-xs text-base-content/40">{length(@slots)}</span>
      </header>
      <%= if @slots == [] do %>
        <p class="text-xs text-base-content/50">
          {gettext(
            ~S|Type {{name}} in a text field (or in an image src) to declare a slot. Wire it to real data on the Assignments page.|
          )}
        </p>
      <% else %>
        <ul class="flex flex-wrap gap-1.5">
          <li :for={s <- @slots} class="badge badge-outline gap-1">
            <span class="text-xs text-base-content/50">{icon_for_type(s.type)}</span>
            <span class="font-mono text-xs">{s.name}</span>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  defp icon_for_type(:text), do: "T"
  defp icon_for_type(:image), do: "\u{1F5BC}"
  defp icon_for_type(_), do: "?"

  # ==============================================================
  # Template properties — shown in the right panel when no element is
  # selected. Covers canvas size + background (color or image + a
  # black text-legibility overlay).
  # ==============================================================
  attr :canvas, :map, required: true

  defp template_props(assigns) do
    bg = Map.get(assigns.canvas, "background", %{})
    bg_type = Map.get(bg, "type", "color")
    # `value_mode` may not be set on legacy backgrounds — infer from the
    # current value (starts with `{{` = variable, otherwise constant).
    bg_value = Map.get(bg, "value", "")

    bg_mode =
      Map.get(bg, "value_mode") ||
        cond do
          is_binary(bg_value) and String.starts_with?(bg_value, "{{") -> "variable"
          true -> "constant"
        end

    overlay_opacity = Map.get(bg, "overlay_opacity", 0)
    overlay_color = Map.get(bg, "overlay_color", "dark")

    assigns =
      assigns
      |> assign(:bg, bg)
      |> assign(:bg_type, bg_type)
      |> assign(:bg_mode, bg_mode)
      |> assign(:overlay_opacity, overlay_opacity)
      |> assign(:overlay_color, overlay_color)

    ~H"""
    <div class="space-y-4">
      <h2 class="font-semibold text-base">{gettext("Template")}</h2>

      <fieldset class="space-y-2">
        <legend class="text-xs font-semibold text-base-content/60">
          {gettext("Canvas size (pixels)")}
        </legend>
        <div class="grid grid-cols-2 gap-2">
          <.canvas_field field="width" label={gettext("Width")} value={Map.get(@canvas, "width", 1200)} />
          <.canvas_field
            field="height"
            label={gettext("Height")}
            value={Map.get(@canvas, "height", 630)}
          />
        </div>
        <p class="text-xs text-base-content/50">
          {gettext("OpenGraph consumers expect 1200×630. Custom sizes render fine.")}
        </p>
      </fieldset>

      <fieldset class="space-y-2">
        <legend class="text-xs font-semibold text-base-content/60">{gettext("Background")}</legend>
        <div>
          <label class="label py-0.5">
            <span class="label-text text-xs">{gettext("Type")}</span>
          </label>
          <form phx-change="update_canvas">
            <input type="hidden" name="field" value="background_type" />
            <select name="value" class="select select-bordered select-sm w-full">
              <option value="color" selected={@bg_type == "color"}>{gettext("Solid color")}</option>
              <option value="image" selected={@bg_type == "image"}>{gettext("Image")}</option>
            </select>
          </form>
        </div>

        <%= if @bg_type == "color" do %>
          <.canvas_color_field
            field="background_value"
            label={gettext("Color")}
            value={Map.get(@bg, "value", "#0b1220")}
          />
        <% else %>
          <div>
            <label class="label py-0.5">
              <span class="label-text text-xs">{gettext("Source")}</span>
            </label>
            <form phx-change="update_canvas" class="tabs tabs-boxed bg-base-200 p-0.5">
              <input type="hidden" name="field" value="background_value_mode" />
              <label class={"tab tab-sm flex-1 #{@bg_mode == "constant" && "tab-active"}"}>
                <input
                  type="radio"
                  name="value"
                  value="constant"
                  checked={@bg_mode == "constant"}
                  class="sr-only"
                />
                {gettext("Constant")}
              </label>
              <label class={"tab tab-sm flex-1 #{@bg_mode == "variable" && "tab-active"}"}>
                <input
                  type="radio"
                  name="value"
                  value="variable"
                  checked={@bg_mode == "variable"}
                  class="sr-only"
                />
                {gettext("Variable")}
              </label>
            </form>
          </div>

          <%= if @bg_mode == "constant" do %>
            <.media_field
              target="background_value"
              value={Map.get(@bg, "value", "")}
              label={gettext("Image")}
            />
          <% else %>
            <div>
              <label class="label py-0.5">
                <span class="label-text text-xs">{gettext("Variable name")}</span>
              </label>
              <form phx-change="update_canvas" class="flex items-center gap-2">
                <input type="hidden" name="field" value="background_variable_name" />
                <span class="text-xs text-base-content/50 font-mono"><%= "{{" %></span>
                <input
                  type="text"
                  name="value"
                  value={Map.get(@bg, "value_name", strip_curlies(Map.get(@bg, "value", "")))}
                  placeholder="background_image"
                  class="input input-bordered input-sm flex-1 font-mono text-xs"
                />
                <span class="text-xs text-base-content/50 font-mono"><%= "}}" %></span>
              </form>
              <p class="text-xs text-base-content/50 mt-1">
                {gettext(
                  "Shows up on the Assignments page — pick which module variable it maps to."
                )}
              </p>
            </div>
          <% end %>

          <div>
            <label class="label py-0.5">
              <span class="label-text text-xs">{gettext("Fit")}</span>
            </label>
            <form phx-change="update_canvas">
              <input type="hidden" name="field" value="background_fit" />
              <select name="value" class="select select-bordered select-sm w-full">
                <% fit = Map.get(@bg, "fit", "fill") %>
                <option value="fill" selected={fit == "fill"}>
                  {gettext("Fill (crop overflow)")}
                </option>
                <option value="contain" selected={fit == "contain"}>
                  {gettext("Contain (fit inside)")}
                </option>
                <option value="stretch" selected={fit == "stretch"}>
                  {gettext("Stretch (distort)")}
                </option>
              </select>
            </form>
          </div>

          <fieldset class="space-y-2 pt-2 border-t border-base-300/60">
            <legend class="text-xs font-medium text-base-content/60">
              {gettext("Text-legibility overlay")}
            </legend>

            <div>
              <label class="label py-0.5">
                <span class="label-text text-xs">{gettext("Color")}</span>
              </label>
              <form phx-change="update_canvas" class="tabs tabs-boxed bg-base-200 p-0.5">
                <input type="hidden" name="field" value="background_overlay_color" />
                <label class={"tab tab-sm flex-1 #{@overlay_color == "dark" && "tab-active"}"}>
                  <input
                    type="radio"
                    name="value"
                    value="dark"
                    checked={@overlay_color == "dark"}
                    class="sr-only"
                  />
                  <span class="w-3 h-3 rounded-full bg-neutral mr-1.5 border border-base-content/20" />
                  {gettext("Dark")}
                </label>
                <label class={"tab tab-sm flex-1 #{@overlay_color == "light" && "tab-active"}"}>
                  <input
                    type="radio"
                    name="value"
                    value="light"
                    checked={@overlay_color == "light"}
                    class="sr-only"
                  />
                  <span class="w-3 h-3 rounded-full bg-base-100 mr-1.5 border border-base-content/20" />
                  {gettext("Light")}
                </label>
              </form>
            </div>

            <div>
              <label class="label py-0.5 flex items-center justify-between">
                <span class="label-text text-xs">{gettext("Strength")}</span>
                <span class="text-xs text-base-content/50">
                  {round(@overlay_opacity * 100)}%
                </span>
              </label>
              <form phx-change="update_canvas">
                <input type="hidden" name="field" value="background_overlay_opacity" />
                <input
                  type="range"
                  name="value"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@overlay_opacity}
                  class="range range-xs w-full"
                />
              </form>
              <p class="text-xs text-base-content/50 mt-0.5">
                {gettext("How much the dark/light tint darkens or lightens the background.")}
              </p>
            </div>
          </fieldset>
        <% end %>
      </fieldset>

      <p class="text-xs text-base-content/50 pt-1">
        {gettext("Changes autosave 800ms after each edit. Ctrl+S saves immediately.")}
      </p>
    </div>
    """
  end

  # =========================================================================
  # Media picker field — a button + thumbnail preview that opens the
  # shared MediaSelectorModal. `target` (e.g. `"background_value"` /
  # `"element_src"`) tells the LV which field to write when the user
  # confirms.
  # =========================================================================
  attr :target, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp media_field(assigns) do
    preview = media_preview_url(assigns.value)
    assigns = assign(assigns, :preview, preview)

    ~H"""
    <div class="space-y-2">
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <%= if @preview do %>
        <img
          src={@preview}
          alt={@label}
          class="w-full rounded-lg border-2 border-base-300 object-cover max-h-40"
          loading="lazy"
        />
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="open_media_picker"
            phx-value-target={@target}
            class="btn btn-outline btn-xs flex-1"
          >
            <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" />
            {gettext("Change")}
          </button>
          <button
            type="button"
            phx-click="clear_media_field"
            phx-value-target={@target}
            class="btn btn-outline btn-error btn-xs flex-1"
          >
            <.icon name="hero-trash" class="w-3 h-3 mr-1" />
            {gettext("Remove")}
          </button>
        </div>
      <% else %>
        <button
          type="button"
          phx-click="open_media_picker"
          phx-value-target={@target}
          class="btn btn-outline btn-sm w-full"
        >
          <.icon name="hero-photo" class="w-4 h-4 mr-1" />
          {gettext("Choose image")}
        </button>
      <% end %>
    </div>
    """
  end

  # Resolves a media-uuid or URL into a preview URL for the small
  # thumbnail. Slot placeholders and empty strings show no preview.
  defp media_preview_url(nil), do: nil
  defp media_preview_url(""), do: nil
  defp media_preview_url("{{" <> _), do: nil
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

  # Strips the leading `{{` and trailing `}}` from a slot-shaped value
  # so the Variable-mode input shows just the bare name — the pipeline
  # only knows the canonical `{{name}}` form.
  defp strip_curlies("{{" <> rest) do
    case String.split(rest, "}}", parts: 2) do
      [name, _] -> name
      _ -> rest
    end
  end

  defp strip_curlies(v) when is_binary(v), do: v
  defp strip_curlies(_), do: ""

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp canvas_field(assigns) do
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_canvas">
        <input type="hidden" name="field" value={@field} />
        <input
          type="number"
          name="value"
          value={@value}
          step="1"
          class="input input-bordered input-sm w-full"
        />
      </form>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp canvas_color_field(assigns) do
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_canvas" class="flex items-center gap-2">
        <input type="hidden" name="field" value={@field} />
        <input
          type="color"
          name="value"
          value={normalize_color(@value)}
          oninput="this.nextElementSibling.value = this.value"
          class="w-10 h-8 rounded border border-base-300"
        />
        <input
          type="text"
          name="value"
          value={@value}
          oninput="this.previousElementSibling.value = this.value"
          class="input input-bordered input-sm flex-1 font-mono text-xs"
        />
      </form>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :canvas, :map, required: true

  defp property_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="font-semibold capitalize">{@selected["type"]}</h2>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="bring_to_front"
            class="btn btn-ghost btn-xs"
            title={gettext("Bring to front")}
          >
            <.icon name="hero-chevron-double-up" class="w-3 h-3" />
          </button>
          <button
            type="button"
            phx-click="send_to_back"
            class="btn btn-ghost btn-xs"
            title={gettext("Send to back")}
          >
            <.icon name="hero-chevron-double-down" class="w-3 h-3" />
          </button>
          <button
            type="button"
            phx-click="delete_selected"
            phx-disable-with={gettext("Deleting…")}
            class="btn btn-ghost btn-xs text-error"
            title={gettext("Delete")}
          >
            <.icon name="hero-trash" class="w-3 h-3" />
          </button>
        </div>
      </div>

      <%!-- Position + size --%>
      <fieldset class="grid grid-cols-2 gap-2">
        <.num_field selected={@selected} field="x" label="X" />
        <.num_field selected={@selected} field="y" label="Y" />
        <.num_field selected={@selected} field="width" label={gettext("Width")} />
        <.num_field selected={@selected} field="height" label={gettext("Height")} />
      </fieldset>

      <%!-- Type-specific --%>
      <%= case @selected["type"] do %>
        <% "text" -> %>
          <.text_props selected={@selected} />
        <% "image" -> %>
          <.image_props selected={@selected} canvas={@canvas} />
        <% "rect" -> %>
          <.rect_props selected={@selected} />
        <% "stamp" -> %>
          <.stamp_props selected={@selected} />
        <% _ -> %>
      <% end %>

      <%!-- Shared underlay: a dark/light scrim under the element for text
           legibility over busy backgrounds. Off by default (opacity 0). --%>
      <.underlay_props selected={@selected} />
    </div>
    """
  end

  # ---- Per-type property groups ----

  defp text_props(assigns) do
    text = Map.get(assigns.selected, "text", "") || ""
    assigns = assign(assigns, :globals_used, PhoenixKitOg.Slots.globals_used(text))

    ~H"""
    <fieldset class="space-y-2">
      <legend class="text-xs font-semibold text-base-content/60">{gettext("Text")}</legend>

      <.text_field selected={@selected} field="text" label={gettext("Text")} />
      <p class="text-xs text-base-content/50 -mt-1">
        {gettext(
          ~S|Use {{name}} for a slot (wired at assignment time) or [[name]] for a global (auto-resolved from settings).|
        )}
      </p>
      <.globals_info :if={@globals_used != []} names={@globals_used} />

      <.num_field selected={@selected} field="size" label={gettext("Font size")} />
      <.num_field selected={@selected} field="weight" label={gettext("Weight (100–900)")} />
      <.color_field selected={@selected} field="color" label={gettext("Color")} />

      <div class="grid grid-cols-2 gap-2">
        <.select_field
          selected={@selected}
          field="align"
          label={gettext("Align")}
          options={[{"left", "Left"}, {"center", "Center"}, {"right", "Right"}]}
        />
        <.select_field
          selected={@selected}
          field="valign"
          label={gettext("V-align")}
          options={[{"top", "Top"}, {"middle", "Middle"}, {"bottom", "Bottom"}]}
        />
      </div>
    </fieldset>
    """
  end

  attr :selected, :map, required: true
  attr :canvas, :map, required: true

  defp image_props(assigns) do
    src = Map.get(assigns.selected, "src", "")
    mode = if is_binary(src) and String.starts_with?(src, "{{"), do: "variable", else: "constant"

    assigns =
      assigns
      |> assign(:src, src)
      |> assign(:mode, mode)

    ~H"""
    <fieldset class="space-y-2">
      <legend class="text-xs font-semibold text-base-content/60">{gettext("Image")}</legend>

      <div>
        <label class="label py-0.5">
          <span class="label-text text-xs">{gettext("Source")}</span>
        </label>
        <div class="tabs tabs-boxed bg-base-200 p-0.5">
          <button
            type="button"
            class={"tab tab-sm flex-1 #{@mode == "constant" && "tab-active"}"}
            phx-click="set_image_mode"
            phx-value-el_id={@selected["id"]}
            phx-value-mode="constant"
          >
            {gettext("Constant")}
          </button>
          <button
            type="button"
            class={"tab tab-sm flex-1 #{@mode == "variable" && "tab-active"}"}
            phx-click="set_image_mode"
            phx-value-el_id={@selected["id"]}
            phx-value-mode="variable"
          >
            {gettext("Variable")}
          </button>
        </div>
      </div>

      <%= if @mode == "constant" do %>
        <.media_field target="element_src" value={@src} label={gettext("Image")} />
      <% end %>

      <.select_field
        selected={@selected}
        field="fit"
        label={gettext("Fit")}
        options={[
          {"fill", gettext("Fill (crop overflow)")},
          {"contain", gettext("Contain (fit inside)")},
          {"stretch", gettext("Stretch (distort)")}
        ]}
      />

      <%= if @mode != "constant" do %>
        <div>
          <label class="label py-0.5">
            <span class="label-text text-xs">{gettext("Variable name")}</span>
          </label>
          <form phx-change="update_prop_variable" class="flex items-center gap-2">
            <input type="hidden" name="el_id" value={@selected["id"]} />
            <input type="hidden" name="field" value="src" />
            <span class="text-xs text-base-content/50 font-mono"><%= "{{" %></span>
            <input
              type="text"
              name="value"
              value={strip_curlies(@src)}
              placeholder="Image"
              class="input input-bordered input-sm flex-1 font-mono text-xs"
              phx-debounce="200"
            />
            <span class="text-xs text-base-content/50 font-mono"><%= "}}" %></span>
          </form>
          <p class="text-xs text-base-content/50 mt-1">
            {gettext("Shows up on the Assignments page as an image slot to wire.")}
          </p>
        </div>
      <% end %>
    </fieldset>
    """
  end

  defp rect_props(assigns) do
    ~H"""
    <fieldset class="space-y-2">
      <legend class="text-xs font-semibold text-base-content/60">{gettext("Shape")}</legend>
      <.color_field selected={@selected} field="fill" label={gettext("Fill")} />
      <.color_field selected={@selected} field="stroke" label={gettext("Stroke")} />
      <.num_field selected={@selected} field="stroke_width" label={gettext("Stroke width")} />
      <.num_field selected={@selected} field="radius" label={gettext("Corner radius")} />
    </fieldset>
    """
  end

  defp stamp_props(assigns) do
    content = Map.get(assigns.selected, "preset", "") || ""
    assigns = assign(assigns, :globals_used, PhoenixKitOg.Slots.globals_used(content))

    ~H"""
    <fieldset class="space-y-2">
      <legend class="text-xs font-semibold text-base-content/60">{gettext("Stamp")}</legend>
      <.text_field selected={@selected} field="preset" label={gettext("Content")} />
      <p class="text-xs text-base-content/50 -mt-1">
        {gettext(~S|Use {{name}} for a slot or [[name]] for a global.|)}
      </p>
      <.globals_info :if={@globals_used != []} names={@globals_used} />
      <.num_field selected={@selected} field="size" label={gettext("Font size")} />
      <.color_field selected={@selected} field="color" label={gettext("Color")} />
    </fieldset>
    """
  end

  # ---- Field primitives ----

  attr :selected, :map, required: true

  defp underlay_props(assigns) do
    opacity = Map.get(assigns.selected, "underlay_opacity", 0)
    color = Map.get(assigns.selected, "underlay_color", "dark")
    assigns = assigns |> assign(:opacity, opacity) |> assign(:color, color)

    ~H"""
    <fieldset class="space-y-2 pt-2 border-t border-base-300/60">
      <legend class="text-xs font-semibold text-base-content/60">
        {gettext("Underlay (behind this element)")}
      </legend>

      <div>
        <label class="label py-0.5">
          <span class="label-text text-xs">{gettext("Color")}</span>
        </label>
        <form phx-change="update_prop" class="tabs tabs-boxed bg-base-200 p-0.5">
          <input type="hidden" name="el_id" value={@selected["id"]} />
          <input type="hidden" name="field" value="underlay_color" />
          <label class={"tab tab-sm flex-1 #{@color == "dark" && "tab-active"}"}>
            <input
              type="radio"
              name="value"
              value="dark"
              checked={@color == "dark"}
              class="sr-only"
            />
            <span class="w-3 h-3 rounded-full bg-neutral mr-1.5 border border-base-content/20" />
            {gettext("Dark")}
          </label>
          <label class={"tab tab-sm flex-1 #{@color == "light" && "tab-active"}"}>
            <input
              type="radio"
              name="value"
              value="light"
              checked={@color == "light"}
              class="sr-only"
            />
            <span class="w-3 h-3 rounded-full bg-base-100 mr-1.5 border border-base-content/20" />
            {gettext("Light")}
          </label>
        </form>
      </div>

      <div>
        <label class="label py-0.5 flex items-center justify-between">
          <span class="label-text text-xs">{gettext("Strength")}</span>
          <span class="text-xs text-base-content/50">
            {round(@opacity * 100)}%
          </span>
        </label>
        <form phx-change="update_prop">
          <input type="hidden" name="el_id" value={@selected["id"]} />
          <input type="hidden" name="field" value="underlay_opacity" />
          <input
            type="range"
            name="value"
            min="0"
            max="1"
            step="0.05"
            value={@opacity}
            class="range range-xs w-full"
          />
        </form>
        <p :if={@opacity == 0} class="text-xs text-base-content/50 mt-0.5">
          {gettext("Increase the strength to see the underlay behind the element.")}
        </p>
      </div>
    </fieldset>
    """
  end

  attr :selected, :map, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true

  defp num_field(assigns) do
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_prop">
        <input type="hidden" name="el_id" value={@selected["id"]} />
        <input type="hidden" name="field" value={@field} />
        <input
          type="number"
          name="value"
          value={@selected[@field]}
          step="1"
          class="input input-bordered input-sm w-full"
        />
      </form>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true

  defp text_field(assigns) do
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_prop">
        <input type="hidden" name="el_id" value={@selected["id"]} />
        <input type="hidden" name="field" value={@field} />
        <input
          type="text"
          name="value"
          value={@selected[@field]}
          class="input input-bordered input-sm w-full"
        />
      </form>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true

  defp color_field(assigns) do
    # Both inputs are named `value` so phx-change sees one param. Form
    # serialization is last-wins, which meant whichever the user *didn't*
    # touch would silently overwrite the one they did. `oninput`
    # cross-syncs the two inputs on the client BEFORE phx-change fires,
    # so the server always sees the freshly-typed / picked value in
    # both slots.
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_prop" class="flex items-center gap-2">
        <input type="hidden" name="el_id" value={@selected["id"]} />
        <input type="hidden" name="field" value={@field} />
        <input
          type="color"
          name="value"
          value={normalize_color(@selected[@field])}
          oninput="this.nextElementSibling.value = this.value"
          class="w-10 h-8 rounded border border-base-300"
        />
        <input
          type="text"
          name="value"
          value={@selected[@field]}
          oninput="this.previousElementSibling.value = this.value"
          class="input input-bordered input-sm flex-1 font-mono text-xs"
        />
      </form>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true

  defp select_field(assigns) do
    ~H"""
    <div>
      <label class="label py-0.5">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <form phx-change="update_prop">
        <input type="hidden" name="el_id" value={@selected["id"]} />
        <input type="hidden" name="field" value={@field} />
        <select name="value" class="select select-bordered select-sm w-full">
          <option :for={{val, lbl} <- @options} value={val} selected={@selected[@field] == val}>
            {lbl}
          </option>
        </select>
      </form>
    </div>
    """
  end

  # =========================================================================
  # JS hook — inline because external modules can't ship JS through the
  # parent's pipeline (per AGENTS.md). The hook handles drag + resize.
  # =========================================================================

  defp editor_hook_script(assigns) do
    ~H"""
    <script>
      // Inline (NOT type="module") so it runs synchronously during HTML
      // parsing, *before* the deferred app.js spreads PhoenixKitHooks
      // into the LiveSocket. With `type="module"` the script gets
      // deferred and the hook is registered too late to be picked up
      // by the running LiveSocket.
      (() => {
        if (window.__pkOgEditorRegistered) return;
        window.__pkOgEditorRegistered = true;

        // Watchdog: if the hook hasn't mounted a few seconds after
        // load, reveal the warning banner. The hook clears this flag
        // by setting `data-pk-og-hook-ready="true"` on the wrapper.
        setTimeout(() => {
          const wrapper = document.getElementById("og-canvas-wrapper");
          const warn = document.getElementById("og-editor-js-warning");
          if (warn && wrapper && wrapper.dataset.pkOgHookReady !== "true") {
            warn.hidden = false;
          }
        }, 2500);

        const Hooks = (window.PhoenixKitHooks = window.PhoenixKitHooks || {});

        // Convert a client point to canvas units using the SVG's CTM.
        function clientToCanvas(svg, evt) {
          const pt = svg.createSVGPoint();
          pt.x = evt.clientX;
          pt.y = evt.clientY;
          const ctm = svg.getScreenCTM();
          if (!ctm) return { x: 0, y: 0 };
          const out = pt.matrixTransform(ctm.inverse());
          return { x: out.x, y: out.y };
        }

        // Anchor `[cx, cy]` for a resize handle given its position code
        // and the element's bounds. Mirrors the server-side layout in
        // the `selection` HEEx component so live drag matches the
        // eventual re-render.
        function handleAnchor(position, x, y, w, h) {
          switch (position) {
            case "nw": return [x, y];
            case "n":  return [x + w / 2, y];
            case "ne": return [x + w, y];
            case "e":  return [x + w, y + h / 2];
            case "se": return [x + w, y + h];
            case "s":  return [x + w / 2, y + h];
            case "sw": return [x, y + h];
            case "w":  return [x, y + h / 2];
            default:   return [x, y];
          }
        }

        Hooks.PhoenixKitOgCanvas = {
          mounted() {
            const svg = this.el;
            let drag = null;
            let resize = null;
            // Set on pointer-up if the interaction was a real
            // drag/resize; used to swallow the synthetic `click` event
            // that would otherwise bubble to `phx-click="deselect"` on
            // the SVG root and blow away the selection mid-interaction.
            let swallowNextClick = false;

            // Flip the wrapper's readiness flag so the "JS didn't
            // load" banner disappears. The banner is rendered by the
            // server (default state) and hidden by CSS when the flag
            // is `true` — so anyone stuck on a stale/failed JS bundle
            // gets a visible hint instead of a silently-dead editor.
            const wrapper = document.getElementById("og-canvas-wrapper");
            if (wrapper) wrapper.dataset.pkOgHookReady = "true";

            const onPointerDown = (evt) => {
              const dragTarget = evt.target.closest("[data-pk-og-drag-handle]");
              const resizeTarget = evt.target.closest("[data-pk-og-resize-handle]");

              if (resizeTarget) {
                evt.preventDefault();
                evt.stopPropagation();
                const id = resizeTarget.dataset.pkOgResizeHandle;
                const position = resizeTarget.dataset.position;
                const el = this.findElement(id);
                if (!el) return;
                const start = clientToCanvas(svg, evt);
                const origin = this.boundsForElement(id);
                resize = {
                  id,
                  position,
                  start,
                  origin,
                  // Seed `last` with the current bounds so a zero-
                  // movement pointerup sends the *current* size to the
                  // server rather than reverting.
                  last: { ...origin },
                };
                try { svg.setPointerCapture(evt.pointerId); } catch (_) {}
              } else if (dragTarget) {
                evt.preventDefault();
                evt.stopPropagation();
                const id = dragTarget.dataset.pkOgDragHandle;
                const start = clientToCanvas(svg, evt);
                drag = { id, start, dx: 0, dy: 0 };
                try { svg.setPointerCapture(evt.pointerId); } catch (_) {}
              }
            };

            // Capture-phase click listener on the SVG root: if the
            // pointerup just ended a drag/resize, swallow the click so
            // it doesn't fall through to `phx-click="deselect"`.
            const onClickCapture = (evt) => {
              if (swallowNextClick) {
                evt.stopPropagation();
                evt.preventDefault();
                swallowNextClick = false;
              }
            };

            const onPointerMove = (evt) => {
              if (drag) {
                const cur = clientToCanvas(svg, evt);
                drag.dx = Math.round(cur.x - drag.start.x);
                drag.dy = Math.round(cur.y - drag.start.y);
                this.applyTempTransform(drag.id, drag.dx, drag.dy);
              } else if (resize) {
                const cur = clientToCanvas(svg, evt);
                const dx = cur.x - resize.start.x;
                const dy = cur.y - resize.start.y;
                this.applyTempResize(resize, dx, dy);
              }
            };

            const releaseCapture = (evt) => {
              try {
                svg.releasePointerCapture(evt.pointerId);
              } catch (_) {
                // Capture may already be released (or never taken);
                // never let this throw and orphan the drag state.
              }
            };

            const onPointerUp = (evt) => {
              // Clear the interaction state FIRST — even if the
              // pushEvent below throws (rare, but a bad server reply
              // shouldn't leave the DOM in a "stuck" state), the local
              // vars are reset so the next pointerdown starts clean.
              const wasDrag = drag;
              const wasResize = resize;
              drag = null;
              resize = null;
              releaseCapture(evt);

              if (wasDrag) {
                if (wasDrag.dx !== 0 || wasDrag.dy !== 0) {
                  swallowNextClick = true;
                  // Bake the drag delta into the children's `x`/`y`
                  // attributes and drop the transient `transform` in
                  // the same tick. This way the DOM already matches
                  // what the server will render on the ack — morphdom
                  // sees no diff and there's no visual patch, which
                  // eliminates the rubber-band between "transform
                  // removed" and "children x/y updated".
                  this.commitDragBounds(wasDrag.id, wasDrag.dx, wasDrag.dy);
                  this.pushEvent("move_element", {
                    id: wasDrag.id,
                    dx: wasDrag.dx,
                    dy: wasDrag.dy,
                  });
                } else {
                  this.clearTempTransform(wasDrag.id);
                }
              } else if (wasResize) {
                swallowNextClick = true;
                const rect = this.computeResizeBounds(wasResize);
                this.pushEvent(
                  "resize_element",
                  {
                    id: wasResize.id,
                    x: Math.round(rect.x),
                    y: Math.round(rect.y),
                    width: Math.round(rect.width),
                    height: Math.round(rect.height),
                  },
                  () => this.clearTempResize(wasResize.id)
                );
              }
            };

            svg.addEventListener("pointerdown", onPointerDown);
            svg.addEventListener("pointermove", onPointerMove);
            svg.addEventListener("pointerup", onPointerUp);
            svg.addEventListener("pointercancel", onPointerUp);
            // Capture-phase so the listener runs *before* LV's own
            // `phx-click` handler on the same element.
            svg.addEventListener("click", onClickCapture, true);

            this._cleanup = () => {
              svg.removeEventListener("pointerdown", onPointerDown);
              svg.removeEventListener("pointermove", onPointerMove);
              svg.removeEventListener("pointerup", onPointerUp);
              svg.removeEventListener("pointercancel", onPointerUp);
              svg.removeEventListener("click", onClickCapture, true);
            };
          },

          destroyed() {
            this._cleanup && this._cleanup();
          },

          findElement(id) {
            return this.el.querySelector(`[data-pk-og-element="${id}"]`);
          },

          boundsForElement(id) {
            const g = this.findElement(id);
            if (!g) return null;
            // First DIRECT child that's sized — restricting to direct
            // children skips descendants that live inside <pattern>
            // (the checker placeholder emits an inline <pattern> whose
            // internal rects have x=0/y=0 in the pattern's own coord
            // space).
            const sized = g.querySelector(
              ":scope > rect, :scope > foreignObject, :scope > image"
            );
            if (!sized) return null;
            return {
              x: parseFloat(sized.getAttribute("x")) || 0,
              y: parseFloat(sized.getAttribute("y")) || 0,
              width: parseFloat(sized.getAttribute("width")) || 0,
              height: parseFloat(sized.getAttribute("height")) || 0,
            };
          },

          // Translates the element group + its selection chrome together,
          // so the dashed outline + drag overlay + resize handles track
          // the element 1:1 during the drag.
          forEachElementGroup(id, fn) {
            const selector =
              `[data-pk-og-element="${id}"], [data-pk-og-selection="${id}"]`;
            this.el.querySelectorAll(selector).forEach(fn);
          },

          applyTempTransform(id, dx, dy) {
            this.forEachElementGroup(id, (g) =>
              g.setAttribute("transform", `translate(${dx} ${dy})`)
            );
          },

          clearTempTransform(id) {
            this.forEachElementGroup(id, (g) =>
              g.removeAttribute("transform")
            );
          },

          // Bakes a `(dx, dy)` drag delta into the element's child
          // coordinates AND its selection-chrome coordinates, then
          // drops the transient `transform`. This produces a DOM that
          // matches what the server will render on the `move_element`
          // ack, so morphdom finds no diff and nothing visibly flickers.
          commitDragBounds(id, dx, dy) {
            const el = this.findElement(id);
            const bounds = el ? this.boundsForElement(id) : null;
            if (!bounds) {
              this.clearTempTransform(id);
              return;
            }

            const newX = bounds.x + dx;
            const newY = bounds.y + dy;

            // Element children (rect, foreignObject, image): update x/y
            // only — width/height are preserved. Direct children so we
            // don't rewrite pattern-internal rects.
            if (el) {
              el.querySelectorAll(
                ":scope > rect, :scope > foreignObject, :scope > image"
              ).forEach((node) => {
                node.setAttribute("x", newX);
                node.setAttribute("y", newY);
              });
              // Pattern (checker placeholder) — keep origin aligned to
              // the moving rect so tiles don't slide during drag.
              el.querySelectorAll(":scope > pattern").forEach((p) => {
                p.setAttribute("x", newX);
                p.setAttribute("y", newY);
              });
              // Center any label text (placeholder "Image" label).
              el.querySelectorAll(":scope > text").forEach((t) => {
                t.setAttribute("x", newX + bounds.width / 2);
                t.setAttribute("y", newY + bounds.height / 2);
              });
            }

            // Selection chrome: outline, drag overlay, resize handles.
            const chrome = this.el.querySelector(
              `[data-pk-og-selection="${id}"]`
            );
            if (chrome) {
              const outline = chrome.querySelector(
                "g[pointer-events='none'] > rect"
              );
              if (outline) {
                outline.setAttribute("x", newX);
                outline.setAttribute("y", newY);
              }

              const overlay = chrome.querySelector("[data-pk-og-drag-handle]");
              if (overlay) {
                overlay.setAttribute("x", newX);
                overlay.setAttribute("y", newY);
              }

              chrome
                .querySelectorAll("[data-pk-og-resize-handle]")
                .forEach((h) => {
                  const [cx, cy] = handleAnchor(
                    h.dataset.position,
                    newX,
                    newY,
                    bounds.width,
                    bounds.height
                  );
                  h.setAttribute("x", cx - 6);
                  h.setAttribute("y", cy - 6);
                });
            }

            // Finally drop the transient `transform` — the element and
            // its chrome are now at their final positions via their
            // coord attributes.
            this.clearTempTransform(id);
          },

          computeResizeBounds(resize) {
            // Prefer the last-applied bounds captured during
            // `applyTempResize`. Fall back to reading the DOM directly
            // (in case something skipped the temp-apply), and finally
            // to the pointerdown origin. Whichever we return goes to
            // the server as the authoritative post-resize bounds.
            if (resize.last) return resize.last;
            const current = this.boundsForElement(resize.id);
            return current || resize.origin;
          },

          applyTempResize(resize, dx, dy) {
            const o = resize.origin;
            let { x, y, width, height } = o;

            switch (resize.position) {
              case "e": width = o.width + dx; break;
              case "w": x = o.x + dx; width = o.width - dx; break;
              case "n": y = o.y + dy; height = o.height - dy; break;
              case "s": height = o.height + dy; break;
              case "ne": y = o.y + dy; width = o.width + dx; height = o.height - dy; break;
              case "nw": x = o.x + dx; y = o.y + dy; width = o.width - dx; height = o.height - dy; break;
              case "se": width = o.width + dx; height = o.height + dy; break;
              case "sw": x = o.x + dx; width = o.width - dx; height = o.height + dy; break;
            }

            width = Math.max(8, width);
            height = Math.max(8, height);

            // Resize the element itself (its sized SVG children).
            // Direct children only — descendants inside <pattern>
            // shouldn't be touched, and the pattern origin is updated
            // separately below.
            const g = this.findElement(resize.id);
            if (g) {
              g.querySelectorAll(
                ":scope > rect, :scope > foreignObject, :scope > image"
              ).forEach((node) => {
                node.setAttribute("x", x);
                node.setAttribute("y", y);
                node.setAttribute("width", width);
                node.setAttribute("height", height);
              });
              // Keep any inline `<pattern>` (image placeholder's
              // checker) anchored to the rect's new top-left so tiles
              // stay aligned during resize.
              g.querySelectorAll(":scope > pattern").forEach((p) => {
                p.setAttribute("x", x);
                p.setAttribute("y", y);
              });
              // Center any label text on the new bounds.
              g.querySelectorAll(":scope > text").forEach((t) => {
                t.setAttribute("x", x + width / 2);
                t.setAttribute("y", y + height / 2);
              });
            }

            // Also update the selection chrome (outline rect, drag
            // overlay, 8 corner/edge handles) so they track the element
            // during the drag rather than orphaning at the original
            // bounds. Each piece uses its own selector — a broad
            // `:scope > rect` would also match the 12×12 handles and
            // resize them to the element bounds, which is what caused
            // the "everything turns into blue boxes" bug.
            const chrome = this.el.querySelector(
              `[data-pk-og-selection="${resize.id}"]`
            );
            if (chrome) {
              // Dashed outline (rect inside the non-interactive <g>).
              const outline = chrome.querySelector("g[pointer-events='none'] > rect");
              if (outline) {
                outline.setAttribute("x", x);
                outline.setAttribute("y", y);
                outline.setAttribute("width", width);
                outline.setAttribute("height", height);
              }

              // Drag overlay (transparent rect covering the element).
              const overlay = chrome.querySelector("[data-pk-og-drag-handle]");
              if (overlay) {
                overlay.setAttribute("x", x);
                overlay.setAttribute("y", y);
                overlay.setAttribute("width", width);
                overlay.setAttribute("height", height);
              }

              // 8 resize handles — reposition only. Their 12×12 size
              // MUST NOT change or they blot out the canvas.
              chrome
                .querySelectorAll("[data-pk-og-resize-handle]")
                .forEach((h) => {
                  const [cx, cy] = handleAnchor(h.dataset.position, x, y, width, height);
                  h.setAttribute("x", cx - 6);
                  h.setAttribute("y", cy - 6);
                });
            }

            resize.last = { x, y, width, height };
          },

          clearTempResize(id) {
            // No-op: the server will re-render with the final bounds.
            // (We don't restore the old bounds because the temp resize
            // wrote them in place; the LV diff will reconcile.)
          },
        };

        // Wrapper hook for keyboard + focus management on the editor root.
        Hooks.PhoenixKitOgEditor = {
          mounted() {
            const onKeyDown = (evt) => {
              // Don't hijack inputs.
              const t = evt.target;
              if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
                return;
              }

              if (evt.key === "Delete" || evt.key === "Backspace") {
                evt.preventDefault();
                this.pushEvent("delete_selected", {});
              } else if (evt.key === "Escape") {
                this.pushEvent("deselect", {});
              } else if (evt.key.startsWith("Arrow")) {
                evt.preventDefault();
                this.pushEvent("nudge", { key: evt.key, shift: evt.shiftKey });
              } else if ((evt.ctrlKey || evt.metaKey) && evt.key === "s") {
                evt.preventDefault();
                this.pushEvent("save_now", {});
              }
            };

            window.addEventListener("keydown", onKeyDown);
            this._cleanup = () => window.removeEventListener("keydown", onKeyDown);
          },

          destroyed() {
            this._cleanup && this._cleanup();
          },
        };
      })();
    </script>
    """
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  # Info banner explaining where a `[[global]]` reference gets its
  # value from, with a link to the settings page for the ones that
  # are user-editable. Rendered when the current text/stamp contains
  # at least one `[[...]]` reference.
  attr :names, :list, required: true

  defp globals_info(assigns) do
    ~H"""
    <div class="rounded-md border border-info/30 bg-info/5 px-3 py-2 space-y-1">
      <p class="text-xs font-medium text-info flex items-center gap-1">
        <.icon name="hero-information-circle" class="w-3.5 h-3.5" />
        {gettext("Auto-filled from site config")}
      </p>
      <ul class="text-xs text-base-content/70 space-y-0.5">
        <li :for={name <- @names} class="flex items-baseline gap-1">
          <span class="font-mono text-base-content/50">[[{name}]]</span>
          <span class="text-base-content/50">—</span>
          <span>{global_description(name)}</span>
        </li>
      </ul>
      <p class="text-xs text-base-content/50 pt-0.5">
        {gettext("Site name is editable at")}
        <.link
          navigate={PhoenixKit.Utils.Routes.path("/admin/settings/organization")}
          class="link link-primary"
        >
          {gettext("Admin → Settings → Organization")}
        </.link>
        {gettext(". Site URL/host come from the app's endpoint config.")}
      </p>
    </div>
    """
  end

  defp global_description("site_url"), do: "Site's endpoint URL (from app config)"
  defp global_description("site_host"), do: "Site's hostname (from app config)"
  defp global_description("site_name"), do: "Project title (settings)"
  defp global_description("page_url"), do: "URL of the current page/post"
  defp global_description("page_locale"), do: "Active locale for this page"
  defp global_description(name), do: name

  # Layered `text-shadow` — four blurs at increasing radii with
  # decreasing opacity produce a smooth aura around each glyph. Blur
  # radii scale with the font size so a 24pt caption gets a subtle
  # halo and a 96pt headline gets a bold one.
  #
  # Off (empty string) when `underlay_opacity` is 0.
  defp text_highlight_style(el) do
    opacity = Map.get(el, "underlay_opacity", 0)

    if is_number(opacity) and opacity > 0 do
      color = Map.get(el, "underlay_color", "dark")
      base = if color == "light", do: "255,255,255", else: "0,0,0"
      size = Map.get(el, "size", 32)

      # Four falloff layers — inner is small + full opacity, outer is
      # large + faint. Sum keeps the glow just below 100% at the core.
      r1 = size * 0.15
      r2 = size * 0.3
      r3 = size * 0.6
      r4 = size * 1.0

      o1 = opacity * 0.95
      o2 = opacity * 0.75
      o3 = opacity * 0.5
      o4 = opacity * 0.3

      "text-shadow: " <>
        "0 0 #{r1}px rgba(#{base},#{o1}), " <>
        "0 0 #{r2}px rgba(#{base},#{o2}), " <>
        "0 0 #{r3}px rgba(#{base},#{o3}), " <>
        "0 0 #{r4}px rgba(#{base},#{o4});"
    else
      ""
    end
  end

  # Outer container — a flex column, positions the inner text block
  # vertically inside the element's bounding box.
  defp text_outer_style(el) do
    valign = Map.get(el, "valign", "top")

    justify =
      case valign do
        "top" -> "flex-start"
        "middle" -> "center"
        "bottom" -> "flex-end"
        _ -> "flex-start"
      end

    "width: 100%; height: 100%; display: flex; flex-direction: column; " <>
      "justify-content: #{justify}; overflow: hidden;"
  end

  # Inner container — a plain block that carries the font styling and
  # horizontal alignment. Keeping this as a normal block (not a flex
  # item) is what lets the `<span>` wrap across lines with
  # `box-decoration-break: clone` — the per-line highlight.
  defp text_inner_style(el) do
    align = Map.get(el, "align", "left")
    size = Map.get(el, "size", 32)
    weight = Map.get(el, "weight", 400)
    color = Map.get(el, "color", "#ffffff")
    font = Map.get(el, "font", "Inter")

    "text-align: #{align}; " <>
      "font-family: #{font}, system-ui, sans-serif; " <>
      "font-size: #{size}px; " <>
      "font-weight: #{weight}; " <>
      "color: #{color}; " <>
      "line-height: 1.4; " <>
      "word-break: break-word;"
  end

  defp image_src(""), do: nil
  defp image_src(nil), do: nil

  defp image_src(src) when is_binary(src) do
    cond do
      String.starts_with?(src, "{{") ->
        nil

      String.starts_with?(src, ["http://", "https://", "/", "data:"]) ->
        src

      true ->
        # Media UUID — resolve via the shared storage helper.
        try do
          PhoenixKit.Modules.Storage.get_public_url_by_uuid(src, "medium") ||
            PhoenixKit.Modules.Storage.get_public_url_by_uuid(src)
        rescue
          _ -> nil
        end
    end
  end

  defp blank_to_none(""), do: "none"
  defp blank_to_none(nil), do: "none"
  defp blank_to_none(v), do: v

  defp normalize_color(nil), do: "#000000"
  defp normalize_color(""), do: "#000000"

  defp normalize_color(<<"#", _::binary-size(6)>> = v), do: v
  defp normalize_color(<<"#", _::binary-size(3)>> = v), do: v
  defp normalize_color(_), do: "#000000"
end
