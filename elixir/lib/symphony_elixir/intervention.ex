defmodule SymphonyElixir.Intervention do
  @moduledoc """
  Per-issue FIFO queue for operator directives injected between agent turns.

  Directives are enqueued via the API and consumed by AgentRunner before each
  subsequent turn, prepended as `[Operator Directive]: <text>` to the prompt.
  """

  use GenServer

  @queue_limit 10

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Enqueue a directive for the given issue.

  Returns `:ok` on success or `{:error, :queue_full}` when the per-issue limit
  of #{@queue_limit} is reached.
  """
  @spec enqueue(binary(), binary()) :: :ok | {:error, :queue_full}
  def enqueue(issue_id, directive) when is_binary(issue_id) and is_binary(directive) do
    GenServer.call(__MODULE__, {:enqueue, issue_id, directive})
  end

  @doc """
  Dequeue and return the oldest directive for the given issue, or `nil` if
  the queue is empty.
  """
  @spec dequeue(binary()) :: binary() | nil
  def dequeue(issue_id) when is_binary(issue_id) do
    GenServer.call(__MODULE__, {:dequeue, issue_id})
  end

  @doc """
  List all pending directives for the given issue without removing them.
  """
  @spec list(binary()) :: [binary()]
  def list(issue_id) when is_binary(issue_id) do
    GenServer.call(__MODULE__, {:list, issue_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, issue_id, directive}, _from, queues) do
    queue = Map.get(queues, issue_id, :queue.new())

    if :queue.len(queue) >= @queue_limit do
      {:reply, {:error, :queue_full}, queues}
    else
      new_queue = :queue.in(directive, queue)
      {:reply, :ok, Map.put(queues, issue_id, new_queue)}
    end
  end

  def handle_call({:dequeue, issue_id}, _from, queues) do
    queue = Map.get(queues, issue_id, :queue.new())

    case :queue.out(queue) do
      {{:value, directive}, rest_queue} ->
        new_queues =
          if :queue.is_empty(rest_queue) do
            Map.delete(queues, issue_id)
          else
            Map.put(queues, issue_id, rest_queue)
          end

        {:reply, directive, new_queues}

      {:empty, _} ->
        {:reply, nil, queues}
    end
  end

  def handle_call({:list, issue_id}, _from, queues) do
    queue = Map.get(queues, issue_id, :queue.new())
    {:reply, :queue.to_list(queue), queues}
  end
end
