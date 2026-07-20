defmodule PhoenixKitOG.TemplatesTest do
  @moduledoc "Context tests for Templates CRUD + activity logging."
  use PhoenixKitOG.DataCase, async: false

  alias PhoenixKitOG.{Canvas, Templates}
  alias PhoenixKitOG.Schemas.Template

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "T-#{System.unique_integer([:positive])}", "canvas" => Canvas.blank()},
      overrides
    )
  end

  describe "create/2 + get/1 + list/0" do
    test "persists a template and reads it back" do
      assert {:ok, %Template{uuid: uuid, name: name}} = Templates.create(valid_attrs())
      assert %Template{} = Templates.get(uuid)
      assert Enum.any?(Templates.list(), &(&1.uuid == uuid))
      assert is_binary(name)
    end

    test "rejects a blank name with a changeset (no crash)" do
      assert {:error, %Ecto.Changeset{} = cs} = Templates.create(valid_attrs(%{"name" => ""}))
      refute cs.valid?
    end

    test "rejects a non-map canvas" do
      assert {:error, %Ecto.Changeset{}} = Templates.create(valid_attrs(%{"canvas" => "nope"}))
    end

    test "enforces the unique name constraint gracefully" do
      attrs = valid_attrs(%{"name" => "dup-name"})
      assert {:ok, _} = Templates.create(attrs)
      assert {:error, %Ecto.Changeset{} = cs} = Templates.create(attrs)
      assert Keyword.has_key?(cs.errors, :name)
    end
  end

  describe "update/3 + delete/2" do
    test "update changes fields" do
      {:ok, t} = Templates.create(valid_attrs())
      assert {:ok, %Template{name: "renamed"}} = Templates.update(t, %{"name" => "renamed"})
    end

    test "delete removes the row" do
      {:ok, t} = Templates.create(valid_attrs())
      assert {:ok, _} = Templates.delete(t)
      assert is_nil(Templates.get(t.uuid))
    end
  end

  describe "activity logging" do
    test "create logs template.created with the actor + resource" do
      actor = Ecto.UUID.generate()
      {:ok, t} = Templates.create(valid_attrs(), actor_uuid: actor)

      assert_activity(action: "template.created", resource_uuid: t.uuid, actor_uuid: actor)
    end

    test "a failed create logs the attempt flagged failed" do
      actor = Ecto.UUID.generate()
      {:error, _} = Templates.create(valid_attrs(%{"name" => ""}), actor_uuid: actor)

      assert_activity(action: "template.created", actor_uuid: actor, failed: true)
    end

    test "a failed UPDATE keeps the resource_uuid (not an orphaned audit row)" do
      actor = Ecto.UUID.generate()
      {:ok, t} = Templates.create(valid_attrs())
      {:error, _} = Templates.update(t, %{"name" => ""}, actor_uuid: actor)

      # The changeset's data carries the loaded struct, so the failure row
      # still points at WHICH template the edit targeted.
      assert_activity(
        action: "template.updated",
        actor_uuid: actor,
        resource_uuid: t.uuid,
        failed: true
      )
    end
  end

  # Query phoenix_kit_activities directly for a matching row.
  defp assert_activity(match) do
    import Ecto.Query
    repo = PhoenixKitOG.Test.Repo

    rows =
      from(a in "phoenix_kit_activities",
        select: %{
          action: a.action,
          actor_uuid: a.actor_uuid,
          resource_uuid: a.resource_uuid,
          metadata: a.metadata
        }
      )
      |> repo.all()

    found =
      Enum.any?(rows, fn r ->
        r.action == match[:action] and
          (is_nil(match[:actor_uuid]) or uuid_str(r.actor_uuid) == match[:actor_uuid]) and
          (is_nil(match[:resource_uuid]) or uuid_str(r.resource_uuid) == match[:resource_uuid]) and
          (is_nil(match[:failed]) or r.metadata["failed"] == true)
      end)

    assert found, "no activity row matching #{inspect(match)} in #{inspect(rows)}"
  end

  defp uuid_str(nil), do: nil

  defp uuid_str(bin) when is_binary(bin) and byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, s} -> s
      _ -> nil
    end
  end

  defp uuid_str(other), do: to_string(other)
end
