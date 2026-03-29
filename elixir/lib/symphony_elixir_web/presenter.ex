defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{CompletionReportStore, Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        checkpoint_waiting = checkpoint_waiting_counts(snapshot)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            checkpoint_human_verify: checkpoint_waiting.human_verify,
            checkpoint_decision: checkpoint_waiting.decision,
            checkpoint_human_action: checkpoint_waiting.human_action
          },
          checkpoint_waiting: checkpoint_waiting,
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          completed: completed_entries_payload(),
          codex_totals: snapshot.codex_totals,
          stats: stats_payload_from_snapshot(snapshot),
          rate_limits: snapshot.rate_limits,
          workspace: workspace_payload(Map.get(snapshot, :workspace))
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec stats_payload(GenServer.name(), timeout()) :: map()
  def stats_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        stats_payload_from_snapshot(snapshot)
        |> Map.put(:generated_at, generated_at)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp checkpoint_waiting_counts(snapshot) when is_map(snapshot) do
    source = Map.get(snapshot, :checkpoint_waiting, %{})

    %{
      human_verify: count_value(source, :human_verify),
      decision: count_value(source, :decision),
      human_action: count_value(source, :human_action)
    }
  end

  defp count_value(map, key) when is_map(map) and is_atom(key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key)) || 0

    if is_integer(value) and value >= 0 do
      value
    else
      0
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec issue_tokens_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_tokens_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))

        if running do
          stats = Map.get(snapshot, :stats) || %{}
          all_turns = Map.get(stats, :per_turn_tokens, [])

          current_session_id = running.session_id

          issue_turns =
            Enum.filter(all_turns, fn turn ->
              (Map.get(turn, :issue_identifier) == issue_identifier or
                 Map.get(turn, "issue_identifier") == issue_identifier) and
                (Map.get(turn, :session_id) == current_session_id or
                   Map.get(turn, "session_id") == current_session_id)
            end)

          payload = %{
            issue_identifier: issue_identifier,
            issue_id: running.issue_id,
            generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            session_id: running.session_id,
            turn_count: Map.get(running, :turn_count, 0),
            total: %{
              input_tokens: running.codex_input_tokens,
              output_tokens: running.codex_output_tokens,
              total_tokens: running.codex_total_tokens
            },
            turns: Enum.map(issue_turns, &turn_payload/1)
          }

          {:ok, payload}
        else
          {:error, :issue_not_found}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.settings!().workspace.root, issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      workflow: workflow_payload((running && running.state) || (retry && "Retrying")),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp turn_payload(turn) do
    %{
      session_id: Map.get(turn, :session_id) || Map.get(turn, "session_id"),
      turn_count: Map.get(turn, :turn_count) || Map.get(turn, "turn_count"),
      input_tokens: Map.get(turn, :input_tokens) || Map.get(turn, "input_tokens"),
      output_tokens: Map.get(turn, :output_tokens) || Map.get(turn, "output_tokens"),
      total_tokens: Map.get(turn, :total_tokens) || Map.get(turn, "total_tokens"),
      recorded_at: iso8601(Map.get(turn, :recorded_at) || Map.get(turn, "recorded_at"))
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      trace_id: Map.get(entry, :trace_id),
      state: entry.state,
      session_id: entry.session_id,
      runtime_name: Map.get(entry, :runtime_name),
      turn_count: Map.get(entry, :turn_count, 0),
      workflow: workflow_payload(Map.get(entry, :state)),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      error_class: entry.error_class
    }
  end

  defp running_issue_payload(running) do
    %{
      trace_id: Map.get(running, :trace_id),
      session_id: running.session_id,
      runtime_name: Map.get(running, :runtime_name),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      workflow: workflow_payload(Map.get(running, :state)),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      error_class: retry.error_class
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp stats_payload_from_snapshot(snapshot) when is_map(snapshot) do
    default = %{
      completed_count: 0,
      failed_count: 0,
      success_rate: nil,
      duration_ms: %{sample_count: 0, p50: nil, p95: nil, p99: nil},
      per_turn_tokens: [],
      linear_api_response_time_ms: %{sample_count: 0, p50: nil, p95: nil}
    }

    stats = Map.get(snapshot, :stats) || Map.get(snapshot, "stats") || %{}
    Map.merge(default, stats)
  end

  defp workspace_payload(%{} = workspace) do
    keep_recent = Map.get(workspace, :done_closed_keep_count) || Map.get(workspace, :cleanup_keep_recent)

    %{
      usage_bytes: non_negative_integer(Map.get(workspace, :usage_bytes), 0),
      warning_threshold_bytes:
        positive_integer(
          Map.get(workspace, :warning_threshold_bytes),
          10 * 1024 * 1024 * 1024
        ),
      done_closed_keep_count: non_negative_integer(keep_recent, 5)
    }
  end

  defp workspace_payload(_workspace) do
    %{
      usage_bytes: 0,
      warning_threshold_bytes: 10 * 1024 * 1024 * 1024,
      done_closed_keep_count: 5
    }
  end

  defp completed_entries_payload do
    CompletionReportStore.list()
    |> Enum.map(&completed_entry_payload/1)
  end

  defp completed_entry_payload(report) do
    tokens = Map.get(report, :tokens) || %{}
    result = normalize_result(Map.get(report, :result))

    %{
      issue_id: Map.get(report, :issue_id),
      issue_identifier: Map.get(report, :issue_identifier),
      runtime_name: Map.get(report, :runtime_name),
      result: result,
      started_at: iso8601(Map.get(report, :started_at)),
      finished_at: iso8601(Map.get(report, :finished_at)),
      duration_ms: Map.get(report, :duration_ms) || 0,
      turns: Map.get(report, :turns) || 0,
      tokens: %{
        input_tokens: Map.get(tokens, :input) || 0,
        output_tokens: Map.get(tokens, :output) || 0,
        total_tokens: Map.get(tokens, :total) || 0
      },
      workflow: workflow_payload(nil, result: result)
    }
  end

  defp workflow_payload(current_state, opts \\ []) do
    result = Keyword.get(opts, :result)
    stages = workflow_stages()
    effective_current = normalize_state_name(current_state)
    stage_names = ensure_stage_presence(stages, effective_current, result)

    items =
      cond do
        result in ["done", "success"] ->
          Enum.map(stage_names, &stage_item(&1, "complete"))

        result in ["failed", "failure"] ->
          failure_stage_items(stage_names, effective_current)

        true ->
          running_stage_items(stage_names, effective_current)
      end

    %{
      current_state: effective_current,
      stages: items,
      summary: Enum.map_join(items, " -> ", &stage_summary_label/1)
    }
  end

  defp workflow_stages do
    tracker = Config.settings!().tracker
    configured = Map.get(tracker, :workflow_stages) || []

    source =
      if configured == [] do
        (Map.get(tracker, :active_states) || []) ++ (Map.get(tracker, :terminal_states) || [])
      else
        configured
      end

    source
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&String.downcase/1)
  rescue
    _ -> []
  end

  defp ensure_stage_presence(stages, nil, result) when result in ["done", "success"] do
    if stages == [], do: ["Done"], else: stages
  end

  defp ensure_stage_presence(stages, nil, result) when result in ["failed", "failure"] do
    if stages == [], do: ["Failed"], else: stages
  end

  defp ensure_stage_presence(stages, nil, _result), do: stages

  defp ensure_stage_presence(stages, current_state, _result) do
    if Enum.any?(stages, &(String.downcase(&1) == String.downcase(current_state))) do
      stages
    else
      stages ++ [current_state]
    end
  end

  defp running_stage_items([], nil), do: []
  defp running_stage_items([], current_state), do: [stage_item(current_state, "current")]

  defp running_stage_items(stages, current_state) do
    current_index =
      Enum.find_index(stages, fn stage ->
        not is_nil(current_state) and String.downcase(stage) == String.downcase(current_state)
      end)

    Enum.with_index(stages)
    |> Enum.map(fn {stage, index} ->
      status =
        cond do
          is_nil(current_index) -> "upcoming"
          index < current_index -> "complete"
          index == current_index -> "current"
          true -> "upcoming"
        end

      stage_item(stage, status)
    end)
  end

  defp failure_stage_items(stages, current_state) do
    base =
      running_stage_items(stages, current_state)
      |> Enum.map(fn item ->
        if item.status == "current", do: %{item | status: "complete"}, else: item
      end)

    base ++ [stage_item("Failed", "failed")]
  end

  defp stage_item(name, status), do: %{name: name, status: status}

  defp stage_summary_label(%{name: name, status: status}) do
    glyph =
      case status do
        "complete" -> "●"
        "current" -> "●"
        "failed" -> "✗"
        _ -> "○"
      end

    glyph <> name
  end

  defp normalize_result(value) when value in [:done, :success], do: "done"
  defp normalize_result(value) when value in [:failed, :failure], do: "failed"
  defp normalize_result(value) when is_binary(value), do: String.downcase(value)
  defp normalize_result(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  defp normalize_result(_value), do: "unknown"

  defp normalize_state_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_state_name(_value), do: nil

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
