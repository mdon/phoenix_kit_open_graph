defmodule PhoenixKitOG.Web.ImageControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  # Direct unit test — bypasses the router. We build a `Plug.Test`
  # conn and call `show/2` so the controller doesn't need a running
  # endpoint / auth pipeline / DB.
  #
  # Why this level: the controller's whole job is a key-shape guard
  # plus a `File.read` off `Render.Cache`. Both testable without a
  # request roundtrip; anything higher-level would be exercising Plug
  # itself.

  alias PhoenixKitOG.Render.Cache
  alias PhoenixKitOG.Web.ImageController

  # A stable 4-byte "PNG" payload for the cache write. Content-type
  # doesn't depend on the bytes so any binary works.
  @png_bytes <<0x89, "PNG", 0x0D>>

  setup do
    # Point the cache at a per-test tmp dir so we don't collide with
    # a running dev-mode cache or need a chmod on the shared
    # /tmp/phoenix_kit_og_cache directory the elixir supervisor owns.
    tmp =
      Path.join(System.tmp_dir!(), "phoenix_kit_og_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:phoenix_kit_og, :cache_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_og, :cache_dir)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  describe "show/2 — key validation" do
    test "rejects a key with a non-hex character (400)" do
      conn = ImageController.show(conn(:get, "/og-image/abc def"), %{"key" => "abc def"})
      assert conn.status == 400
    end

    test "rejects a key longer than 64 chars (400)" do
      long = String.duplicate("a", 65)
      conn = ImageController.show(conn(:get, "/og-image/#{long}"), %{"key" => long})
      assert conn.status == 400
    end

    test "rejects an empty key (400)" do
      conn = ImageController.show(conn(:get, "/og-image/"), %{"key" => ""})
      assert conn.status == 400
    end
  end

  describe "show/2 — cache miss" do
    test "returns 404 when the cache file doesn't exist" do
      key = "0000000000000000"

      conn = ImageController.show(conn(:get, "/og-image/#{key}"), %{"key" => key})
      assert conn.status == 404
    end
  end

  describe "show/2 — cache hit" do
    test "serves the PNG with clean image/png content-type (no charset)" do
      key = "deadbeef01234567"
      :ok = Cache.write(key, @png_bytes)

      conn = ImageController.show(conn(:get, "/og-image/#{key}"), %{"key" => key})

      assert conn.status == 200
      assert conn.resp_body == @png_bytes

      # The bug this test pins: without `put_resp_content_type(_, _, nil)`
      # Phoenix appends `; charset=utf-8` and Telegram drops the OG
      # preview when it sees a text charset on a binary MIME.
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type == "image/png"
      refute content_type =~ "charset"
    end

    test "includes cache-control immutable + a content-length header" do
      key = "abcdef0123456789"
      :ok = Cache.write(key, @png_bytes)

      conn = ImageController.show(conn(:get, "/og-image/#{key}"), %{"key" => key})

      [cache_control] = Plug.Conn.get_resp_header(conn, "cache-control")
      assert cache_control =~ "immutable"
      assert cache_control =~ "public"

      [content_length] = Plug.Conn.get_resp_header(conn, "content-length")
      assert content_length == to_string(byte_size(@png_bytes))
    end
  end
end
