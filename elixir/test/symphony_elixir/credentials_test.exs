defmodule SymphonyElixir.CredentialsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Credentials

  # Build injectable test deps with overridable sources
  defp test_deps(overrides \\ %{}) do
    defaults = %{
      env_fn: fn _key -> nil end,
      read_file: fn _path -> {:error, :enoent} end,
      keychain_fn: fn _key -> nil end,
      cwd_fn: fn -> "/tmp/test-cwd" end
    }

    Map.merge(defaults, overrides)
  end

  # ── env var (source 1) ────────────────────────────────────────────────────

  test "returns env var when present" do
    deps = test_deps(%{env_fn: fn "MY_KEY" -> "env-value" end})
    assert Credentials.resolve("MY_KEY", deps) == "env-value"
  end

  test "skips env var when nil and tries next source" do
    deps = test_deps(%{
      env_fn: fn _key -> nil end,
      read_file: fn "~/.config/symphony/credentials.json" ->
        {:ok, ~s({"MY_KEY": "from-json"})}

        path ->
          {:error, {:enoent, path}}
      end
    })

    # credentials.json key lookup uses Path.expand so we match the expanded path
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      env_fn: fn _key -> nil end,
      read_file: fn ^credentials_path -> {:ok, ~s({"MY_KEY": "from-json"})}
                   _path -> {:error, :enoent}
                 end
    })

    assert Credentials.resolve("MY_KEY", deps) == "from-json"
  end

  # ── credentials.json (source 2) ───────────────────────────────────────────

  test "reads key from credentials.json" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      read_file: fn ^credentials_path -> {:ok, ~s({"LINEAR_API_KEY": "json-token"})}
                   _path -> {:error, :enoent}
                 end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "json-token"
  end

  test "skips credentials.json when key not present" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      read_file: fn ^credentials_path -> {:ok, ~s({"OTHER_KEY": "other-value"})}
                   _path -> {:error, :enoent}
                 end,
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-token" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "keychain-token"
  end

  test "skips credentials.json when file does not exist" do
    deps = test_deps(%{
      read_file: fn _path -> {:error, :enoent} end,
      keychain_fn: fn _key -> "keychain-fallback" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "keychain-fallback"
  end

  test "skips credentials.json when JSON is invalid" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      read_file: fn ^credentials_path -> {:ok, "not-json"}
                   _path -> {:error, :enoent}
                 end,
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-fallback" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "keychain-fallback"
  end

  test "treats empty string in credentials.json as missing" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      read_file: fn ^credentials_path -> {:ok, ~s({"LINEAR_API_KEY": ""})}
                   _path -> {:error, :enoent}
                 end,
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-fallback" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "keychain-fallback"
  end

  # ── macOS Keychain (source 3) ─────────────────────────────────────────────

  test "returns keychain value when present" do
    deps = test_deps(%{
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-token" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "keychain-token"
  end

  test "skips keychain when nil and falls through to .env" do
    dir = "/tmp/test-cwd-dotenv-keychain-#{System.unique_integer()}"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "LINEAR_API_KEY=dotenv-token\n")

    deps = test_deps(%{
      keychain_fn: fn _key -> nil end,
      read_file: &File.read/1,
      cwd_fn: fn -> dir end
    })

    try do
      assert Credentials.resolve("LINEAR_API_KEY", deps) == "dotenv-token"
    after
      File.rm_rf!(dir)
    end
  end

  # ── .env file (source 4) ──────────────────────────────────────────────────

  test "reads key from .env file" do
    dir = "/tmp/test-cwd-dotenv-#{System.unique_integer()}"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "LINEAR_API_KEY=dotenv-token\n")

    deps = test_deps(%{
      read_file: &File.read/1,
      cwd_fn: fn -> dir end
    })

    try do
      assert Credentials.resolve("LINEAR_API_KEY", deps) == "dotenv-token"
    after
      File.rm_rf!(dir)
    end
  end

  test "strips double quotes from .env value" do
    dir = "/tmp/test-cwd-dotenv-#{System.unique_integer()}"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), ~s(LINEAR_API_KEY="quoted-token"\n))

    deps = test_deps(%{
      read_file: &File.read/1,
      cwd_fn: fn -> dir end
    })

    try do
      assert Credentials.resolve("LINEAR_API_KEY", deps) == "quoted-token"
    after
      File.rm_rf!(dir)
    end
  end

  test "strips single quotes from .env value" do
    dir = "/tmp/test-cwd-dotenv-sq-#{System.unique_integer()}"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "LINEAR_API_KEY='single-quoted'\n")

    deps = test_deps(%{
      read_file: &File.read/1,
      cwd_fn: fn -> dir end
    })

    try do
      assert Credentials.resolve("LINEAR_API_KEY", deps) == "single-quoted"
    after
      File.rm_rf!(dir)
    end
  end

  test "skips comment lines in .env" do
    dir = "/tmp/test-cwd-dotenv-comment-#{System.unique_integer()}"
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, ".env"), """
    # This is a comment
    OTHER=val
    LINEAR_API_KEY=found-it
    """)

    deps = test_deps(%{
      read_file: &File.read/1,
      cwd_fn: fn -> dir end
    })

    try do
      assert Credentials.resolve("LINEAR_API_KEY", deps) == "found-it"
    after
      File.rm_rf!(dir)
    end
  end

  test "returns nil when key not found in any source" do
    assert Credentials.resolve("MISSING_KEY", test_deps()) == nil
  end

  # ── priority ordering ─────────────────────────────────────────────────────

  test "env var takes precedence over credentials.json" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      env_fn: fn "LINEAR_API_KEY" -> "env-wins" end,
      read_file: fn ^credentials_path -> {:ok, ~s({"LINEAR_API_KEY": "json-value"})}
                   _path -> {:error, :enoent}
                 end,
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-value" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "env-wins"
  end

  test "credentials.json takes precedence over keychain" do
    credentials_path = Path.expand("~/.config/symphony/credentials.json")

    deps = test_deps(%{
      read_file: fn ^credentials_path -> {:ok, ~s({"LINEAR_API_KEY": "json-wins"})}
                   _path -> {:error, :enoent}
                 end,
      keychain_fn: fn "LINEAR_API_KEY" -> "keychain-value" end
    })

    assert Credentials.resolve("LINEAR_API_KEY", deps) == "json-wins"
  end
end
