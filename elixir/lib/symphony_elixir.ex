defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node via the leader-election wrapper.

  In a cluster, only the first caller wins the `:global` election and runs the
  Orchestrator; subsequent nodes become followers. On a single node this behaves
  identically to starting `SymphonyElixir.Orchestrator` directly.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.CoordinatorStarter.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      # Cluster discovery: only add when topologies are configured (skipped in tests/dev).
      (if topologies != [] do
         [{Cluster.Supervisor, [topologies, [name: SymphonyElixir.ClusterSupervisor]]}]
       else
         []
       end) ++
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          # Distributed executor pool — works on single-node too (Horde is transparent).
          {Horde.DynamicSupervisor,
           name: SymphonyElixir.ExecutorPool,
           strategy: :one_for_one,
           distribution_strategy: Horde.UniformDistribution,
           members: :auto},
          # Distributed registry for cluster-wide issue claim deduplication.
          {Horde.Registry,
           name: SymphonyElixir.IssueRegistry,
           keys: :unique,
           members: :auto},
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.ActivityLog,
          SymphonyElixir.CompletionReportStore,
          SymphonyElixir.Intervention,
          SymphonyElixir.CoordinatorStarter,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]

    result =
      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )

    # After supervisor (and WorkflowStore) are running, load memory tracker issues
    # from the WORKFLOW.md config into Application env so Tracker.Memory can serve them.
    :ok = maybe_load_memory_tracker_issues()

    result
  end

  # When tracker.kind is "memory" and the WORKFLOW.md defines inline issues,
  # load them into Application env so Tracker.Memory can serve them.
  # Called after the supervisor starts so WorkflowStore is available.
  defp maybe_load_memory_tracker_issues do
    try do
      case SymphonyElixir.Config.settings() do
        {:ok, %{tracker: %{kind: "memory", memory_issues: [_ | _] = issues}}} ->
          loaded =
            Enum.map(issues, fn issue ->
              %SymphonyElixir.Linear.Issue{
                id: Map.get(issue, "id", Map.get(issue, :id, issue["identifier"] || "demo")),
                identifier: Map.get(issue, "identifier", Map.get(issue, :identifier, "")),
                title: Map.get(issue, "title", Map.get(issue, :title, "")),
                description: Map.get(issue, "description", Map.get(issue, :description, "")),
                state: Map.get(issue, "state", Map.get(issue, :state, "Todo")),
                priority: Map.get(issue, "priority", Map.get(issue, :priority, 0)),
                branch_name: Map.get(issue, "branch_name", Map.get(issue, :branch_name, nil)),
                url: Map.get(issue, "url", Map.get(issue, :url, "")),
                labels: []
              }
            end)

          existing = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])

          if existing == [] do
            Application.put_env(:symphony_elixir, :memory_tracker_issues, loaded)
          end

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
