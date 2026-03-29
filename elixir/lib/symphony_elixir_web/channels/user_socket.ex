defmodule SymphonyElixirWeb.UserSocket do
  @moduledoc """
  Phoenix Socket for external WebSocket clients (CLI, tooling).

  Mounts at /ws. Routes "agent:*" topics to AgentChannel for real-time
  agent event streaming.
  """

  use Phoenix.Socket

  channel "agent:*", SymphonyElixirWeb.AgentChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
