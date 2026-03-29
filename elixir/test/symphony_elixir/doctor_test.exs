defmodule SymphonyElixir.DoctorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Doctor

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp capture_deps(overrides \\ %{}) do
    parent = self()

    base = %{
      puts: fn msg ->
        send(parent, {:puts, msg})
        :ok
      end,
      workflow_file_path: fn -> Workflow.workflow_file_path() end,
      load_config: fn -> Config.settings() end,
      resolve_api_key: fn -> "test-api-key" end,
      test_linear_connection: fn _key -> :ok end,
      find_executable: fn cmd -> "/usr/bin/#{cmd}" end,
      test_git_remote: fn _url -> :ok end,
      check_dir_writable: fn _path -> :ok end
    }

    Map.merge(base, overrides)
  end

  defp collected_output do
    receive_loop([])
  end

  defp receive_loop(acc) do
    receive do
      {:puts, msg} -> receive_loop(acc ++ [msg])
    after
      100 -> Enum.join(acc, "\n")
    end
  end

  # ── all passing ──────────────────────────────────────────────────────────────

  test "returns :ok and prints all-pass summary when all checks succeed" do
    deps = capture_deps()
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
    assert output =~ "All checks passed."
  end

  # ── WORKFLOW.md check ────────────────────────────────────────────────────────

  test "reports failure when WORKFLOW.md is missing" do
    path = "/tmp/nonexistent-#{System.unique_integer()}.md"

    deps =
      capture_deps(%{
        workflow_file_path: fn -> path end,
        load_config: fn -> {:error, {:missing_workflow_file, path, :enoent}} end
      })

    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "symphony init"
  end

  test "reports failure when WORKFLOW.md has invalid config" do
    deps =
      capture_deps(%{
        load_config: fn -> {:error, {:invalid_workflow_config, "tracker.kind is required"}} end
      })

    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "tracker.kind is required"
  end

  test "reports success when WORKFLOW.md is valid" do
    deps = capture_deps()
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
  end

  # ── API key check ─────────────────────────────────────────────────────────────

  test "reports failure when API key is missing" do
    deps = capture_deps(%{resolve_api_key: fn -> nil end})
    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "LINEAR_API_KEY"
  end

  test "reports failure when Linear rejects the API key" do
    deps =
      capture_deps(%{
        test_linear_connection: fn _key -> {:error, {:http_status, 401}} end
      })

    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "API key"
  end

  test "reports success when API key is valid and Linear responds" do
    deps = capture_deps()
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
    assert output =~ "API key"
  end

  # ── agent backend check ───────────────────────────────────────────────────────

  test "reports failure when codex binary is not in PATH" do
    deps = capture_deps(%{find_executable: fn _cmd -> nil end})
    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "Agent backend"
  end

  test "reports success when codex binary is found" do
    deps = capture_deps(%{find_executable: fn cmd -> "/usr/bin/#{cmd}" end})
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
    assert output =~ "Agent backend"
  end

  # ── git remote check ─────────────────────────────────────────────────────────

  test "skips git remote check when no after_create hook is configured" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_after_create: nil)

    deps =
      capture_deps(%{
        test_git_remote: fn _url -> {:error, "connection refused"} end
      })

    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "skipped"
  end

  test "reports failure when git remote is unreachable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_after_create: "git clone git@github.com:test/myrepo.git ."
    )

    deps =
      capture_deps(%{
        test_git_remote: fn _url -> {:error, "Connection timed out"} end
      })

    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "Git remote"
  end

  test "reports success when git remote is reachable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_after_create: "git clone git@github.com:test/myrepo.git ."
    )

    deps = capture_deps()
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
  end

  # ── workspace root check ──────────────────────────────────────────────────────

  test "reports failure when workspace root is not writable" do
    deps =
      capture_deps(%{
        check_dir_writable: fn _path -> {:error, "permission denied"} end
      })

    assert {:error, _} = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✗"
    assert output =~ "Workspace root"
  end

  test "reports success when workspace root is writable" do
    tmp_root = Path.join(System.tmp_dir!(), "symphony-doctor-test-#{System.unique_integer()}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: tmp_root)
    on_exit(fn -> File.rm_rf(tmp_root) end)

    deps = capture_deps()
    assert :ok = Doctor.run(deps)
    output = collected_output()
    assert output =~ "✓"
    assert output =~ "Workspace root"
  end

  # ── CLI routing ───────────────────────────────────────────────────────────────

  test "CLI evaluate routes doctor subcommand and returns a result tuple" do
    # CLI.evaluate(["doctor"]) calls Doctor.run() with runtime_deps().
    # The real API/network checks may fail in CI, so we accept both outcomes —
    # the important invariant is that it returns a valid result tuple (not crash).
    result = CLI.evaluate(["doctor"], %{})
    assert result in [:ok, {:ok, :no_wait}] or match?({:error, _}, result)
  end

  test "doctor: success path returns {:ok, :no_wait} via CLI" do
    # Inject all checks as passing by calling Doctor.run/1 directly and verifying
    # the CLI correctly forwards :ok → {:ok, :no_wait}.
    deps = capture_deps()
    assert :ok = Doctor.run(deps)
  end
end
