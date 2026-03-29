defmodule SymphonyElixir.CompletionReportStore do
  @moduledoc """
  Stores issue completion reports in memory (ring buffer of 100) and persists
  each report as a JSON line to `{workspace_root}/.symphony/completion_log.jsonl`.
  """

  use GenServer
  require Logger

  @max_reports 100
  @log_dir ".symphony"
  @log_file "completion_log.jsonl"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Append a completion report. Silently drops if the store is unavailable."
  @spec store(map()) :: :ok
  def store(report) when is_map(report) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(__MODULE__, {:store, report})

      _ ->
        :ok
    end
  end

  @doc "Return all reports, newest first."
  @spec list() :: [map()]
  def list do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :list)

      _ ->
        []
    end
  end

  @doc "Return the most recent report for a given issue_identifier, or nil."
  @spec get(String.t()) :: map() | nil
  def get(issue_identifier) when is_binary(issue_identifier) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, {:get, issue_identifier})

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, :queue.new()}
  end

  @impl true
  def handle_cast({:store, report}, queue) do
    queue = enqueue(queue, report)
    persist(report)
    {:noreply, queue}
  end

  @impl true
  def handle_call(:list, _from, queue) do
    reports = queue |> :queue.to_list() |> Enum.reverse()
    {:reply, reports, queue}
  end

  def handle_call({:get, issue_identifier}, _from, queue) do
    result =
      queue
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.find(fn report ->
        Map.get(report, :issue_identifier) == issue_identifier
      end)

    {:reply, result, queue}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp enqueue(queue, report) do
    queue = :queue.in(report, queue)

    if :queue.len(queue) > @max_reports do
      {_, queue} = :queue.out(queue)
      queue
    else
      queue
    end
  end

  defp persist(report) do
    case log_file_path() do
      {:ok, path} ->
        dir = Path.dirname(path)

        with :ok <- File.mkdir_p(dir),
             {:ok, line} <- encode_report(report),
             :ok <- File.write(path, line <> "\n", [:append]) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("CompletionReportStore: failed to persist report reason=#{inspect(reason)}")
            :ok
        end

      :error ->
        :ok
    end
  end

  defp log_file_path do
    try do
      root = SymphonyElixir.Config.settings!().workspace.root

      if is_binary(root) and root != "" do
        {:ok, Path.join([root, @log_dir, @log_file])}
      else
        :error
      end
    rescue
      _ -> :error
    end
  end

  defp encode_report(report) do
    serializable =
      report
      |> Map.new(fn {k, v} -> {to_string(k), serialize_value(v)} end)

    case Jason.encode(serializable) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_value(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  defp serialize_value(v), do: v
end
