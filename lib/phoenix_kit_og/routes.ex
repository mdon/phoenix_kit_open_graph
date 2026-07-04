defmodule PhoenixKitOG.Routes do
  @moduledoc """
  Route registration for routes that can't be inlined on a `Tab` —
  notably the per-template editor at `/admin/open-graph/:uuid/edit`.

  The two index routes (`/admin/open-graph` and `…/assignments`) are
  still registered via the `live_view:` field on their admin tabs in
  `PhoenixKitOG.admin_tabs/0`; including them here as well would
  produce a duplicate-route error.
  """

  @doc """
  Public (non-admin) routes injected into the host router. We mount a
  single endpoint that serves cached OG PNGs.

  No auth — OG image consumers (Facebook, Twitter, LinkedIn) don't
  carry sessions. The route lives under the host's PhoenixKit URL
  prefix and rides the standard `:browser` pipeline so it inherits
  session/CSRF handling for free, even though we don't use them.
  """
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup])

        get("/og-image/:key", PhoenixKitOG.Web.ImageController, :show, as: :phoenix_kit_og_image)
      end
    end
  end

  @doc false
  def public_routes(_url_prefix), do: quote(do: nil)

  @doc """
  Localized admin routes — `/<locale>/admin/...`. The editor + new-template
  routes only; index pages come from the `live_view:` field on tabs.
  """
  def admin_locale_routes do
    quote do
      live("/admin/open-graph/new", PhoenixKitOG.Web.EditorLive, :new,
        as: :phoenix_kit_og_new_localized
      )

      live("/admin/open-graph/:uuid/edit", PhoenixKitOG.Web.EditorLive, :edit,
        as: :phoenix_kit_og_edit_localized
      )
    end
  end

  @doc "Non-localized variants."
  def admin_routes do
    quote do
      live("/admin/open-graph/new", PhoenixKitOG.Web.EditorLive, :new, as: :phoenix_kit_og_new)

      live("/admin/open-graph/:uuid/edit", PhoenixKitOG.Web.EditorLive, :edit,
        as: :phoenix_kit_og_edit
      )
    end
  end
end
