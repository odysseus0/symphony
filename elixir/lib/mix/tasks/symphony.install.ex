defmodule Mix.Tasks.Symphony.Install do
  @shortdoc "Symlink Symphony scripts (e.g. cursor-symphony-bridge) into ~/.local/bin"
  @moduledoc """
  Creates symlinks in `~/.local/bin` for executable scripts shipped in the
  Symphony `scripts/` directory so they are available on the user's PATH.

  This mirrors the pattern used by the Cursor CLI (`agent`) which is also
  symlinked into `~/.local/bin`.

      $ mix symphony.install

  The task is idempotent — re-running it updates existing symlinks to point
  at the current checkout.
  """

  use Mix.Task

  @install_dir Path.expand("~/.local/bin")

  @impl Mix.Task
  def run(_args) do
    scripts_dir =
      __DIR__
      |> Path.join("../../../../scripts")
      |> Path.expand()

    unless File.dir?(scripts_dir) do
      Mix.raise("scripts/ directory not found at #{scripts_dir}")
    end

    File.mkdir_p!(@install_dir)

    scripts_dir
    |> File.ls!()
    |> Enum.filter(fn name ->
      path = Path.join(scripts_dir, name)
      File.regular?(path) and not String.starts_with?(name, ".") and not String.ends_with?(name, ".pyc")
    end)
    |> Enum.reject(fn name -> name == "__pycache__" end)
    |> Enum.each(fn name ->
      source = Path.join(scripts_dir, name)
      target = Path.join(@install_dir, name)

      case File.read_link(target) do
        {:ok, ^source} ->
          Mix.shell().info("  already linked: #{name}")

        {:ok, _old} ->
          File.rm!(target)
          File.ln_s!(source, target)
          Mix.shell().info("  updated link:   #{name} -> #{source}")

        {:error, _} ->
          if File.exists?(target) do
            Mix.shell().error("  skipped:        #{name} (#{target} exists and is not a symlink)")
          else
            File.ln_s!(source, target)
            Mix.shell().info("  linked:         #{name} -> #{source}")
          end
      end
    end)

    Mix.shell().info("\nSymphony scripts installed to #{@install_dir}")
  end
end
