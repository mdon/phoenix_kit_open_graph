defmodule PhoenixKitOg.Schemas.AssignmentTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Schemas.Assignment

  @template_uuid "01234567-89ab-cdef-0123-456789abcdef"

  describe "changeset/2 — required fields" do
    test "requires module_key + scope_type + template_uuid" do
      cs = Assignment.changeset(%Assignment{}, %{})
      refute cs.valid?

      errs = errors(cs)
      assert %{module_key: [_], scope_type: [_], template_uuid: [_]} = errs
    end

    test "is valid with the three required fields" do
      cs =
        Assignment.changeset(%Assignment{}, %{
          "module_key" => "publishing",
          "scope_type" => "default",
          "template_uuid" => @template_uuid
        })

      assert cs.valid?
    end
  end

  describe "changeset/2 — length caps" do
    test "module_key capped at 64" do
      cs =
        Assignment.changeset(%Assignment{}, %{
          "module_key" => String.duplicate("x", 65),
          "scope_type" => "default",
          "template_uuid" => @template_uuid
        })

      refute cs.valid?
      assert %{module_key: [msg]} = errors(cs)
      assert msg =~ "should be at most 64"
    end

    test "scope_type capped at 32" do
      cs =
        Assignment.changeset(%Assignment{}, %{
          "module_key" => "publishing",
          "scope_type" => String.duplicate("x", 33),
          "template_uuid" => @template_uuid
        })

      refute cs.valid?
      assert %{scope_type: [msg]} = errors(cs)
      assert msg =~ "should be at most 32"
    end
  end

  describe "changeset/2 — slot_mapping shape" do
    test "empty map is fine (no wiring yet)" do
      cs = valid_changeset(%{"slot_mapping" => %{}})
      assert cs.valid?
    end

    test "%{string => string} is fine" do
      cs = valid_changeset(%{"slot_mapping" => %{"Title" => "post_title"}})
      assert cs.valid?
    end

    test "rejects nested structures — keeps the storage layer flat" do
      cs = valid_changeset(%{"slot_mapping" => %{"Title" => %{"nested" => "map"}}})
      refute cs.valid?
      assert %{slot_mapping: [msg]} = errors(cs)
      assert msg =~ "must be strings"
    end

    test "rejects a non-map slot_mapping" do
      cs = valid_changeset(%{"slot_mapping" => "not a map"})
      refute cs.valid?
      assert %{slot_mapping: [_]} = errors(cs)
    end
  end

  defp valid_changeset(overrides) do
    base = %{
      "module_key" => "publishing",
      "scope_type" => "default",
      "template_uuid" => @template_uuid
    }

    Assignment.changeset(%Assignment{}, Map.merge(base, overrides))
  end

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
