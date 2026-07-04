defmodule PhoenixKitOG.Render.Rasterizer do
  @moduledoc """
  SVG → PNG conversion. Shells out to `rsvg-convert` (librsvg). The
  binary is part of the `librsvg2-bin` package on Debian/Ubuntu — if
  not installed, rendering returns `{:error, :rasterizer_missing}` and
  `refine_og/4` falls back to the input OG map so nothing crashes
  user-facing.

  A second backend (ImageMagick `magick`) is wired as a fallback for
  hosts without rsvg-convert, but its SVG rendering quality is lower —
  prefer rsvg.

  ## Why rsvg-convert

  - Best quality / native librsvg renderer.
  - Single dependency, very fast (~50ms per 1200×630).
  - Drop-in piping: SVG via stdin, PNG via stdout.
  """

  require Logger

  # `:resvg` is an optional dependency (see mix.exs) — hosts that don't add
  # it compile fine, they just never see `which_backend/0` return
  # `:resvg_nif` (guarded by `Code.ensure_loaded?(Resvg)` below).
  @compile {:no_warn_undefined, [Resvg]}

  @doc """
  Rasterizes the given SVG iodata/binary to a PNG binary.

  `opts`:
    * `:width` / `:height` — output size (defaults to the SVG's intrinsic
      dimensions).
    * `:timeout` — wallclock ms for the converter, default 5000.

  Errors are returned, never raised — the caller decides whether to
  return a fallback URL or 404.
  """
  @spec render(iodata() | binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def render(svg, opts \\ []) do
    backend = which_backend()
    render_with(backend, svg, opts)
  end

  @doc """
  Reports which rasterizer backend is reachable on this host.

  Preference order:

  - `:resvg_nif` — the `:resvg` Hex package's NIF (mrdotb/resvg_nif).
    Precompiled via rustler_precompiled, shipped inside `mix deps.get`.
    Zero system-install burden in the common case. This is the
    default.
  - `:resvg_cli` — `cargo install resvg` binary on PATH. Same renderer
    but as a subprocess; only used if the NIF isn't available.
  - `:rsvg` — librsvg2's `rsvg-convert`. Pipes via stdin/stdout.
  - `:magick` — ImageMagick. Last-resort fallback.
  - `:none` — no backend reachable; `refine_og/4` becomes a pass-
    through (never crashes).
  """
  @spec which_backend() :: :resvg_nif | :resvg_cli | :rsvg | :magick | :none
  def which_backend do
    cond do
      Code.ensure_loaded?(Resvg) -> :resvg_nif
      System.find_executable("resvg") -> :resvg_cli
      System.find_executable("rsvg-convert") -> :rsvg
      System.find_executable("magick") -> :magick
      System.find_executable("convert") -> :magick
      true -> :none
    end
  end

  # =========================================================================
  # Backends
  # =========================================================================

  defp render_with(:none, _svg, _opts), do: {:error, :rasterizer_missing}

  defp render_with(:resvg_nif, svg, opts) do
    # The NIF takes a keyword list of options. `resources_dir` is
    # required for the buffer variant (resvg uses it to resolve
    # relative href= in embedded `<image>` tags); we point it at the
    # tmp dir since our SVGs only carry absolute href URLs.
    resvg_opts =
      [resources_dir: System.tmp_dir!()]
      |> maybe_put(:width, opts[:width])
      |> maybe_put(:height, opts[:height])

    case Resvg.svg_string_to_png_buffer(IO.iodata_to_binary(svg), resvg_opts) do
      {:ok, bytes} -> {:ok, :erlang.list_to_binary(bytes)}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp render_with(:resvg_cli, svg, opts) do
    # resvg's CLI takes positional file args, no stdin/stdout. Round-trip
    # through unique tempfiles so concurrent renders don't trample each
    # other.
    {tmp_svg, tmp_png} = tmp_paths()

    try do
      File.write!(tmp_svg, IO.iodata_to_binary(svg))

      args =
        []
        |> maybe_arg("--width", opts[:width])
        |> maybe_arg("--height", opts[:height])
        |> Kernel.++([tmp_svg, tmp_png])

      case run_blocking("resvg", args, opts) do
        :ok -> File.read(tmp_png)
        {:error, _} = err -> err
      end
    after
      File.rm(tmp_svg)
      File.rm(tmp_png)
    end
  end

  defp render_with(:rsvg, svg, opts) do
    args = ["--format=png", "--keep-aspect-ratio"]
    args = if w = opts[:width], do: args ++ ["--width=#{w}"], else: args
    args = if h = opts[:height], do: args ++ ["--height=#{h}"], else: args

    run_pipe("rsvg-convert", args, svg, opts)
  end

  defp render_with(:magick, svg, opts) do
    args = ["svg:-"]
    args = if w = opts[:width], do: ["-resize", "#{w}x#{opts[:height] || ""}"] ++ args, else: args

    run_pipe("magick", args ++ ["png:-"], svg, opts)
  rescue
    _ ->
      # `magick` (v7) may not exist; try v6 `convert`.
      run_pipe("convert", ["svg:-", "png:-"], svg, opts)
  end

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp tmp_paths do
    base = Path.join(System.tmp_dir!(), "pk_og_#{System.unique_integer([:positive])}")
    {base <> ".svg", base <> ".png"}
  end

  # Run a binary, ignore stdout. Returns `:ok` on exit 0, `{:error, term}`
  # otherwise. Used by file-IO backends (resvg) that don't pipe bytes.
  defp run_blocking(bin, args, opts) do
    timeout = opts[:timeout] || 5_000
    path = System.find_executable(bin)

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, n}} -> {:error, {:exit, n}}
    after
      timeout ->
        if Port.info(port), do: Port.close(port)
        {:error, :timeout}
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  # =========================================================================
  # Process plumbing
  # =========================================================================

  defp run_pipe(bin, args, svg, opts) do
    timeout = opts[:timeout] || 5_000
    svg_bin = IO.iodata_to_binary(svg)

    port =
      Port.open({:spawn_executable, System.find_executable(bin)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    send(port, {self(), {:command, svg_bin}})
    send(port, {self(), :close})

    collect_port(port, <<>>, timeout)
  rescue
    e ->
      Logger.warning("[PhoenixKitOG.Rasterizer] #{bin} failed: #{Exception.message(e)}")
      {:error, {:exception, e}}
  end

  defp collect_port(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, n}} ->
        Logger.warning("[PhoenixKitOG.Rasterizer] exit #{n}: #{inspect(acc)}")
        {:error, {:exit, n}}

      {^port, :closed} ->
        {:ok, acc}
    after
      timeout ->
        if Port.info(port), do: Port.close(port)
        {:error, :timeout}
    end
  end
end
