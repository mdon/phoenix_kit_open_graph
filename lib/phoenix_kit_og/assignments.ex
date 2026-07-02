defmodule PhoenixKitOg.Assignments do
  @moduledoc """
  Context for binding templates to scopes inside a consumer module's
  hierarchy.

  ## Hierarchy resolution

  A consumer module's `refine_og/4` walks an ordered list of
  `{scope_type, scope_uuid}` tuples (most specific first) — the first
  scope with an assignment wins.

      Assignments.resolve_template("publishing", [
        {"post", post_uuid},
        {"group", group_uuid},
        {"default", nil}
      ])

  Returns `{:ok, template}` or `:none`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKitOg.ActivityLog
  alias PhoenixKitOg.Schemas.{Assignment, Template}

  @doc """
  All assignments owned by `module_key`, preloaded with their template
  for display in the assignments admin UI.
  """
  @spec list_for_module(String.t()) :: [Assignment.t()]
  def list_for_module(module_key) when is_binary(module_key) do
    Repo.all(
      from a in Assignment,
        where: a.module_key == ^module_key,
        preload: [:template],
        order_by: [asc: a.scope_type, asc: a.scope_uuid]
    )
  end

  @doc """
  Upserts an assignment. Pass `scope_uuid: nil` for the module-wide
  default tier.
  """
  @spec set(String.t(), String.t(), binary() | nil, binary(), keyword()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def set(module_key, scope_type, scope_uuid, template_uuid, opts \\ []) do
    case get(module_key, scope_type, scope_uuid) do
      nil ->
        %Assignment{}
        |> Assignment.changeset(%{
          module_key: module_key,
          scope_type: scope_type,
          scope_uuid: scope_uuid,
          template_uuid: template_uuid
        })
        |> Repo.insert()
        |> ActivityLog.log("assignment.created", opts, &assignment_activity/1)

      %Assignment{} = existing ->
        existing
        |> Assignment.changeset(%{template_uuid: template_uuid})
        |> Repo.update()
        |> ActivityLog.log("assignment.updated", opts, &assignment_activity/1)
    end
  end

  @spec clear(String.t(), String.t(), binary() | nil, keyword()) ::
          {:ok, Assignment.t()} | {:error, :not_found}
  def clear(module_key, scope_type, scope_uuid, opts \\ []) do
    case get(module_key, scope_type, scope_uuid) do
      nil ->
        {:error, :not_found}

      %Assignment{} = a ->
        a
        |> Repo.delete()
        |> ActivityLog.log("assignment.deleted", opts, &assignment_activity/1)
    end
  end

  @doc """
  Updates just the `slot_mapping` on an existing assignment. The
  wiring UI writes here every time a slot dropdown changes.
  """
  @spec update_slot_mapping(Assignment.t(), map(), keyword()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def update_slot_mapping(%Assignment{} = assignment, mapping, opts \\ [])
      when is_map(mapping) do
    assignment
    |> Assignment.changeset(%{slot_mapping: mapping})
    |> Repo.update()
    |> ActivityLog.log("assignment.slot_mapping_updated", opts, &assignment_activity/1)
  end

  @spec get(String.t(), String.t(), binary() | nil) :: Assignment.t() | nil
  def get(module_key, scope_type, nil) do
    Repo.one(
      from a in Assignment,
        where:
          a.module_key == ^module_key and
            a.scope_type == ^scope_type and
            is_nil(a.scope_uuid),
        preload: [:template]
    )
  end

  def get(module_key, scope_type, scope_uuid) when is_binary(scope_uuid) do
    Repo.one(
      from a in Assignment,
        where:
          a.module_key == ^module_key and
            a.scope_type == ^scope_type and
            a.scope_uuid == ^scope_uuid,
        preload: [:template]
    )
  end

  @doc """
  Walks the hierarchy, returns the first template that wins.

  Skips tuples whose `scope_uuid` is `nil` for any scope other than
  `"default"` — those represent "no id resolvable" (e.g. a post without
  a group) and should pass through to the next tier.
  """
  @spec resolve_template(String.t(), [{String.t(), binary() | nil}]) ::
          {:ok, Template.t()} | :none
  def resolve_template(module_key, hierarchy) when is_list(hierarchy) do
    case resolve_template_with_mapping(module_key, hierarchy) do
      {:ok, template, _mapping} -> {:ok, template}
      other -> other
    end
  end

  @doc """
  Same walk as `resolve_template/2` but also returns the winning
  assignment's `slot_mapping` so callers can substitute template slots
  in one pass.
  """
  @spec resolve_template_with_mapping(String.t(), [{String.t(), binary() | nil}]) ::
          {:ok, Template.t(), map()} | :none
  def resolve_template_with_mapping(module_key, hierarchy) when is_list(hierarchy) do
    Enum.reduce_while(hierarchy, :none, fn
      {"default", _}, _acc ->
        case get(module_key, "default", nil) do
          %Assignment{template: %Template{} = t} = a ->
            {:halt, {:ok, t, a.slot_mapping || %{}}}

          _ ->
            {:cont, :none}
        end

      {_scope, nil}, _acc ->
        {:cont, :none}

      {scope_type, scope_uuid}, _acc ->
        case get(module_key, scope_type, scope_uuid) do
          %Assignment{template: %Template{} = t} = a ->
            {:halt, {:ok, t, a.slot_mapping || %{}}}

          _ ->
            {:cont, :none}
        end
    end)
  end

  # PII-safe activity payload: module + scope shape + template pointer.
  # No slot_mapping content (users type into it — treat as free text).
  defp assignment_activity(%Assignment{} = a) do
    %{
      resource_type: "phoenix_kit_og_assignment",
      resource_uuid: a.uuid,
      metadata: %{
        "module_key" => a.module_key,
        "scope_type" => a.scope_type,
        "scope_uuid" => a.scope_uuid,
        "template_uuid" => a.template_uuid
      }
    }
  end
end
