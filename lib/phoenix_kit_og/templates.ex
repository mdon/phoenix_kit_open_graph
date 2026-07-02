defmodule PhoenixKitOg.Templates do
  @moduledoc """
  Context for managing OpenGraph templates. CRUD only — the editor and
  renderer live elsewhere.

  Mutating functions accept an `opts` keyword list; pass `actor_uuid:
  user_uuid` to attribute the change in the activity feed. Omitting it
  logs an anonymous entry — still auditable, just not attributed.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKitOg.ActivityLog
  alias PhoenixKitOg.Schemas.Template

  @doc "Returns all templates, ordered by name."
  @spec list() :: [Template.t()]
  def list do
    Repo.all(from t in Template, order_by: [asc: t.name])
  end

  @doc "Returns `nil` when no template matches."
  @spec get(binary()) :: Template.t() | nil
  def get(uuid) when is_binary(uuid), do: Repo.get(Template, uuid)

  @spec create(map(), keyword()) :: {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs, opts \\ []) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
    |> ActivityLog.log("template.created", opts, &template_activity/1)
  end

  @spec update(Template.t(), map(), keyword()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def update(%Template{} = template, attrs, opts \\ []) do
    template
    |> Template.changeset(attrs)
    |> Repo.update()
    |> ActivityLog.log("template.updated", opts, &template_activity/1)
  end

  @spec delete(Template.t(), keyword()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Template{} = template, opts \\ []) do
    template
    |> Repo.delete()
    |> ActivityLog.log("template.deleted", opts, &template_activity/1)
  end

  @spec change(Template.t(), map()) :: Ecto.Changeset.t()
  def change(%Template{} = template, attrs \\ %{}),
    do: Template.changeset(template, attrs)

  # PII-safe activity payload: name + element count only. The canvas
  # itself isn't logged (it can grow to many KB and doesn't help
  # scanning the audit feed).
  defp template_activity(%Template{} = template) do
    element_count =
      case template.canvas do
        %{"elements" => els} when is_list(els) -> length(els)
        _ -> 0
      end

    %{
      resource_type: "phoenix_kit_og_template",
      resource_uuid: template.uuid,
      metadata: %{
        "name" => template.name,
        "elements" => element_count
      }
    }
  end
end
