import Config

# Runtime configuration loaded when the release boots.
# Environment variables set here override compile-time config.

# Allow overriding the HTTP server port at runtime.
if port = System.get_env("SYMPHONY_PORT") do
  config :symphony_elixir, :server_port_override, String.to_integer(port)
end

# Allow overriding the logs root at runtime.
if logs_root = System.get_env("SYMPHONY_LOGS_ROOT") do
  config :symphony_elixir, :logs_root_override, logs_root
end

# In release mode, enable the Phoenix endpoint server process.
if config_env() == :prod do
  config :symphony_elixir, SymphonyElixirWeb.Endpoint, server: true
end
