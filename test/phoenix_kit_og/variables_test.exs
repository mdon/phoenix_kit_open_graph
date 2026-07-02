defmodule PhoenixKitOg.VariablesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitOg.Variables

  describe "global/0" do
    test "returns the fixed catalogue of OG-owned globals" do
      names = Variables.global() |> Enum.map(& &1.name)
      assert "site_host" in names
      assert "site_url" in names
      assert "site_name" in names
      assert "page_url" in names
      assert "page_locale" in names
    end
  end

  describe "global_values/1" do
    test "reads scheme/host/port from a Plug.Conn" do
      conn = %Plug.Conn{scheme: :https, host: "example.com", port: 443}
      values = Variables.global_values(%{conn: conn})

      assert values["site_host"] == "example.com"
      # 443 is default for https — no port suffix.
      assert values["site_url"] == "https://example.com"
    end

    test "keeps a non-default port in site_url" do
      conn = %Plug.Conn{scheme: :http, host: "localhost", port: 4000}
      values = Variables.global_values(%{conn: conn})
      assert values["site_url"] == "http://localhost:4000"
    end

    test "page_url falls back to conn.request_path when not passed" do
      conn = %Plug.Conn{scheme: :https, host: "example.com", port: 443, request_path: "/blog/x"}
      values = Variables.global_values(%{conn: conn})
      assert values["page_url"] == "https://example.com/blog/x"
    end

    test "explicit page_url wins over the conn-derived one" do
      conn = %Plug.Conn{scheme: :https, host: "example.com", port: 443, request_path: "/derived"}
      values = Variables.global_values(%{conn: conn, page_url: "/explicit"})
      assert values["page_url"] == "/explicit"
    end

    test "handles no conn gracefully" do
      values = Variables.global_values(%{})
      assert Map.has_key?(values, "site_host")
      assert Map.has_key?(values, "site_url")
    end
  end

  describe "resolve/3" do
    test "custom: prefix passes through verbatim" do
      slots = [%{name: "Title", type: :text}]
      mapping = %{"Title" => "custom:Hardcoded"}
      resolved = Variables.resolve(slots, mapping, %{module_key: "publishing"})
      assert resolved == %{"Title" => "Hardcoded"}
    end

    test "empty custom: entry resolves to empty string" do
      slots = [%{name: "Title", type: :text}]
      mapping = %{"Title" => "custom:"}
      resolved = Variables.resolve(slots, mapping, %{module_key: "publishing"})
      assert resolved == %{"Title" => ""}
    end

    test "unmapped slots are omitted from the result" do
      slots = [%{name: "Title", type: :text}, %{name: "Missing", type: :text}]
      mapping = %{"Title" => "custom:Hi"}
      resolved = Variables.resolve(slots, mapping, %{module_key: "publishing"})
      assert Map.keys(resolved) == ["Title"]
    end

    test "global variable name resolves from globals_values context" do
      slots = [%{name: "TheHost", type: :text}]
      # Wire the slot to the "site_host" global name.
      mapping = %{"TheHost" => "site_host"}

      conn = %Plug.Conn{scheme: :https, host: "example.com", port: 443}
      resolved = Variables.resolve(slots, mapping, %{module_key: "publishing", conn: conn})
      assert resolved == %{"TheHost" => "example.com"}
    end
  end
end
