defmodule SymphonyElixir.CoordinatorStarter do
  @moduledoc """
  Leader-election wrapper that ensures exactly one Orchestrator runs cluster-wide.

  On startup, each node races to register `:symphony_coordinator` via `:global`.

  * **Winner** (`:yes`) — starts `SymphonyElixir.Orchestrator` locally and monitors it.
    The global name resolves to *this* process so that cross-node webhook events
    (`{:webhook_issue_event, data}`) are forwarded to the local Orchestrator.
  * **Loser** (`:no`) — becomes a follower: monitors the remote coordinator and
    restarts when it disappears to trigger a new election.

  On single-node deployments `:global` still works correctly; the first (and only)
  node always wins the election.
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    case :global.register_name(:symphony_coordinator, self()) do
      :yes ->
        Logger.info("[CoordinatorStarter] Won leader election — starting Orchestrator on #{node()}")
        {:ok, pid} = SymphonyElixir.Orchestrator.start_link([])
        Process.monitor(pid)
        {:ok, %{role: :coordinator, orchestrator_pid: pid}}

      :no ->
        case :global.whereis_name(:symphony_coordinator) do
          :undefined ->
            # Rare race: name was released between register_name and whereis_name
            Logger.warning("[CoordinatorStarter] Lost election but coordinator not found — retrying")
            {:stop, :coordinator_not_found}

          pid ->
            Logger.info("[CoordinatorStarter] Follower on #{node()} — monitoring coordinator at #{inspect(pid)}")
            Process.monitor(pid)
            {:ok, %{role: :follower, orchestrator_pid: nil}}
        end
    end
  end

  # Forward webhook events to local Orchestrator (coordinator only)
  @impl true
  def handle_info({:webhook_issue_event, _} = msg, %{orchestrator_pid: pid} = state)
      when is_pid(pid) do
    send(pid, msg)
    {:noreply, state}
  end

  # Follower nodes receive webhook events directed at `:symphony_coordinator` —
  # this can happen if the routing lookup races with a leader change.
  # Safe to drop: the new coordinator will poll on its next tick.
  def handle_info({:webhook_issue_event, _}, state) do
    {:noreply, state}
  end

  # Orchestrator (coordinator) or remote coordinator (follower) went down.
  # Stop so the supervisor restarts us and triggers a new election.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("[CoordinatorStarter] Monitored process down (#{inspect(reason)}) — restarting for re-election")
    {:stop, :monitored_process_down, state}
  end
end
