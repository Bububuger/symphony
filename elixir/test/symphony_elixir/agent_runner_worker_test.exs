defmodule SymphonyElixir.AgentRunner.WorkerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.Worker

  # ---------------------------------------------------------------------------
  # start_link validates required keys
  # ---------------------------------------------------------------------------

  test "start_link raises on missing required keys" do
    # Pattern match in start_link requires issue/recipient/trace_id
    assert_raise FunctionClauseError, fn ->
      Worker.start_link(%{issue: nil})
    end
  end

  test "start_link/1 requires issue, recipient, and trace_id keys (guards via pattern match)" do
    # Partial maps missing required keys must raise FunctionClauseError
    assert_raise FunctionClauseError, fn ->
      Worker.start_link(%{issue: nil, recipient: self()})
    end

    assert_raise FunctionClauseError, fn ->
      Worker.start_link(%{issue: nil, trace_id: "t"})
    end
  end

  # ---------------------------------------------------------------------------
  # Horde integration: ExecutorPool accepts AgentRunner.Worker child specs
  # ---------------------------------------------------------------------------

  test "Horde.DynamicSupervisor ExecutorPool is running and accepts a child spec" do
    assert Process.whereis(SymphonyElixir.ExecutorPool) != nil,
           "ExecutorPool must be running"

    # A child spec with an invalid start MFA should fail gracefully (not crash the supervisor)
    bad_spec = %{
      id: {:test_child, System.unique_integer()},
      start: {SymphonyElixir.AgentRunner.Worker, :start_link, [%{}]},
      restart: :temporary,
      type: :worker
    }

    # Trying to start a child that will immediately crash is expected to return
    # {:error, ...} rather than raising — Horde handles it gracefully.
    result = Horde.DynamicSupervisor.start_child(SymphonyElixir.ExecutorPool, bad_spec)
    assert is_tuple(result) and elem(result, 0) in [:ok, :error]
  end
end
