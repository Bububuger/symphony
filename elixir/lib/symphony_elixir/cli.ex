defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.DynamicTools.MCPServer
  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @logs_switches [issue: :string, full: :boolean, port: :integer]
  @port_switches [port: :integer]
  @request_timeout_ms 5_000
  @default_consent_file "~/.config/symphony/.consented"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          run_dynamic_tools_mcp: ([String.t()] -> :ok | {:error, String.t()}),
          ensure_all_started: (-> ensure_started_result()),
          consent_file_path: String.t(),
          write_consent: (String.t() -> :ok),
          ask_for_consent: (-> boolean())
        }

  @spec main([String.t()]) :: no_return()
  def main(["dynamic-tools-mcp" | rest]) do
    MCPServer.main(rest)
  end

  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, :no_wait} ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, :no_wait} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps())

  def evaluate(["dynamic-tools-mcp" | rest], deps) do
    deps.run_dynamic_tools_mcp.(rest)
  end

  def evaluate(["on" | rest], deps) do
    case OptionParser.parse(rest, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_consent(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_consent(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(["off" | rest], deps) do
    case OptionParser.parse(rest, strict: @port_switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_server_port_runtime(opts, deps),
             {:ok, payload} <- api_request(:post, "/api/v1/shutdown", %{}),
             :ok <- print_shutdown(payload) do
          {:ok, :no_wait}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(["status" | rest], deps) do
    case OptionParser.parse(rest, strict: @port_switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_server_port_runtime(opts, deps),
             {:ok, payload} <- api_request(:get, "/api/v1/state"),
             :ok <- print_status(payload) do
          {:ok, :no_wait}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(["init" | rest], _deps) do
    case SymphonyElixir.Init.run(rest) do
      :ok -> {:ok, :no_wait}
      {:error, msg} -> {:error, msg}
    end
  end

  def evaluate(["doctor" | _rest], _deps) do
    case SymphonyElixir.Doctor.run() do
      :ok -> {:ok, :no_wait}
      {:error, msg} -> {:error, msg}
    end
  end
  def evaluate(["logs" | rest], deps) do
    case OptionParser.parse(rest, strict: @logs_switches) do
      {opts, [], []} ->
        with issue when is_binary(issue) <- normalize_issue_identifier(opts[:issue]),
             :ok <- maybe_set_server_port_runtime(opts, deps),
             {:ok, payload} <- api_request(:get, "/api/v1/issues/#{URI.encode(issue)}/activity"),
             :ok <- print_issue_activity(issue, payload, Keyword.get(opts, :full, false)) do
          {:ok, :no_wait}
        else
          nil -> {:error, usage_message()}
          error -> error
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(["intervene" | rest], deps) do
    case OptionParser.parse(rest, strict: @port_switches) do
      {opts, [issue_identifier, directive], []} ->
        trimmed_issue = normalize_issue_identifier(issue_identifier)
        trimmed_directive = directive |> to_string() |> String.trim()

        cond do
          is_nil(trimmed_issue) ->
            {:error, usage_message()}

          trimmed_directive == "" ->
            {:error, usage_message()}

          true ->
            with :ok <- maybe_set_server_port_runtime(opts, deps),
                 {:ok, payload} <-
                   api_request(
                     :post,
                     "/api/v1/issues/#{URI.encode(trimmed_issue)}/intervene",
                     %{"directive" => trimmed_directive}
                   ) do
              IO.puts(
                "Directive queued for #{payload["issue_identifier"]} at #{payload["queued_at"]}"
              )

              {:ok, :no_wait}
            end
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(_args, deps) do
    _ = deps
    {:error, usage_message()}
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony on [path-to-WORKFLOW.md] [--logs-root <path>] [--port <port>]
      symphony off
      symphony status
      symphony init
      symphony doctor
      symphony logs [--issue <identifier>] [--full] [--port <port>]
      symphony intervene <issue-identifier> <directive> [--port <port>]
      symphony dynamic-tools-mcp [--linear-api-key <token>] [--linear-endpoint <url>]
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      run_dynamic_tools_mcp: &MCPServer.run_cli/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      consent_file_path: Path.expand(@default_consent_file),
      write_consent: &write_consent/1,
      ask_for_consent: &ask_for_consent/0
    }
  end

  defp require_consent(opts, deps) do
    cond do
      Keyword.get(opts, @acknowledgement_switch, false) ->
        :ok

      deps.file_regular?.(deps.consent_file_path) ->
        :ok

      deps.ask_for_consent.() ->
        deps.write_consent.(deps.consent_file_path)

      true ->
        {:error, acknowledgement_banner()}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_set_server_port_runtime(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        cond do
          not (is_integer(port) and port >= 0) ->
            {:error, usage_message()}

          is_map(deps) and is_function(Map.get(deps, :set_server_port_override), 1) ->
            :ok = deps.set_server_port_override.(port)

          true ->
            :ok = set_server_port_override(port)
        end
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp api_request(method, path, body \\ nil) do
    with {:ok, base_url} <- api_base_url() do
      request =
        [
          headers: [{"accept", "application/json"}],
          connect_options: [timeout: @request_timeout_ms],
          receive_timeout: @request_timeout_ms
        ]

      response =
        case method do
          :get ->
            Req.get(base_url <> path, request)

          :post ->
            Req.post(base_url <> path, Keyword.put(request, :json, body || %{}))
        end

      case response do
        {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %Req.Response{body: response_body}} ->
          {:error, api_error_message(response_body)}

        {:error, reason} ->
          {:error, "Failed to contact Symphony HTTP server: #{inspect(reason)}"}
      end
    end
  end

  defp api_base_url do
    with {:ok, port} <- resolve_server_port() do
      {:ok, "http://#{resolve_server_host()}:#{port}"}
    end
  end

  defp resolve_server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        {:ok, port}

      _ ->
        try do
          case Config.server_port() do
            port when is_integer(port) and port >= 0 ->
              {:ok, port}

            _ ->
              {:error, "No server port configured. Use --port <port> or set server.port in WORKFLOW.md"}
          end
        rescue
          _ ->
            {:error, "No server port configured. Use --port <port> or set server.port in WORKFLOW.md"}
        end
    end
  end

  defp resolve_server_host do
    try do
      case Config.settings!().server.host do
        host when host in [nil, "", "0.0.0.0", "::"] -> "127.0.0.1"
        host when is_binary(host) -> host
        _ -> "127.0.0.1"
      end
    rescue
      _ -> "127.0.0.1"
    end
  end

  defp print_status(%{"counts" => counts, "generated_at" => generated_at}) do
    IO.puts("""
    Symphony status
    running: #{counts["running"] || 0}
    retrying: #{counts["retrying"] || 0}
    generated_at: #{generated_at}
    """)

    :ok
  end

  defp print_status(payload), do: {:error, api_error_message(payload)}

  defp print_issue_activity(issue_identifier, payload, full?) do
    items = Map.get(payload, "items", [])
    visible_items = if full?, do: items, else: Enum.take(items, 20)
    report = matching_completion_report(issue_identifier)

    IO.puts("Issue activity: #{issue_identifier}")

    if visible_items == [] do
      IO.puts("(no activity)")
    else
      Enum.each(visible_items, &IO.puts(format_activity_item(&1)))
    end

    if report do
      IO.puts("")
      IO.puts(format_completion_report(report))
    end

    :ok
  end

  defp print_shutdown(%{"status" => status, "message" => message}) do
    IO.puts("#{status}: #{message}")
    :ok
  end

  defp print_shutdown(payload), do: {:error, api_error_message(payload)}

  defp matching_completion_report(issue_identifier) do
    case api_request(:get, "/api/v1/issues/completed") do
      {:ok, %{"items" => items}} when is_list(items) ->
        Enum.find(items, fn item -> item["issue_identifier"] == issue_identifier end)

      _ ->
        nil
    end
  end

  defp format_activity_item(item) do
    timestamp = item["timestamp"] || "n/a"
    event = item["event"] || "unknown"
    turn = item["turn"] || 0
    detail = item["detail"] || ""

    [timestamp, event, "turn=#{turn}", detail]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp format_completion_report(report) do
    tokens = Map.get(report, "tokens") || %{}

    [
      "Completion report:",
      "result=#{Map.get(report, "result") || "unknown"}",
      "duration_ms=#{Map.get(report, "duration_ms") || 0}",
      "turns=#{Map.get(report, "turns") || 0}",
      "tokens=#{Map.get(tokens, "total") || 0}"
    ]
    |> Enum.join(" ")
  end

  defp api_error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp api_error_message(%{"message" => message}) when is_binary(message), do: message
  defp api_error_message(other), do: "Unexpected response: #{inspect(other)}"

  defp normalize_issue_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_issue_identifier(_value), do: nil

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp write_consent(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "")
    :ok
  end

  defp ask_for_consent do
    IO.puts(acknowledgement_banner())
    IO.write("\nType YES to proceed: ")

    case IO.gets("") do
      line when is_binary(line) -> String.trim(line) == "YES"
      _ -> false
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
