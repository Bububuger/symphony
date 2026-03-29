defmodule SymphonyElixir.CompletionReportStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CompletionReportStore

  # Start an isolated CompletionReportStore per test.
  setup do
    name = :"completion_report_store_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = CompletionReportStore.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, server: name}
  end

  defp make_report(attrs \\ %{}) do
    Map.merge(
      %{
        issue_id: "id-1",
        issue_identifier: "BUB-100",
        runtime_name: "codex",
        result: :success,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        duration_ms: 5_000,
        turns: 3,
        tokens: %{input: 100, output: 200, total: 300},
        tokens_per_turn: 100.0,
        error: nil
      },
      attrs
    )
  end

  # ---------------------------------------------------------------------------
  # store/list basics
  # ---------------------------------------------------------------------------

  test "list returns empty list when no reports stored", %{server: server} do
    assert [] == GenServer.call(server, :list)
  end

  test "store and list a single report", %{server: server} do
    GenServer.cast(server, {:store, make_report()})
    :sys.get_state(server)
    reports = GenServer.call(server, :list)
    assert length(reports) == 1
    assert hd(reports).issue_identifier == "BUB-100"
  end

  test "list returns newest first", %{server: server} do
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-101"})})
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-102"})})
    :sys.get_state(server)
    [first | _] = GenServer.call(server, :list)
    assert first.issue_identifier == "BUB-102"
  end

  # ---------------------------------------------------------------------------
  # get/1
  # ---------------------------------------------------------------------------

  test "get returns nil for unknown identifier", %{server: server} do
    assert nil == GenServer.call(server, {:get, "BUB-999"})
  end

  test "get returns most recent report for a given identifier", %{server: server} do
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-200", duration_ms: 1_000})})
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-200", duration_ms: 2_000})})
    :sys.get_state(server)
    result = GenServer.call(server, {:get, "BUB-200"})
    assert result.duration_ms == 2_000
  end

  test "get returns nil for a different identifier", %{server: server} do
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-300"})})
    :sys.get_state(server)
    assert nil == GenServer.call(server, {:get, "BUB-999"})
  end

  # ---------------------------------------------------------------------------
  # Ring buffer: evicts oldest when exceeding 100 entries
  # ---------------------------------------------------------------------------

  test "ring buffer evicts oldest entry when exceeding 100 reports", %{server: server} do
    for i <- 1..101 do
      GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-#{i}", duration_ms: i})})
    end

    :sys.get_state(server)
    reports = GenServer.call(server, :list)
    assert length(reports) == 100

    identifiers = Enum.map(reports, & &1.issue_identifier)
    refute "BUB-1" in identifiers
    assert "BUB-101" in identifiers
  end

  test "ring buffer keeps exactly 100 after many stores", %{server: server} do
    for i <- 1..200 do
      GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-#{i}"})})
    end

    :sys.get_state(server)
    assert length(GenServer.call(server, :list)) == 100
  end

  # ---------------------------------------------------------------------------
  # workspace_root unavailable: store must not crash
  # ---------------------------------------------------------------------------

  test "store does not crash when Config raises (no workspace_root available)", %{server: server} do
    # Without a loaded config, Config.settings!() raises — the store should
    # rescue and skip disk persistence, but still store in memory.
    GenServer.cast(server, {:store, make_report(%{issue_identifier: "BUB-NOCONFIG"})})
    :sys.get_state(server)
    reports = GenServer.call(server, :list)
    assert Enum.any?(reports, &(&1.issue_identifier == "BUB-NOCONFIG"))
  end

  # ---------------------------------------------------------------------------
  # Public API helpers (module-level calls)
  # ---------------------------------------------------------------------------

  test "module-level store/1 is callable and list/0 returns a list" do
    # The module-level API calls __MODULE__. When the global store is
    # running (e.g. started by Application), calls succeed; when not
    # running they must return gracefully. Either way, the call must not raise.
    assert :ok == CompletionReportStore.store(make_report(%{issue_identifier: "BUB-MODULE-API"}))
    result = CompletionReportStore.list()
    assert is_list(result)
    nil_or_map = CompletionReportStore.get("BUB-UNKNOWN-99999")
    assert nil_or_map == nil
  end
end
