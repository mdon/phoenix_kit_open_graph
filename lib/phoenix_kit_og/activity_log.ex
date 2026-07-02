defmodule PhoenixKitOg.ActivityLog do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/1` for the OG plugin.

  Every entry is stamped with `module: "phoenix_kit_og"` so the admin
  activity feed can filter to just this plugin's events. Callers pass
  the pipe-friendly `{:ok, struct}` shape so the return value chains
  cleanly through context functions.

  The wrapper guards against three known drop-cases:

    * `PhoenixKit.Activity` isn't loaded — module not compiled yet
      (rare, but possible during recompile cascades).
    * The `phoenix_kit_activity` table doesn't exist — a very fresh
      host that hasn't run migrations past V72 (activity was
      introduced there). Rescuing `Postgrex.Error :undefined_table`
      keeps a fresh install usable before migrations catch up.
    * Any other exception — logged as a warning, never re-raised.

  Metadata is PII-safe by convention: names, statuses, counts, UUIDs
  are OK; email / phone / free-text / anything a user could paste in
  is not.
  """

  require Logger

  @module_key "phoenix_kit_og"

  @doc """
  Pipe step for context functions returning `{:ok, struct}`. Logs the
  action and returns the value unchanged. `{:error, _}` short-circuits
  to a no-op so callers can put this at the tail of the pipe.

  ## Example

      %Template{}
      |> Template.changeset(attrs)
      |> Repo.insert()
      |> ActivityLog.log("template.created", opts, &template_activity_fields/1)
  """
  @spec log(
          {:ok, struct()} | {:error, term()},
          String.t(),
          keyword(),
          (struct() -> map())
        ) :: {:ok, struct()} | {:error, term()}
  def log({:ok, struct} = ok, action, opts, fields_fn)
      when is_binary(action) and is_function(fields_fn, 1) do
    maybe_log(action, opts, fields_fn.(struct))
    ok
  end

  def log({:error, _} = err, _action, _opts, _fields_fn), do: err

  @doc """
  Log without the pipe wrapper — for transactions, toggles, and other
  paths where the caller doesn't have a `{:ok, struct}` in hand.
  """
  @spec maybe_log(String.t(), keyword(), map()) :: :ok
  def maybe_log(action, opts, fields) when is_binary(action) and is_map(fields) do
    do_log(action, opts, fields)
  rescue
    e in Postgrex.Error ->
      case e do
        %Postgrex.Error{postgres: %{code: :undefined_table}} ->
          # Fresh host, migrations haven't caught up — silently no-op.
          :ok

        _ ->
          Logger.warning("[PhoenixKitOg.ActivityLog] Postgrex error: #{inspect(e)}")
          :ok
      end

    e ->
      Logger.warning("[PhoenixKitOg.ActivityLog] log failed: #{inspect(e)}")
      :ok
  end

  defp do_log(action, opts, fields) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      attrs =
        %{
          action: action,
          module: @module_key,
          mode: Keyword.get(opts, :mode, "manual"),
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: Map.get(fields, :resource_type),
          resource_uuid: Map.get(fields, :resource_uuid),
          metadata: Map.get(fields, :metadata, %{})
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      _ = PhoenixKit.Activity.log(attrs)
    end

    :ok
  end
end
