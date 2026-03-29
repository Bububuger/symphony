defmodule SymphonyElixir.ActivityLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ActivityLog

  # Each test starts its own isolated ActivityLog GenServer so tests don't
  # share state.
  setup do
    {:ok, pid} = start_supervised({ActivityLog, name: nil})
    %{log: pid}
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp append(pid, issue_id, event, opts \\ []) do
    turn = Keyword.get(opts, :turn, 0)
    detail = Keyword.get(opts, :detail, nil)
    ts = Keyword.get(opts, :timestamp, utc_now())
    tokens = Keyword.get(opts, :tokens, %{input: 0, output: 0})

    GenServer.cast(pid, {:append, issue_id, %{
      event: event,
      timestamp: ts,
      turn: turn,
      detail: detail,
      tokens: tokens
    }})
  end

  defp get(pid, issue_id) do
    GenServer.call(pid, {:get, issue_id})
  end

  defp get_since(pid, issue_id, since) do
    GenServer.call(pid, {:get_since, issue_id, since})
  end

  defp complete(pid, issue_id, event_name) do
    GenServer.cast(pid, {:complete, issue_id, %{
      event: event_name,
      timestamp: utc_now(),
      turn: 0,
      detail: nil,
      tokens: %{input: 0, output: 0}
    }})
  end

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp dt_ago_iso8601(seconds) do
    DateTime.utc_now()
    |> DateTime.add(-seconds, :second)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp dt_future_iso8601(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  # Wait for all casts to be processed
  defp flush(pid) do
    :sys.get_state(pid)
    :ok
  end

  # ── tests ─────────────────────────────────────────────────────────────────────

  describe "append/get" do
    test "empty log returns empty list", %{log: pid} do
      assert get(pid, "issue-1") == []
    end

    test "appended events are returned newest first", %{log: pid} do
      append(pid, "issue-1", "turn_started")
      append(pid, "issue-1", "tool_called")
      append(pid, "issue-1", "turn_completed")
      flush(pid)

      events = get(pid, "issue-1")
      assert length(events) == 3
      assert Enum.at(events, 0).event == "turn_completed"
      assert Enum.at(events, 1).event == "tool_called"
      assert Enum.at(events, 2).event == "turn_started"
    end

    test "events for different issues are isolated", %{log: pid} do
      append(pid, "issue-A", "turn_started")
      append(pid, "issue-B", "tool_called")
      flush(pid)

      assert length(get(pid, "issue-A")) == 1
      assert Enum.at(get(pid, "issue-A"), 0).event == "turn_started"
      assert length(get(pid, "issue-B")) == 1
      assert Enum.at(get(pid, "issue-B"), 0).event == "tool_called"
    end

    test "event struct contains required fields", %{log: pid} do
      append(pid, "issue-1", "turn_started", turn: 3, detail: "some detail", tokens: %{input: 10, output: 5})
      flush(pid)

      [event] = get(pid, "issue-1")
      assert is_binary(event.timestamp)
      assert event.event == "turn_started"
      assert event.turn == 3
      assert event.detail == "some detail"
      assert event.tokens == %{input: 10, output: 5}
    end

    test "atom event names are normalised to strings", %{log: pid} do
      append(pid, "issue-1", :turn_started)
      flush(pid)

      [event] = get(pid, "issue-1")
      assert is_binary(event.event)
      assert event.event == "turn_started"
    end
  end

  describe "500-event ring buffer" do
    test "at 500 events all are retained", %{log: pid} do
      for i <- 1..500 do
        append(pid, "issue-ring", "turn_started", turn: i)
      end
      flush(pid)

      events = get(pid, "issue-ring")
      assert length(events) == 500
    end

    test "501st event evicts the oldest, keeping 500", %{log: pid} do
      for i <- 1..501 do
        append(pid, "issue-ring", "event-#{i}", turn: i)
      end
      flush(pid)

      events = get(pid, "issue-ring")
      assert length(events) == 500
      # newest first: last event is turn=501, oldest retained is turn=2
      assert Enum.at(events, 0).turn == 501
      assert Enum.at(events, 499).turn == 2
    end

    test "after 600 events the oldest 100 are evicted", %{log: pid} do
      for i <- 1..600 do
        append(pid, "issue-ring", "event-#{i}", turn: i)
      end
      flush(pid)

      events = get(pid, "issue-ring")
      assert length(events) == 500
      # oldest retained should have turn == 101
      oldest = events |> Enum.min_by(& &1.turn)
      assert oldest.turn == 101
    end
  end

  describe "get_since" do
    test "returns events with timestamp strictly after since", %{log: pid} do
      past = dt_ago_iso8601(10)
      recent = dt_ago_iso8601(2)

      append(pid, "issue-1", "old_event", timestamp: past)
      append(pid, "issue-1", "new_event", timestamp: recent)
      flush(pid)

      # since 5 seconds ago: only new_event should appear
      since = dt_ago_iso8601(5)
      events = get_since(pid, "issue-1", since)
      assert length(events) == 1
      assert Enum.at(events, 0).event == "new_event"
    end

    test "returns empty list for nil since", %{log: pid} do
      append(pid, "issue-1", "turn_started")
      flush(pid)

      assert get_since(pid, "issue-1", nil) == []
    end

    test "returns empty list for unparseable since", %{log: pid} do
      append(pid, "issue-1", "turn_started")
      flush(pid)

      assert get_since(pid, "issue-1", "not-a-date") == []
    end

    test "returns empty when all events are older than since", %{log: pid} do
      past = dt_ago_iso8601(20)
      append(pid, "issue-1", "old_event", timestamp: past)
      flush(pid)

      since = dt_ago_iso8601(5)
      assert get_since(pid, "issue-1", since) == []
    end

    test "since equal to event timestamp excludes that event (strictly after)", %{log: pid} do
      ts = dt_ago_iso8601(5)
      append(pid, "issue-1", "boundary_event", timestamp: ts)
      flush(pid)

      # using same timestamp as since — should be excluded
      assert get_since(pid, "issue-1", ts) == []
    end

    test "returns all events when since is far in the past", %{log: pid} do
      append(pid, "issue-1", "event_a")
      append(pid, "issue-1", "event_b")
      flush(pid)

      since = dt_ago_iso8601(9_999)
      events = get_since(pid, "issue-1", since)
      assert length(events) == 2
    end

    test "since in the future returns empty list", %{log: pid} do
      append(pid, "issue-1", "turn_started")
      flush(pid)

      future = dt_future_iso8601(3600)
      assert get_since(pid, "issue-1", future) == []
    end
  end

  describe "detail truncation" do
    test "detail longer than 2048 bytes is truncated to 2048 chars", %{log: pid} do
      long_detail = String.duplicate("x", 3000)
      append(pid, "issue-1", "turn_started", detail: long_detail)
      flush(pid)

      [event] = get(pid, "issue-1")
      assert String.length(event.detail) == 2048
    end

    test "nil detail stays nil", %{log: pid} do
      append(pid, "issue-1", "turn_started", detail: nil)
      flush(pid)

      [event] = get(pid, "issue-1")
      assert event.detail == nil
    end

    test "detail within 2048 bytes is preserved", %{log: pid} do
      detail = String.duplicate("y", 100)
      append(pid, "issue-1", "turn_started", detail: detail)
      flush(pid)

      [event] = get(pid, "issue-1")
      assert event.detail == detail
    end
  end

  describe "complete/FIFO eviction (20 issue limit)" do
    test "completing an issue moves it to completed store", %{log: pid} do
      append(pid, "issue-1", "turn_started")
      complete(pid, "issue-1", "issue_completed")
      flush(pid)

      events = get(pid, "issue-1")
      assert length(events) >= 2
      # last event is the outcome
      [newest | _] = events
      assert newest.event == "issue_completed"
    end

    test "get returns completed log after running log is cleared", %{log: pid} do
      append(pid, "issue-c", "turn_started")
      append(pid, "issue-c", "tool_called")
      complete(pid, "issue-c", "issue_completed")
      flush(pid)

      events = get(pid, "issue-c")
      # 2 running events + 1 final = 3 events
      assert length(events) == 3
    end

    test "at 20 completed issues, 21st evicts oldest", %{log: pid} do
      # Complete 20 issues
      for i <- 1..20 do
        id = "issue-comp-#{i}"
        append(pid, id, "turn_started")
        complete(pid, id, "issue_completed")
      end
      flush(pid)

      # First 20 issues should all be retrievable
      for i <- 1..20 do
        id = "issue-comp-#{i}"
        assert get(pid, id) != [], "Expected events for #{id}"
      end

      # Complete the 21st — should evict issue-comp-1
      append(pid, "issue-comp-21", "turn_started")
      complete(pid, "issue-comp-21", "issue_completed")
      flush(pid)

      assert get(pid, "issue-comp-1") == []
      assert get(pid, "issue-comp-21") != []
    end

    test "FIFO: oldest issue is evicted first among completed issues", %{log: pid} do
      for i <- 1..21 do
        id = "fifo-#{i}"
        append(pid, id, "turn_started")
        complete(pid, id, "issue_completed")
      end
      flush(pid)

      # issue 1 should be gone (oldest)
      assert get(pid, "fifo-1") == []
      # issue 2 should still be present
      assert get(pid, "fifo-2") != []
      # issue 21 (newest) should be present
      assert get(pid, "fifo-21") != []
    end

    test "running log is cleared after completion", %{log: pid} do
      append(pid, "issue-r", "turn_started")
      flush(pid)

      # Before completion: in running log
      assert length(get(pid, "issue-r")) == 1

      complete(pid, "issue-r", "issue_completed")
      flush(pid)

      # Still retrievable (now from completed log)
      events = get(pid, "issue-r")
      assert length(events) >= 1
    end
  end
end
