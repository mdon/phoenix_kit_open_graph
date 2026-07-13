defmodule PhoenixKitOG.Schemas.Template do
  @moduledoc """
  A reusable OpenGraph design — canvas + ordered elements with variable
  bindings. Persisted as JSONB so the structure can evolve (new element
  types) without a schema change.

  See `AGENTS.md` → "Canvas JSON shape" for the shape contract.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: binary() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          canvas: map(),
          preview_image_uuid: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7
  @timestamps_opts [type: :utc_datetime]

  schema "phoenix_kit_og_templates" do
    field :name, :string
    field :description, :string
    field :canvas, :map, default: %{}
    field :preview_image_uuid, UUIDv7

    timestamps()
  end

  @doc false
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :description, :canvas, :preview_image_uuid])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> validate_length(:description, max: 1024)
    |> validate_canvas()
    |> unique_constraint(:name, name: :phoenix_kit_og_templates_name_uniq)
  end

  # Canvas is freeform JSONB but we require *some* shape: a map at the
  # top level. Element validation lives in the editor / renderer rather
  # than the schema so the JSON can grow new fields without migrations.
  defp validate_canvas(changeset) do
    case get_field(changeset, :canvas) do
      m when is_map(m) -> changeset
      _ -> add_error(changeset, :canvas, "must be a map")
    end
  end
end
