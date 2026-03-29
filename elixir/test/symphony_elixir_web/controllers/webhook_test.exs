defmodule SymphonyElixirWeb.WebhookTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  # Minimal fake orchestrator that records received messages
  defmodule RecordingOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{owner: nil, messages: []}, name: name)
    end

    def set_owner(server, pid), do: GenServer.cast(server, {:set_owner, pid})
    def received_messages(server), do: GenServer.call(server, :received_messages)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:set_owner, pid}, state), do: {:noreply, %{state | owner: pid}}

    @impl true
    def handle_call(:received_messages, _from, state), do: {:reply, state.messages, state}
    def handle_call(:snapshot, _from, state), do: {:reply, :timeout, state}

    @impl true
    def handle_info({:webhook_issue_event, _data} = msg, state) do
      if state.owner, do: send(state.owner, msg)
      {:noreply, %{state | messages: [msg | state.messages]}}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  test "POST /api/v1/webhook/linear with valid Issue create event returns 200 {ok: true}" do
    orchestrator_name = Module.concat(__MODULE__, :OrchestratorCreate)
    {:ok, orch_pid} = start_supervised({RecordingOrchestrator, name: orchestrator_name})
    RecordingOrchestrator.set_owner(orchestrator_name, self())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = %{
      "action" => "create",
      "type" => "Issue",
      "data" => %{"id" => "abc-123", "identifier" => "BUB-1", "title" => "Test issue"}
    }

    conn = post(build_conn(), "/api/v1/webhook/linear", payload)
    assert json_response(conn, 200) == %{"ok" => true}

    assert_receive {:webhook_issue_event, %{"id" => "abc-123"}}, 500

    stop_supervised(orch_pid)
  end

  test "POST /api/v1/webhook/linear with valid Issue update event returns 200 {ok: true}" do
    orchestrator_name = Module.concat(__MODULE__, :OrchestratorUpdate)
    {:ok, orch_pid} = start_supervised({RecordingOrchestrator, name: orchestrator_name})
    RecordingOrchestrator.set_owner(orchestrator_name, self())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = %{
      "action" => "update",
      "type" => "Issue",
      "data" => %{"id" => "def-456", "identifier" => "BUB-2", "title" => "Updated issue"}
    }

    conn = post(build_conn(), "/api/v1/webhook/linear", payload)
    assert json_response(conn, 200) == %{"ok" => true}

    assert_receive {:webhook_issue_event, %{"id" => "def-456"}}, 500

    stop_supervised(orch_pid)
  end

  test "POST /api/v1/webhook/linear with non-Issue type returns 200 and does not notify orchestrator" do
    orchestrator_name = Module.concat(__MODULE__, :OrchestratorNonIssue)
    {:ok, orch_pid} = start_supervised({RecordingOrchestrator, name: orchestrator_name})
    RecordingOrchestrator.set_owner(orchestrator_name, self())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = %{
      "action" => "create",
      "type" => "Comment",
      "data" => %{"id" => "ghi-789"}
    }

    conn = post(build_conn(), "/api/v1/webhook/linear", payload)
    assert json_response(conn, 200) == %{"ok" => true}

    refute_receive {:webhook_issue_event, _}, 100

    stop_supervised(orch_pid)
  end

  test "POST /api/v1/webhook/linear with missing fields returns 200 gracefully" do
    orchestrator_name = Module.concat(__MODULE__, :OrchestratorMissing)
    {:ok, orch_pid} = start_supervised({RecordingOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = post(build_conn(), "/api/v1/webhook/linear", %{})
    assert json_response(conn, 200) == %{"ok" => true}

    stop_supervised(orch_pid)
  end

  test "non-POST methods to /api/v1/webhook/linear return 405" do
    orchestrator_name = Module.concat(__MODULE__, :OrchestratorMethod)
    {:ok, orch_pid} = start_supervised({RecordingOrchestrator, name: orchestrator_name})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/webhook/linear"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    stop_supervised(orch_pid)
  end
end
