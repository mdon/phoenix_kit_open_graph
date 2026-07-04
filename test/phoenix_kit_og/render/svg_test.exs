defmodule PhoenixKitOG.Render.SvgTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOG.Render.Svg

  # Pure SVG generation — no rasterization, no DB, no filesystem.
  # We inspect the emitted string / iodata to pin the observable
  # behavior each fix depends on.

  describe "to_binary/2 — background" do
    test "solid color renders as a full-canvas rect" do
      canvas = %{
        "width" => 1200,
        "height" => 630,
        "background" => %{"type" => "color", "value" => "#0b1220"},
        "elements" => []
      }

      svg = Svg.to_binary(canvas)
      assert svg =~ ~s|<rect x="0" y="0" width="1200" height="630" fill="#0b1220"/>|
    end

    test "image with an unresolved `{{slot}}` src falls back to the fallback color" do
      canvas = %{
        "background" => %{
          "type" => "image",
          "value" => "{{Missing}}",
          "value_fallback" => "#123456"
        },
        "elements" => []
      }

      svg = Svg.to_binary(canvas, %{values: %{}})
      # Uses the fallback fill, not an <image> tag.
      assert svg =~ ~s|fill="#123456"|
      refute svg =~ "<image"
    end
  end

  describe "to_binary/2 — text elements" do
    test "text picks up the DejaVu / sans-serif fallback family" do
      canvas = %{
        "elements" => [
          %{
            "type" => "text",
            "text" => "hello",
            "font" => "Inter",
            "x" => 10,
            "y" => 20,
            "width" => 500,
            "height" => 60,
            "size" => 24
          }
        ]
      }

      svg = Svg.to_binary(canvas)
      # The fix: never emit just `font-family="Inter"`; always append a
      # widely-available fallback so text renders when the picked font
      # isn't installed on the render host (the case that made every
      # rendered PNG show up as an empty grey box).
      assert svg =~ "font-family="
      assert svg =~ "Inter"
      assert svg =~ "DejaVu Sans"
      assert svg =~ "sans-serif"
    end

    test "substitutes `{{slot}}` from the values map before emitting <text>" do
      canvas = %{
        "elements" => [
          %{
            "type" => "text",
            "text" => "{{Title}}",
            "x" => 0,
            "y" => 0,
            # Big width — keeps the text on a single tspan so we can
            # assert against the raw string without word-wrap noise.
            "width" => 1000
          }
        ]
      }

      svg = Svg.to_binary(canvas, %{values: %{"Title" => "Hello world"}})
      assert svg =~ "Hello world"
      refute svg =~ "{{Title}}"
    end

    test "escapes XML special characters in text content" do
      canvas = %{
        "elements" => [
          %{"type" => "text", "text" => "a & b < c", "x" => 0, "y" => 0, "width" => 1000}
        ]
      }

      svg = Svg.to_binary(canvas)
      assert svg =~ "a &amp; b &lt; c"
    end
  end

  describe "to_binary/2 — image elements" do
    test "unresolved `{{slot}}` src emits nothing rather than a broken href" do
      canvas = %{
        "elements" => [
          %{
            "type" => "image",
            "src" => "{{BackgroundImage}}",
            "x" => 0,
            "y" => 0,
            "width" => 100,
            "height" => 100
          }
        ]
      }

      # `resvg` would render `<image href="{{...}}"/>` as a broken image
      # icon; skipping the element entirely is preferable.
      svg = Svg.to_binary(canvas, %{values: %{}})
      refute svg =~ "{{BackgroundImage}}"
      refute svg =~ ~s|<image href="{{|
    end

    test "an absolute http URL is passed through as href" do
      canvas = %{
        "elements" => [
          %{
            "type" => "image",
            "src" => "http://example.com/image.png",
            "x" => 0,
            "y" => 0,
            "width" => 100,
            "height" => 100
          }
        ]
      }

      svg = Svg.to_binary(canvas)
      assert svg =~ ~s|href="http://example.com/image.png"|
    end

    test "a host-relative src (e.g. an unresolvable signed local-storage URL) resolves to an empty href" do
      # The rasterizer only reads `data:` URLs or local file bytes — a
      # bare `/file/...` path can't be fetched any more than a remote
      # HTTP URL can. Regression test: this used to get prepended with
      # a hardcoded `http://localhost:4000`, which broke on every real
      # deployment instead of degrading like any other unresolvable href.
      canvas = %{
        "elements" => [
          %{
            "type" => "image",
            "src" => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/ab12",
            "x" => 0,
            "y" => 0,
            "width" => 100,
            "height" => 100
          }
        ]
      }

      svg = Svg.to_binary(canvas)
      refute svg =~ "localhost"
      assert svg =~ ~s|<image href="" |
    end

    test "a data: URL passes through unchanged (used for the placeholder)" do
      data_url = "data:image/svg+xml;base64,PHN2Zy8+"

      canvas = %{
        "elements" => [
          %{
            "type" => "image",
            "src" => data_url,
            "x" => 0,
            "y" => 0,
            "width" => 100,
            "height" => 100
          }
        ]
      }

      svg = Svg.to_binary(canvas)
      assert svg =~ data_url
    end
  end

  describe "to_binary/2 — rect elements" do
    test "emits fill + stroke + stroke-width + radius from the element map" do
      canvas = %{
        "elements" => [
          %{
            "type" => "rect",
            "x" => 10,
            "y" => 20,
            "width" => 100,
            "height" => 200,
            "fill" => "#7adb42",
            "stroke" => "#16ff0f",
            "stroke_width" => 13,
            "radius" => 4
          }
        ]
      }

      svg = Svg.to_binary(canvas)
      assert svg =~ ~s|fill="#7adb42"|
      assert svg =~ ~s|stroke="#16ff0f"|
      assert svg =~ ~s|stroke-width="13"|
      assert svg =~ ~s|rx="4"|
    end
  end

  describe "to_binary/2 — determinism" do
    test "same canvas + values produce byte-identical output" do
      canvas = %{
        "width" => 1200,
        "height" => 630,
        "background" => %{"type" => "color", "value" => "#0b1220"},
        "elements" => [
          %{"type" => "text", "text" => "{{Title}}", "x" => 0, "y" => 0}
        ]
      }

      ctx = %{values: %{"Title" => "Hello"}}

      # Load-bearing for `Render.Cache` — the cache key hashes canvas +
      # values, so an identical hit MUST produce identical SVG bytes.
      assert Svg.to_binary(canvas, ctx) == Svg.to_binary(canvas, ctx)
    end
  end
end
