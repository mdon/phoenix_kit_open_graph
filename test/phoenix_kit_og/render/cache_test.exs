defmodule PhoenixKitOg.Render.CacheTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Render.Cache

  # A minimal struct-shaped map — Cache only reads the fields it hashes,
  # so we don't need the full Template schema (which requires a Repo).
  defp fake_template do
    %{
      uuid: "01234567-89ab-cdef-0123-456789abcdef",
      updated_at: ~U[2026-07-02 10:00:00Z],
      canvas: %{"width" => 1200, "height" => 630, "elements" => []}
    }
  end

  describe "key_and_path/2" do
    test "returns a 16-hex-char key + absolute path" do
      {key, path} = Cache.key_and_path(fake_template(), %{values: %{}})

      assert String.length(key) == 16
      assert Regex.match?(~r/\A[a-f0-9]{16}\z/, key)
      assert String.starts_with?(path, System.tmp_dir!())
      assert String.ends_with?(path, "#{key}.png")
    end

    test "same inputs produce the same key" do
      ctx = %{values: %{"Title" => "Hello"}, module_key: "publishing"}
      {k1, _} = Cache.key_and_path(fake_template(), ctx)
      {k2, _} = Cache.key_and_path(fake_template(), ctx)
      assert k1 == k2
    end

    test "different values produce different keys" do
      {k1, _} = Cache.key_and_path(fake_template(), %{values: %{"Title" => "A"}})
      {k2, _} = Cache.key_and_path(fake_template(), %{values: %{"Title" => "B"}})
      refute k1 == k2
    end

    test "bumping template.updated_at invalidates the key" do
      old = fake_template()
      new = %{old | updated_at: ~U[2026-07-02 11:00:00Z]}
      {k1, _} = Cache.key_and_path(old, %{values: %{}})
      {k2, _} = Cache.key_and_path(new, %{values: %{}})
      refute k1 == k2
    end
  end
end
