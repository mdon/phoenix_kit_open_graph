defmodule PhoenixKitOG.Schemas.Assignment do
  @moduledoc """
  Binds a template to a scope inside a consumer module's hierarchy.

  `module_key` is the consumer's `PhoenixKit.Module.module_key/0`
  (e.g. `"publishing"`). `scope_type` is the consumer-defined tier
  (`"default"`, `"group"`, `"post"`). `scope_uuid` is the row uuid at
  that tier, or `nil` for the module-wide `"default"` tier.

  Uniqueness is enforced at the DB level via a partial index pair:

      (module_key, scope_type) WHERE scope_uuid IS NULL
      (module_key, scope_type, scope_uuid) WHERE scope_uuid IS NOT NULL

  (See V139.)
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitOG.Schemas.Template

  @type t :: %__MODULE__{
          uuid: binary() | nil,
          module_key: String.t() | nil,
          scope_type: String.t() | nil,
          scope_uuid: binary() | nil,
          slot_mapping: map(),
          template_uuid: binary() | nil,
          template: Template.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7
  @timestamps_opts [type: :utc_datetime]

  schema "phoenix_kit_og_assignments" do
    field :module_key, :string
    field :scope_type, :string
    field :scope_uuid, UUIDv7
    field :slot_mapping, :map, default: %{}
    belongs_to :template, Template, foreign_key: :template_uuid, references: :uuid, type: UUIDv7

    timestamps()
  end

  @doc false
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:module_key, :scope_type, :scope_uuid, :template_uuid, :slot_mapping])
    |> validate_required([:module_key, :scope_type, :template_uuid])
    |> validate_length(:module_key, max: 64)
    |> validate_length(:scope_type, max: 32)
    |> validate_slot_mapping()
    |> foreign_key_constraint(:template_uuid)
  end

  # slot_mapping must be a flat `%{slot_name => variable_name}` where
  # both are strings. Nested structures leak module-specific shapes
  # into the storage layer; keep it strict.
  defp validate_slot_mapping(changeset) do
    case get_field(changeset, :slot_mapping) do
      m when is_map(m) ->
        if Enum.all?(m, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          changeset
        else
          add_error(changeset, :slot_mapping, "keys and values must be strings")
        end

      _ ->
        add_error(changeset, :slot_mapping, "must be a map")
    end
  end
end
