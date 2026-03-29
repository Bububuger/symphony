defmodule SymphonyElixir.InterventionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Intervention

  # Start an isolated Intervention GenServer per test to avoid coupling with the
  # global application instance.
  setup do
    name = :"intervention_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Intervention.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, server: name}
  end

  # ---------------------------------------------------------------------------
  # enqueue / dequeue — basic FIFO
  # ---------------------------------------------------------------------------

  test "enqueue returns :ok for a valid directive", %{server: server} do
    assert :ok == GenServer.call(server, {:enqueue, "issue-1", "do X"})
  end

  test "dequeue returns nil when queue is empty", %{server: server} do
    assert nil == GenServer.call(server, {:dequeue, "issue-1"})
  end

  test "dequeue returns nil for unknown issue", %{server: server} do
    :ok = GenServer.call(server, {:enqueue, "issue-1", "do X"})
    assert nil == GenServer.call(server, {:dequeue, "unknown-issue"})
  end

  test "FIFO ordering: directives dequeued in insertion order", %{server: server} do
    :ok = GenServer.call(server, {:enqueue, "issue-1", "first"})
    :ok = GenServer.call(server, {:enqueue, "issue-1", "second"})
    :ok = GenServer.call(server, {:enqueue, "issue-1", "third"})

    assert "first" == GenServer.call(server, {:dequeue, "issue-1"})
    assert "second" == GenServer.call(server, {:dequeue, "issue-1"})
    assert "third" == GenServer.call(server, {:dequeue, "issue-1"})
    assert nil == GenServer.call(server, {:dequeue, "issue-1"})
  end

  test "dequeue removes the directive from the queue", %{server: server} do
    :ok = GenServer.call(server, {:enqueue, "issue-1", "do X"})
    assert "do X" == GenServer.call(server, {:dequeue, "issue-1"})
    # Second dequeue returns nil because item was removed
    assert nil == GenServer.call(server, {:dequeue, "issue-1"})
  end

  # ---------------------------------------------------------------------------
  # Queue size limit
  # ---------------------------------------------------------------------------

  test "enqueue returns {:error, :queue_full} after 10 items", %{server: server} do
    Enum.each(1..10, fn i ->
      assert :ok == GenServer.call(server, {:enqueue, "issue-full", "directive #{i}"})
    end)

    assert {:error, :queue_full} == GenServer.call(server, {:enqueue, "issue-full", "overflow"})
  end

  test "queue accepts new items after dequeue frees space", %{server: server} do
    Enum.each(1..10, fn i ->
      :ok = GenServer.call(server, {:enqueue, "issue-1", "directive #{i}"})
    end)

    # Queue is full
    assert {:error, :queue_full} == GenServer.call(server, {:enqueue, "issue-1", "overflow"})

    # Dequeue one
    assert "directive 1" == GenServer.call(server, {:dequeue, "issue-1"})

    # Now can enqueue again
    assert :ok == GenServer.call(server, {:enqueue, "issue-1", "new directive"})
  end

  # ---------------------------------------------------------------------------
  # list/1 — non-destructive inspection
  # ---------------------------------------------------------------------------

  test "list returns empty list when no directives queued", %{server: server} do
    assert [] == GenServer.call(server, {:list, "issue-1"})
  end

  test "list returns all queued directives in order without removing them", %{server: server} do
    :ok = GenServer.call(server, {:enqueue, "issue-1", "alpha"})
    :ok = GenServer.call(server, {:enqueue, "issue-1", "beta"})

    assert ["alpha", "beta"] == GenServer.call(server, {:list, "issue-1"})
    # Still intact after listing
    assert ["alpha", "beta"] == GenServer.call(server, {:list, "issue-1"})
  end

  # ---------------------------------------------------------------------------
  # Per-issue isolation
  # ---------------------------------------------------------------------------

  test "queues are isolated per issue_id", %{server: server} do
    :ok = GenServer.call(server, {:enqueue, "issue-A", "for A"})
    :ok = GenServer.call(server, {:enqueue, "issue-B", "for B"})

    assert "for A" == GenServer.call(server, {:dequeue, "issue-A"})
    assert "for B" == GenServer.call(server, {:dequeue, "issue-B"})
    assert nil == GenServer.call(server, {:dequeue, "issue-A"})
    assert nil == GenServer.call(server, {:dequeue, "issue-B"})
  end

  # ---------------------------------------------------------------------------
  # Public API delegates (module-level functions call the global __MODULE__)
  # ---------------------------------------------------------------------------

  describe "public API via default process name" do
    setup do
      # Only run if the global Intervention is running (application may not be started)
      case Process.whereis(Intervention) do
        nil -> :ignore
        _pid -> :ok
      end
    end

    test "Intervention.enqueue/2 and Intervention.dequeue/1 round-trip" do
      if Process.whereis(Intervention) do
        issue_id = "test-api-#{System.unique_integer([:positive])}"
        assert :ok == Intervention.enqueue(issue_id, "directive via public api")
        assert "directive via public api" == Intervention.dequeue(issue_id)
        assert nil == Intervention.dequeue(issue_id)
      end
    end

    test "Intervention.list/1 returns pending directives" do
      if Process.whereis(Intervention) do
        issue_id = "test-list-#{System.unique_integer([:positive])}"
        :ok = Intervention.enqueue(issue_id, "list test")
        assert ["list test"] == Intervention.list(issue_id)
        Intervention.dequeue(issue_id)
      end
    end
  end
end
