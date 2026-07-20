defmodule PhoenixKitOG.Gettext do
  @moduledoc """
  Gettext backend for OpenGraph-module-specific UI strings.

  Modules wrapping domain strings (template editor, assignments,
  variable/global labels, save-state badges, sample copy) declare
  `use Gettext, backend: PhoenixKitOG.Gettext` and call `gettext(...)`.
  Translations live in this repo's `priv/gettext/` — keep them in sync
  with `mix gettext.extract` + `mix gettext.merge priv/gettext`.

  The Phoenix pipeline sets the locale once via `Gettext.put_locale/1`
  (read from the process dictionary), so a single locale switch in the
  host drives this backend and core's `PhoenixKitWeb.Gettext` together.
  """

  # Generated Gettext.Backend callbacks trigger `call_without_opaque`
  # warnings from Expo.PluralForms — a known false positive in gettext ≥ 0.26.
  @dialyzer {:no_opaque, []}

  use Gettext.Backend, otp_app: :phoenix_kit_og
end
