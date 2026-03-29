defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{ActivityLog, Intervention, Orchestrator}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec stats(Conn.t(), map()) :: Conn.t()
  def stats(conn, _params) do
    json(conn, Presenter.stats_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec completion_reports(Conn.t(), map()) :: Conn.t()
  def completion_reports(conn, _params) do
    reports = SymphonyElixir.CompletionReportStore.list()
    json(conn, %{reports: reports})
  end

  @spec completed_issues(Conn.t(), map()) :: Conn.t()
  def completed_issues(conn, _params) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    items =
      SymphonyElixir.CompletionReportStore.list()
      |> Enum.map(&completed_issue_item/1)

    json(conn, %{items: items, generated_at: generated_at})
  end

  @spec issue_activity(Conn.t(), map()) :: Conn.t()
  def issue_activity(conn, %{"id" => id} = params) do
    since = Map.get(params, "since")
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    items =
      if is_binary(since) and since != "" do
        ActivityLog.get_since(id, since)
      else
        ActivityLog.get(id)
      end

    json(conn, %{
      issue_identifier: id,
      items: items,
      has_more: false,
      since: since,
      generated_at: generated_at
    })
  end

  @spec issue_tokens(Conn.t(), map()) :: Conn.t()
  def issue_tokens(conn, %{"id" => id}) do
    case Presenter.issue_tokens_payload(id, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> json(conn, payload)
      {:error, :issue_not_found} -> error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec issue_intervene(Conn.t(), map()) :: Conn.t()
  def issue_intervene(conn, %{"id" => id} = params) do
    raw = Map.get(params, "directive")

    cond do
      not is_binary(raw) ->
        error_response(conn, 422, "directive_required", "directive must be a non-empty string")

      String.trim(raw) == "" ->
        error_response(conn, 422, "directive_required", "directive must be a non-empty string")

      true ->
        directive = String.trim(raw)
        do_issue_intervene(conn, id, directive)
    end
  end

  defp do_issue_intervene(conn, issue_identifier, directive) do
    snapshot = Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms())

    running_entry =
      case snapshot do
        %{running: running} -> Enum.find(running, &(&1.identifier == issue_identifier))
        _ -> nil
      end

    case running_entry do
      nil ->
        error_response(conn, 404, "issue_not_running", "Issue not running")

      %{issue_id: issue_id} ->
        queued_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        case Intervention.enqueue(issue_id, directive) do
          :ok ->
            conn
            |> put_status(202)
            |> json(%{issue_identifier: issue_identifier, directive: directive, queued_at: queued_at, status: "queued"})

          {:error, :queue_full} ->
            error_response(conn, 429, "queue_full", "Intervention queue full")
        end
    end
  end

  @spec webhook_linear(Conn.t(), map()) :: Conn.t()
  def webhook_linear(conn, params) do
    with :ok <- verify_webhook_secret(conn) do
      action = Map.get(params, "action")
      type = Map.get(params, "type")

      if type == "Issue" and action in ["create", "update"] do
        issue_data = Map.get(params, "data", %{})
        target = resolve_orchestrator_pid()
        if is_pid(target), do: send(target, {:webhook_issue_event, issue_data})
      end

      json(conn, %{ok: true})
    else
      {:error, :unauthorized} ->
        error_response(conn, 401, "unauthorized", "Invalid webhook secret")
    end
  end

  # If SYMPHONY_WEBHOOK_SECRET is set, require matching X-Symphony-Secret header.
  # When unset, the endpoint is open (suitable for internal/firewalled deployments).
  defp verify_webhook_secret(conn) do
    case System.get_env("SYMPHONY_WEBHOOK_SECRET") do
      nil -> :ok
      "" -> :ok
      secret ->
        header = get_req_header(conn, "x-symphony-secret") |> List.first()
        if header == secret, do: :ok, else: {:error, :unauthorized}
    end
  end

  defp resolve_orchestrator_pid, do: orchestrator()

  @spec shutdown(Conn.t(), map()) :: Conn.t()
  def shutdown(conn, params) do
    timeout_ms = case Map.get(params, "timeout_ms") do
      v when is_integer(v) and v > 0 -> v
      _ -> 30_000
    end

    spawn(fn ->
      SymphonyElixir.Orchestrator.initiate_shutdown(orchestrator(), timeout_ms)
      :init.stop()
    end)

    conn
    |> put_status(202)
    |> json(%{status: "shutting_down", message: "Graceful shutdown initiated"})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp completed_issue_item(report) when is_map(report) do
    tokens = Map.get(report, :tokens) || Map.get(report, "tokens") || %{}

    %{
      issue_id: Map.get(report, :issue_id) || Map.get(report, "issue_id"),
      issue_identifier: Map.get(report, :issue_identifier) || Map.get(report, "issue_identifier"),
      runtime_name: Map.get(report, :runtime_name) || Map.get(report, "runtime_name"),
      result: normalize_report_value(Map.get(report, :result) || Map.get(report, "result")),
      started_at: iso8601_or_nil(Map.get(report, :started_at) || Map.get(report, "started_at")),
      finished_at: iso8601_or_nil(Map.get(report, :finished_at) || Map.get(report, "finished_at")),
      duration_ms: Map.get(report, :duration_ms) || Map.get(report, "duration_ms") || 0,
      turns: Map.get(report, :turns) || Map.get(report, "turns") || 0,
      tokens: %{
        input: Map.get(tokens, :input) || Map.get(tokens, "input") || 0,
        output: Map.get(tokens, :output) || Map.get(tokens, "output") || 0,
        total: Map.get(tokens, :total) || Map.get(tokens, "total") || 0
      },
      tokens_per_turn:
        Map.get(report, :tokens_per_turn) || Map.get(report, "tokens_per_turn") || 0,
      error: Map.get(report, :error) || Map.get(report, "error")
    }
  end

  defp normalize_report_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_report_value(value), do: value

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(value) when is_binary(value), do: value
  defp iso8601_or_nil(_value), do: nil

  # Returns the target for all orchestrator calls.
  # - Endpoint config override (non-default): used in tests to inject doubles.
  # - Default: resolve global coordinator name for multi-node support.
  defp orchestrator do
    case Endpoint.config(:orchestrator) do
      nil ->
        do_global_orchestrator()

      SymphonyElixir.Orchestrator ->
        do_global_orchestrator()

      name when is_atom(name) ->
        Process.whereis(name)

      other ->
        other
    end
  end

  defp do_global_orchestrator do
    case :global.whereis_name(:symphony_coordinator) do
      :undefined -> SymphonyElixir.Orchestrator
      pid -> pid
    end
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
