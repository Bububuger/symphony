defmodule SymphonyElixirWeb.AgentChannelTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ChannelTest

  alias SymphonyElixirWeb.{AgentChannel, UserSocket}

  @endpoint SymphonyElixirWeb.Endpoint
  @pubsub SymphonyElixir.PubSub

  setup do
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  describe "join/3" do
    test "successfully joins agent topic" do
      {:ok, _reply, socket} =
        socket(UserSocket, "user:1", %{})
        |> subscribe_and_join(AgentChannel, "agent:BUB-123")

      assert socket.topic == "agent:BUB-123"
    end
  end

  describe "handle_info/2" do
    test "pushes agent_event to client when PubSub broadcast received" do
      {:ok, _reply, _socket} =
        socket(UserSocket, "user:2", %{})
        |> subscribe_and_join(AgentChannel, "agent:BUB-456")

      payload = %{
        event: "tool_called",
        turn: 3,
        detail: "Bash tool invoked",
        tokens: %{input: 100, output: 50},
        timestamp: "2026-01-01T00:00:00Z"
      }

      Phoenix.PubSub.broadcast(@pubsub, "agent:BUB-456", {:agent_event, payload})

      assert_push "agent_event", received_payload
      assert received_payload == payload
    end

    test "does not receive events for different issue" do
      {:ok, _reply, _socket} =
        socket(UserSocket, "user:3", %{})
        |> subscribe_and_join(AgentChannel, "agent:BUB-789")

      other_payload = %{
        event: "text_output",
        turn: 1,
        detail: "some text",
        tokens: %{input: 10, output: 5},
        timestamp: "2026-01-01T00:00:00Z"
      }

      Phoenix.PubSub.broadcast(@pubsub, "agent:DIFFERENT-999", {:agent_event, other_payload})

      refute_push "agent_event", _
    end
  end
end
