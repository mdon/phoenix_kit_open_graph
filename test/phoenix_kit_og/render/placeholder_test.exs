defmodule PhoenixKitOg.Render.PlaceholderTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Render.Placeholder

  test "data_url/0 is a base64 SVG data URL" do
    url = Placeholder.data_url()
    assert String.starts_with?(url, "data:image/svg+xml;base64,")

    "data:image/svg+xml;base64," <> b64 = url
    assert {:ok, decoded} = Base.decode64(b64)
    assert String.contains?(decoded, "<svg")
    assert String.contains?(decoded, "Placeholder image")
  end

  test "svg/0 returns the raw SVG source" do
    svg = Placeholder.svg()
    assert String.contains?(svg, "viewBox=\"0 0 400 400\"")
  end
end
