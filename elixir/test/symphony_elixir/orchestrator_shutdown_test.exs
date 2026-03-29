defmodule SymphonyElixir.OrchestratorShutdownTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  defp base_state do
    %State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 10,
      next_poll_due_at_ms: 1_000,
      poll_check_in_progress: false,
      shutdown_in_progress?: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{}
    }
  end

  describe "initiate_shutdown" do
    test "marks the orchestrator as shutting down and clears the next tick" do
      timer_ref = Process.send_after(self(), :orchestrator_shutdown_test_tick, 60_000)
      tick_token = make_ref()

      state =
        base_state()
        |> Map.put(:tick_timer_ref, timer_ref)
        |> Map.put(:tick_token, tick_token)
        |> Map.put(:next_poll_due_at_ms, System.monotonic_time(:millisecond) + 60_000)

      assert {:reply, :ok, next_state} =
               Orchestrator.handle_call({:initiate_shutdown, 0}, {self(), make_ref()}, state)

      assert next_state.shutdown_in_progress? == true
      assert next_state.tick_timer_ref == nil
      assert next_state.tick_token == nil
      assert next_state.next_poll_due_at_ms == nil
      assert next_state.poll_check_in_progress == false
    end
  end

  describe "request_refresh during shutdown" do
    test "does not queue another poll cycle" do
      state = %{base_state() | shutdown_in_progress?: true, next_poll_due_at_ms: nil}

      assert {:reply, reply, next_state} =
               Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

      assert reply.queued == false
      assert reply.coalesced == true
      assert reply.operations == []
      assert %DateTime{} = reply.requested_at
      assert next_state.shutdown_in_progress? == true
      assert next_state.tick_timer_ref == nil
      assert next_state.tick_token == nil
      assert next_state.next_poll_due_at_ms == nil
    end
  end

  describe "queued poll messages during shutdown" do
    test "run_poll_cycle becomes a no-op" do
      state = %{base_state() | shutdown_in_progress?: true, poll_check_in_progress: true}

      assert {:noreply, next_state} = Orchestrator.handle_info(:run_poll_cycle, state)

      assert next_state.shutdown_in_progress? == true
      assert next_state.poll_check_in_progress == false
      assert next_state.tick_timer_ref == nil
      assert next_state.next_poll_due_at_ms == 1_000
    end

    test "tick messages are ignored once shutdown has started" do
      assert {:noreply, next_state} =
               Orchestrator.handle_info({:tick, make_ref()}, %{base_state() | shutdown_in_progress?: true})

      assert next_state.shutdown_in_progress? == true
      assert next_state.poll_check_in_progress == false
    end
  end
end
