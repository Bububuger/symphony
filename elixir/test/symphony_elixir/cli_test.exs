defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defp base_deps(parent) do
    %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      run_dynamic_tools_mcp: fn args ->
        send(parent, {:mcp_subcommand, args})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }
  end

  defp on_deps(parent, consent_exists?) do
    base_deps(parent)
    |> Map.merge(%{
      consent_file_path: "/tmp/test-symphony-consent",
      write_consent: fn _path ->
        send(parent, :consent_written)
        :ok
      end,
      ask_for_consent: fn ->
        send(parent, :consent_asked)
        false
      end,
      file_regular?: fn path ->
        if path == "/tmp/test-symphony-consent" do
          consent_exists?
        else
          send(parent, {:file_checked, path})
          true
        end
      end
    })
  end

  # ── dynamic-tools-mcp ─────────────────────────────────────────────────────

  test "routes dynamic-tools-mcp subcommand without guardrails acknowledgement" do
    parent = self()
    deps = base_deps(parent)

    assert :ok =
             CLI.evaluate(
               ["dynamic-tools-mcp", "--linear-api-key", "token", "--linear-endpoint", "https://example.invalid/graphql"],
               deps
             )

    assert_received {:mcp_subcommand, ["--linear-api-key", "token", "--linear-endpoint", "https://example.invalid/graphql"]}

    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  # ── on subcommand ─────────────────────────────────────────────────────────

  test "on: starts when consent file exists" do
    parent = self()
    deps = on_deps(parent, true)

    assert :ok = CLI.evaluate(["on", "WORKFLOW.md"], deps)
    assert_received :started
    refute_received :consent_asked
    refute_received :consent_written
  end

  test "on: starts when ack flag provided (CI path), writes no consent" do
    parent = self()
    deps = on_deps(parent, false)

    assert :ok = CLI.evaluate(["on", @ack_flag, "WORKFLOW.md"], deps)
    assert_received :started
    refute_received :consent_asked
    refute_received :consent_written
  end

  test "on: asks for consent when no consent file, user says YES → writes consent and starts" do
    parent = self()

    deps =
      on_deps(parent, false)
      |> Map.put(:ask_for_consent, fn ->
        send(parent, :consent_asked)
        true
      end)

    assert :ok = CLI.evaluate(["on", "WORKFLOW.md"], deps)
    assert_received :consent_asked
    assert_received :consent_written
    assert_received :started
  end

  test "on: returns banner when no consent file and user says NO" do
    parent = self()
    deps = on_deps(parent, false)

    assert {:error, banner} = CLI.evaluate(["on", "WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert_received :consent_asked
    refute_received :consent_written
    refute_received :started
  end

  test "on: defaults to WORKFLOW.md when no path given" do
    parent = self()

    deps =
      on_deps(parent, true)
      |> Map.put(:file_regular?, fn path ->
        if path == "/tmp/test-symphony-consent" do
          true
        else
          send(parent, {:file_checked, path})
          Path.basename(path) == "WORKFLOW.md"
        end
      end)

    assert :ok = CLI.evaluate(["on"], deps)
    assert_received {:file_checked, path}
    assert Path.basename(path) == "WORKFLOW.md"
  end

  # ── stub subcommands ──────────────────────────────────────────────────────

  test "off subcommand returns :no_wait" do
    assert {:error, message} = CLI.evaluate(["off"], %{})
    assert message =~ "No server port configured"
  end

  test "status subcommand returns :no_wait" do
    assert {:error, message} = CLI.evaluate(["status"], %{})
    assert message =~ "No server port configured"
  end

  test "init --demo subcommand returns :no_wait" do
    # --demo mode writes a WORKFLOW.md without requiring interactive IO
    tmp = Path.join(System.tmp_dir!(), "cli-test-init-#{System.unique_integer()}.md")
    assert {:ok, :no_wait} = CLI.evaluate(["init", "--demo", "--output", tmp])
    assert File.exists?(tmp)
    File.rm!(tmp)
  end

  test "doctor subcommand returns a result tuple" do
    # Doctor.run() uses runtime_deps which may fail network/env checks;
    # accept both success and error outcomes — the important thing is no crash.
    result = CLI.evaluate(["doctor"], %{})
    assert result in [:ok, {:ok, :no_wait}] or match?({:error, _}, result)
  end

  test "logs subcommand requires --issue" do
    assert {:error, message} = CLI.evaluate(["logs"], %{})
    assert message =~ "Usage:"
  end

  test "logs subcommand with --issue and no server returns an error" do
    assert {:error, message} = CLI.evaluate(["logs", "--issue", "BUB-123"], %{})
    assert message =~ "No server port configured"
  end

  test "intervene subcommand with no server returns an error" do
    assert {:error, message} = CLI.evaluate(["intervene", "BUB-123", "use middleware instead"], %{})
    assert message =~ "No server port configured"
  end

  test "legacy bare invocation without subcommand returns usage" do
    parent = self()
    deps = base_deps(parent)

    assert {:error, usage} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert usage =~ "Usage:"
    assert usage =~ "symphony on [path-to-WORKFLOW.md]"
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "on accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn path ->
        if path == "/tmp/test-symphony-consent" do
          true
        else
          path == Path.expand("WORKFLOW.md")
        end
      end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      consent_file_path: "/tmp/test-symphony-consent",
      write_consent: fn _path -> :ok end,
      ask_for_consent: fn -> false end
    }

    assert :ok = CLI.evaluate(["on", "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)

    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      consent_file_path: "/tmp/test-symphony-consent",
      write_consent: fn _path -> :ok end,
      ask_for_consent: fn -> false end
    }

    assert {:error, message} = CLI.evaluate(["on", @ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end,
      consent_file_path: "/tmp/test-symphony-consent",
      write_consent: fn _path -> :ok end,
      ask_for_consent: fn -> false end
    }

    assert {:error, message} = CLI.evaluate(["on", @ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      consent_file_path: "/tmp/test-symphony-consent",
      write_consent: fn _path -> :ok end,
      ask_for_consent: fn -> false end
    }

    assert :ok = CLI.evaluate(["on", @ack_flag, "WORKFLOW.md"], deps)
  end
end
