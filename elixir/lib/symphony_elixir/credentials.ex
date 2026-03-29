defmodule SymphonyElixir.Credentials do
  @moduledoc """
  Multi-source credential resolution chain.

  Resolution order for a given key (e.g. `"LINEAR_API_KEY"`):
    1. Environment variable
    2. `~/.config/symphony/credentials.json`
    3. macOS Keychain (`security find-generic-password`)
    4. `.env` file in the current working directory

  Returns the first non-empty string found, or `nil` if none found.
  """

  @default_credentials_file "~/.config/symphony/credentials.json"

  @type deps :: %{
          env_fn: (String.t() -> String.t() | nil),
          read_file: (String.t() -> {:ok, String.t()} | {:error, term()}),
          keychain_fn: (String.t() -> String.t() | nil),
          cwd_fn: (-> String.t())
        }

  @spec resolve(String.t()) :: String.t() | nil
  def resolve(key) do
    case Application.get_env(:symphony_elixir, :credentials_fn) do
      fun when is_function(fun, 1) -> fun.(key)
      _ -> resolve(key, runtime_deps())
    end
  end

  @spec resolve(String.t(), deps()) :: String.t() | nil
  def resolve(key, deps) do
    deps.env_fn.(key) ||
      credentials_json_lookup(key, Path.expand(@default_credentials_file), deps) ||
      deps.keychain_fn.(key) ||
      dotenv_lookup(key, deps)
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      env_fn: &System.get_env/1,
      read_file: &File.read/1,
      keychain_fn: &keychain_lookup/1,
      # Prefer the workflow file directory; fall back to cwd if not set
      cwd_fn: fn ->
        case SymphonyElixir.Workflow.current() do
          {:ok, %{path: path}} when is_binary(path) -> Path.dirname(path)
          _ -> File.cwd!()
        end
      end
    }
  end

  # ── private helpers ──────────────────────────────────────────────────────────

  defp credentials_json_lookup(key, path, deps) do
    with {:ok, content} <- deps.read_file.(path),
         {:ok, data} when is_map(data) <- Jason.decode(content),
         value when is_binary(value) and value != "" <- Map.get(data, key) do
      value
    else
      _ -> nil
    end
  end

  defp keychain_lookup(key) do
    user = System.get_env("USER") || ""

    case System.cmd("security", ["find-generic-password", "-a", user, "-s", key, "-w"],
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp dotenv_lookup(key, deps) do
    path = Path.join(deps.cwd_fn.(), ".env")

    with {:ok, content} <- deps.read_file.(path) do
      content
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        trimmed = String.trim(line)

        # Skip comments and blank lines
        if String.starts_with?(trimmed, "#") or trimmed == "" do
          nil
        else
          case String.split(trimmed, "=", parts: 2) do
            [k, v] when k == key ->
              # Strip optional surrounding quotes
              v |> String.trim() |> unquote_value()

            _ ->
              nil
          end
        end
      end)
    else
      _ -> nil
    end
  end

  defp unquote_value("\"" <> rest) do
    case String.split_at(rest, -1) do
      {inner, "\""} -> inner
      _ -> rest
    end
  end

  defp unquote_value("'" <> rest) do
    case String.split_at(rest, -1) do
      {inner, "'"} -> inner
      _ -> rest
    end
  end

  defp unquote_value(value), do: value
end
