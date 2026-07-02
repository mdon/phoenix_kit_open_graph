defmodule PhoenixKitOg.SlotsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Slots

  describe "used/1" do
    test "extracts unique {{slot}} references in first-appearance order" do
      canvas = %{
        "background" => %{
          "type" => "image",
          "value" => "{{BackgroundImage}}"
        },
        "elements" => [
          %{"type" => "text", "text" => "{{Title}} — {{Title}}"},
          %{"type" => "image", "src" => "{{Featured}}"},
          %{"type" => "text", "text" => "static text"}
        ]
      }

      assert Slots.used(canvas) == [
               %{name: "BackgroundImage", type: :image},
               %{name: "Title", type: :text},
               %{name: "Featured", type: :image}
             ]
    end

    test "ignores [[global]] references — those don't need wiring" do
      canvas = %{
        "elements" => [
          %{"type" => "text", "text" => "[[site_url]] is the host"},
          %{"type" => "text", "text" => "[[site_url]] again"}
        ]
      }

      assert Slots.used(canvas) == []
    end

    test "returns [] for an empty canvas" do
      assert Slots.used(%{}) == []
      assert Slots.used(%{"elements" => []}) == []
    end
  end

  describe "globals_used/1" do
    test "extracts unique [[global]] names" do
      assert Slots.globals_used("[[site_url]]/[[page_locale]]/[[site_url]]") == [
               "site_url",
               "page_locale"
             ]
    end

    test "nil and empty string are safe" do
      assert Slots.globals_used(nil) == []
      assert Slots.globals_used("") == []
    end
  end

  describe "substitute/2" do
    test "substitutes both {{slot}} and [[global]] from the same map" do
      values = %{"Title" => "Hello", "site_url" => "https://example.com"}
      text = "{{Title}} — [[site_url]]"
      assert Slots.substitute(text, values) == "Hello — https://example.com"
    end

    test "unknown names pass through unchanged" do
      assert Slots.substitute("{{Missing}}", %{}) == "{{Missing}}"
      assert Slots.substitute("[[missing]]", %{}) == "[[missing]]"
    end

    test "nil text returns empty string" do
      assert Slots.substitute(nil, %{}) == ""
    end

    test "casts non-string values via to_string/1" do
      assert Slots.substitute("{{Count}}", %{"Count" => 42}) == "42"
    end
  end
end
