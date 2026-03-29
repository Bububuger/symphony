defmodule SymphonyElixir.AgentRunner.Worker do
  @moduledoc """
  OTP Task wrapper around `AgentRunner.run/3` that can be distributed via
  `Horde.DynamicSupervisor` across cluster nodes.

  The Coordinator (on any node) starts this worker via
  `Horde.DynamicSupervisor.start_child/2`. Horde places it on the least-loaded
  cluster member. Erlang distribution transparently handles cross-node
  `Process.monitor/1` and `send/2`, so the Coordinator receives `:DOWN` and
  progress messages regardless of which node the worker runs on.
  """

  use Task, restart: :temporary

  require Logger

  @spec start_link(map()) :: {:ok, pid()} | {:error, term()}
  def start_link(%{issue: _, recipient: _, trace_id: _} = args) do
    Task.start_link(__MODULE__, :run, [args])
  end

  @doc false
  def run(%{
        issue: issue,
        runtime: runtime,
        attempt: attempt,
        recipient: recipient,
        trace_id: trace_id,
        max_turns: max_turns,
        active_states: active_states,
        context_window_tokens: context_window_tokens
      }) do
    Logger.metadata(trace_id: trace_id, issue_identifier: issue.identifier)

    SymphonyElixir.AgentRunner.run(
      issue,
      recipient,
      attempt: attempt,
      trace_id: trace_id,
      runtime: runtime,
      max_turns: max_turns,
      active_states: active_states,
      context_window_tokens: context_window_tokens
    )
  end
end
