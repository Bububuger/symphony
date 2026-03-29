defmodule SymphonyElixir.ActivityLog do
  @moduledoc """
  Per-issue activity log backed by ETS.

  Two ETS tables are maintained:

  * `:activity_log_running`   — events for in-progress issues.  Each issue
    keeps at most 500 events; older entries are evicted when the cap is
    exceeded (ring buffer).

  * `:activity_log_completed` — events for finished issues.  At most 20 issues
    are retained; the oldest issue is purged (FIFO) when a new completed issue
    would exceed the cap.

  All public functions are synchronous `GenServer.call/cast` wrappers so that
  ETS writes are serialised through a single owner process.
  """

  use GenServer

  require Logger

  @ring_limit 500
  @completed_issue_limit 20
  @detail_max_bytes 2_048

  # ── public API ────────────────────────────────────────────────────────────────

  @doc "Append an event map to the log for *issue_id*."
  @spec append(String.t(), map()) :: :ok
  def append(issue_id, event_map) when is_binary(issue_id) and is_map(event_map) do
    GenServer.cast(__MODULE__, {:append, issue_id, event_map})
  end

  @doc "Return all logged events for *issue_id*, newest first."
  @spec get(String.t()) :: [map()]
  def get(issue_id) when is_binary(issue_id) do
    GenServer.call(__MODULE__, {:get, issue_id})
  end

  @doc """
  Return events for *issue_id* with a timestamp strictly after *since_iso8601*.
  Returns an empty list when *since_iso8601* is `nil` or unparseable.
  """
  @spec get_since(String.t(), String.t() | nil) :: [map()]
  def get_since(issue_id, since_iso8601) when is_binary(issue_id) do
    GenServer.call(__MODULE__, {:get_since, issue_id, since_iso8601})
  end

  @doc """
  Append a final event for *issue_id* and move its log to the completed table.
  *final_event_map* should already have the `event` key set to
  `"issue_completed"` or `"issue_failed"`.
  """
  @spec complete(String.t(), map()) :: :ok
  def complete(issue_id, final_event_map)
      when is_binary(issue_id) and is_map(final_event_map) do
    GenServer.cast(__MODULE__, {:complete, issue_id, final_event_map})
  end

  # ── GenServer lifecycle ───────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  defmodule State do
    @moduledoc false
    # completed_order: list of issue_ids in insertion order (oldest first)
    defstruct [:running_table, :completed_table, completed_order: []]
  end

  @impl true
  def init(_opts) do
    running_table = :ets.new(:activity_log_running, [:set, :protected])
    completed_table = :ets.new(:activity_log_completed, [:set, :protected])
    {:ok, %State{running_table: running_table, completed_table: completed_table}}
  end

  # ── handle_cast ───────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:append, issue_id, event_map}, state) do
    event = normalize_event(event_map)
    do_append(state.running_table, issue_id, event)
    {:noreply, state}
  end

  def handle_cast({:complete, issue_id, final_event_map}, state) do
    final_event = normalize_event(final_event_map)
    do_append(state.running_table, issue_id, final_event)

    events = fetch_events_from(state.running_table, issue_id)
    delete_issue_from(state.running_table, issue_id)

    :ets.insert(state.completed_table, {issue_id, events})

    new_order = state.completed_order ++ [issue_id]

    new_state =
      if length(new_order) > @completed_issue_limit do
        [evict_id | rest] = new_order
        :ets.delete(state.completed_table, evict_id)
        %{state | completed_order: rest}
      else
        %{state | completed_order: new_order}
      end

    {:noreply, new_state}
  end

  # ── handle_call ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:get, issue_id}, _from, state) do
    events = lookup_events(state, issue_id)
    result = events |> Enum.sort_by(& &1.seq, :desc) |> Enum.map(&to_public_map/1)
    {:reply, result, state}
  end

  def handle_call({:get_since, issue_id, since_iso8601}, _from, state) do
    result =
      with true <- is_binary(since_iso8601),
           {:ok, since_dt, _} <- DateTime.from_iso8601(since_iso8601) do
        lookup_events(state, issue_id)
        |> Enum.filter(fn event ->
          case DateTime.from_iso8601(event.timestamp) do
            {:ok, dt, _} -> DateTime.compare(dt, since_dt) == :gt
            _ -> false
          end
        end)
        |> Enum.sort_by(& &1.seq, :desc)
        |> Enum.map(&to_public_map/1)
      else
        _ -> []
      end

    {:reply, result, state}
  end

  # ── private helpers ───────────────────────────────────────────────────────────

  defp lookup_events(state, issue_id) do
    case fetch_events_from(state.running_table, issue_id) do
      [] ->
        case :ets.lookup(state.completed_table, issue_id) do
          [{^issue_id, events}] when is_list(events) -> events
          _ -> []
        end

      events ->
        events
    end
  end

  defp normalize_event(event_map) do
    raw_detail = Map.get(event_map, :detail) || Map.get(event_map, "detail")

    detail =
      if is_binary(raw_detail),
        do: String.slice(raw_detail, 0, @detail_max_bytes),
        else: nil

    tokens =
      Map.get(event_map, :tokens) ||
        Map.get(event_map, "tokens") ||
        %{input: 0, output: 0}

    %{
      seq: System.unique_integer([:monotonic, :positive]),
      timestamp:
        Map.get(event_map, :timestamp) ||
          Map.get(event_map, "timestamp") ||
          utc_now_iso8601(),
      event:
        event_map
        |> (fn m -> Map.get(m, :event) || Map.get(m, "event") end).()
        |> normalize_event_name(),
      turn: Map.get(event_map, :turn) || Map.get(event_map, "turn") || 0,
      detail: detail,
      tokens: tokens
    }
  end

  defp normalize_event_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_event_name(str) when is_binary(str), do: str
  defp normalize_event_name(_), do: "unknown"

  defp utc_now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp fetch_events_from(table, issue_id) do
    case :ets.lookup(table, issue_id) do
      [{^issue_id, events}] when is_list(events) -> events
      _ -> []
    end
  end

  defp delete_issue_from(table, issue_id) do
    :ets.delete(table, issue_id)
  end

  defp do_append(table, issue_id, event) do
    existing = fetch_events_from(table, issue_id)
    updated = existing ++ [event]

    trimmed =
      if length(updated) > @ring_limit do
        Enum.drop(updated, length(updated) - @ring_limit)
      else
        updated
      end

    :ets.insert(table, {issue_id, trimmed})
  end

  defp to_public_map(event) do
    %{
      timestamp: event.timestamp,
      event: event.event,
      turn: event.turn,
      detail: event.detail,
      tokens: event.tokens
    }
  end
end
