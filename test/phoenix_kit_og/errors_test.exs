defmodule PhoenixKitOg.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Errors

  describe "message/1 — known atoms" do
    test "returns a translated string for each supported atom" do
      # Each atom's message is wrapped in gettext — we just check the
      # dispatch runs and returns a non-empty binary. The exact wording
      # is UI copy and shouldn't be pinned here.
      for atom <- [:not_found, :rasterizer_missing, :template_missing, :group_missing] do
        assert is_binary(Errors.message(atom))
        assert Errors.message(atom) != ""
      end
    end
  end

  describe "message/1 — tagged tuples" do
    test "{:render_failed, reason} interpolates the reason" do
      msg = Errors.message({:render_failed, :timeout})
      assert String.contains?(msg, "timeout")
    end

    test "very long reasons are truncated with an ellipsis" do
      long_reason = String.duplicate("a", 500)
      msg = Errors.message({:render_failed, long_reason})
      # 100-char cap + trailing ellipsis; the raw 500-char blob never
      # reaches a flash.
      assert String.contains?(msg, "…")
      refute String.contains?(msg, String.duplicate("a", 200))
    end
  end

  describe "message/1 — pass-through shapes" do
    test "an %Ecto.Changeset{} is returned as-is (renderable by <.input>)" do
      cs = %Ecto.Changeset{}
      assert Errors.message(cs) == cs
    end

    test "a plain string is returned unchanged" do
      assert Errors.message("already translated") == "already translated"
    end
  end

  describe "message/1 — fallback" do
    test "unexpected shapes are wrapped, not raised" do
      msg = Errors.message({:some_new_reason, :with_data})
      assert is_binary(msg)
      # The wrapper mentions "Unexpected" so surfaces stay traceable
      # in production logs.
      assert String.contains?(msg, "Unexpected") or String.contains?(msg, "unexpected")
    end
  end
end
