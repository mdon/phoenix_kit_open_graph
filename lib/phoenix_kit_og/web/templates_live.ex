defmodule PhoenixKitOg.Web.TemplatesLive do
  @moduledoc """
  Admin landing page for the OG module — lists templates and the
  create/delete actions. The visual editor is Phase 2; this page only
  carries minimal CRUD scaffolding so the module is interactive end-to-end.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitOg.{Errors, Paths, Templates}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "OpenGraph — Templates")
     |> load_templates()}
  end

  @impl true
  def handle_event("create_blank", _params, socket) do
    {:noreply, push_navigate(socket, to: Paths.new_template())}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Templates.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:not_found))}

      template ->
        case Templates.delete(template, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Deleted “%{name}”.", name: template.name))
             |> load_templates()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete template."))}
        end
    end
  end

  defp load_templates(socket), do: assign(socket, :templates, Templates.list())

  # Standard actor-opts shape — passes actor_uuid to the context so
  # the activity feed can attribute the change. Anonymous users
  # (nil actor) still write an audit row, just unattributed.
  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-4 py-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("OpenGraph templates")}</h1>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext(
              "Designs used to compose OG share images. Assignments page binds each template to a module, group, or post."
            )}
          </p>
        </div>
        <button type="button" phx-click="create_blank" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4 mr-1" />
          {gettext("New template")}
        </button>
      </div>

      <div class="rounded-lg border border-base-300 bg-base-100">
        <%= if @templates == [] do %>
          <div class="px-6 py-12 text-center text-base-content/60">
            <.icon name="hero-rectangle-stack" class="w-10 h-10 mx-auto text-base-content/30" />
            <p class="mt-3 text-sm">
              {gettext(
                "No templates yet. The visual editor is coming next — for now you can create a default starter to verify the integration."
              )}
            </p>
          </div>
        <% else %>
          <ul class="divide-y divide-base-300">
            <li
              :for={t <- @templates}
              class="px-4 py-3 flex items-center justify-between hover:bg-base-200"
            >
              <.link navigate={Paths.edit_template(t.uuid)} class="flex-1 min-w-0">
                <p class="font-medium">{t.name}</p>
                <p :if={t.description not in [nil, ""]} class="text-xs text-base-content/60 mt-0.5">
                  {t.description}
                </p>
                <p class="text-xs text-base-content/40 mt-0.5 font-mono">{t.uuid}</p>
              </.link>
              <button
                type="button"
                phx-click="delete"
                phx-value-uuid={t.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Delete %{name}?", name: t.name)}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </li>
          </ul>
        <% end %>
      </div>

      <p class="text-xs text-base-content/50">
        {gettext(
          "Templates listed here can be bound to modules, groups, or posts from the Assignments tab."
        )}
        <.link navigate={Paths.assignments()} class="link link-primary">
          {gettext("Go to assignments →")}
        </.link>
      </p>
    </div>
    """
  end
end
