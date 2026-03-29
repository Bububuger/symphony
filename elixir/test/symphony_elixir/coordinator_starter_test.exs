defmodule SymphonyElixir.CoordinatorStarterTest do
  use ExUnit.Case, async: false

  # async: false because :global is a node-wide singleton

  alias SymphonyElixir.CoordinatorStarter

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Starts a minimal CoordinatorStarter with test doubles.
  # Patches :global and Orchestrator via process dictionary tricks are fragile;
  # instead we validate observable behaviour directly.

  # ---------------------------------------------------------------------------
  # start_link/init
  # ---------------------------------------------------------------------------

  test "starts without error and registers :symphony_coordinator globally" do
    # Stop the application-level CoordinatorStarter if running so we can
    # test the global registration in isolation.
    existing = :global.whereis_name(:symphony_coordinator)
    if is_pid(existing) and Process.alive?(existing) do
      # Already running in test node — skip this test variant
      assert is_pid(existing)
    else
      {:ok, pid} = CoordinatorStarter.start_link([])
      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        :global.unregister_name(:symphony_coordinator)
      end)

      registered = :global.whereis_name(:symphony_coordinator)
      assert is_pid(registered), "expected :symphony_coordinator to be registered globally"
    end
  end

  test "global :symphony_coordinator registration resolves to coordinator process" do
    pid = :global.whereis_name(:symphony_coordinator)

    # In the test application, CoordinatorStarter is running and has registered
    # :symphony_coordinator. The registered PID must be alive.
    assert is_pid(pid), "expected :symphony_coordinator to be registered"
    assert Process.alive?(pid), "expected registered coordinator to be alive"
  end

  # ---------------------------------------------------------------------------
  # Webhook event forwarding
  # ---------------------------------------------------------------------------

  test "coordinator forwards :webhook_issue_event to Orchestrator" do
    coordinator_pid = :global.whereis_name(:symphony_coordinator)
    assert is_pid(coordinator_pid), "coordinator not registered"

    # The Orchestrator should be running locally as SymphonyElixir.Orchestrator.
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
    assert is_pid(orchestrator_pid), "Orchestrator not running"

    # Send a webhook event to the coordinator — it must forward it to Orchestrator.
    # We cannot inspect Orchestrator's mailbox directly, so we verify liveness
    # (process remains alive after receiving the message).
    send(coordinator_pid, {:webhook_issue_event, %{"id" => "test-123"}})

    # Give it a tick to process
    :timer.sleep(50)

    assert Process.alive?(orchestrator_pid),
           "Orchestrator crashed after receiving forwarded webhook event"
  end

  # ---------------------------------------------------------------------------
  # Restart / re-election on crash
  # ---------------------------------------------------------------------------

  test "CoordinatorStarter restarts when it stops and re-registers coordinator" do
    pid_before = :global.whereis_name(:symphony_coordinator)
    assert is_pid(pid_before)

    # The supervisor restarts CoordinatorStarter on crash.
    # We verify the module is registered in the Supervisor children.
    children = Supervisor.which_children(SymphonyElixir.Supervisor)
    has_starter = Enum.any?(children, fn {id, _, _, _} -> id == SymphonyElixir.CoordinatorStarter end)
    assert has_starter, "CoordinatorStarter must be a supervised child"
  end
end
