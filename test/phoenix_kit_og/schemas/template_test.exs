defmodule PhoenixKitOg.Schemas.TemplateTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Schemas.Template

  describe "changeset/2 — required fields" do
    test "is invalid when name is missing" do
      cs = Template.changeset(%Template{}, %{"canvas" => %{}})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors(cs)
    end

    test "is valid with just a name (canvas defaults to %{})" do
      cs = Template.changeset(%Template{}, %{"name" => "Hero"})
      assert cs.valid?
    end
  end

  describe "changeset/2 — length caps" do
    test "rejects a name longer than 255 chars" do
      cs = Template.changeset(%Template{}, %{"name" => String.duplicate("x", 256)})
      refute cs.valid?
      assert %{name: [msg]} = errors(cs)
      assert msg =~ "should be at most 255"
    end

    test "rejects a description longer than 1024 chars" do
      cs =
        Template.changeset(%Template{}, %{
          "name" => "OK",
          "description" => String.duplicate("x", 1025)
        })

      refute cs.valid?
      assert %{description: [msg]} = errors(cs)
      assert msg =~ "should be at most 1024"
    end
  end

  describe "changeset/2 — canvas shape" do
    test "accepts any map at the top level" do
      cs =
        Template.changeset(%Template{}, %{
          "name" => "OK",
          "canvas" => %{"width" => 1200, "elements" => []}
        })

      assert cs.valid?
    end

    test "rejects a non-map canvas" do
      # Ecto's `:map` field cast rejects a bare string as
      # `"is invalid"`; the custom `validate_canvas/1` only fires when
      # the field survives cast. Either shape counts as invalid input
      # — we just want to be sure it doesn't slip through.
      cs = Template.changeset(%Template{}, %{"name" => "OK", "canvas" => "not a map"})
      refute cs.valid?
      assert Map.has_key?(errors(cs), :canvas)
    end
  end

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
