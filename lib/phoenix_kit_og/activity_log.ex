defmodule PhoenixKitOG.ActivityLog do
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

  # Audit the ATTEMPT even on failure: the user initiated the action, so
  # the trail shouldn't lose it because a changeset was invalid. For an
  # UPDATE/DELETE the changeset's `data` carries the loaded struct (with
  # its uuid), so run `fields_fn` on it to preserve the resource context
  # — a failed edit points at WHICH record it targeted. A failed CREATE's
  # `data` is a blank struct (uuid nil), which resolves to no resource_uuid,
  # exactly right.
  def log({:error, %Ecto.Changeset{data: data} = cs} = err, action, opts, fields_fn)
      when is_binary(action) and is_function(fields_fn, 1) do
    fields =
      data
      |> fields_fn.()
      |> Map.update(:metadata, %{"failed" => true, "reason" => "validation"}, fn m ->
        Map.merge(m, %{"failed" => true, "reason" => failure_reason(cs)})
      end)

    maybe_log(action, opts, fields)
    err
  end

  # Non-changeset error (e.g. an atom reason) — no struct to key off, so
  # just record the flagged attempt.
  def log({:error, reason} = err, action, opts, _fields_fn) when is_binary(action) do
    maybe_log(action, opts, %{
      metadata: %{"failed" => true, "reason" => failure_reason(reason)}
    })

    err
  end

  defp failure_reason(%Ecto.Changeset{}), do: "validation"
  defp failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp failure_reason(_), do: "error"

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
          Logger.warning("[PhoenixKitOG.ActivityLog] Postgrex error: #{inspect(e)}")
          :ok
      end

    e ->
      Logger.warning("[PhoenixKitOG.ActivityLog] log failed: #{inspect(e)}")
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
