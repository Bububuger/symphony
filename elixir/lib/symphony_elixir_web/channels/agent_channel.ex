defmodule SymphonyElixirWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time agent event streaming to external clients (CLI, tooling).

  Clients connect via WebSocket to topic "agent:<issue_id>" and receive live
  agent events broadcast from the Orchestrator via PubSub.

  ## Usage

      // JavaScript
      let channel = socket.channel("agent:BUB-123", {})
      channel.on("agent_event", payload => console.log(payload))
      channel.join()
  """

  use Phoenix.Channel

  @pubsub SymphonyElixir.PubSub

  @impl true
  def join("agent:" <> _issue_id = topic, _params, socket) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
    {:ok, socket}
  end

  @impl true
  def handle_info({:agent_event, event}, socket) do
    push(socket, "agent_event", event)
    {:noreply, socket}
  end
end
