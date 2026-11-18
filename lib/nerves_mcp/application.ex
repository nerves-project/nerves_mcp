# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Application do
  @moduledoc false

  use Application

  alias EMCP.SessionStore

  require Logger

  @impl true
  def start(_type, _args) do
    # The host application may use emcp too, and have made the table already.
    if :ets.whereis(SessionStore.ETS) == :undefined, do: SessionStore.ETS.init()

    children = [
      {Registry, keys: :unique, name: NervesMCP.Registry},
      {DynamicSupervisor, name: NervesMCP.InstanceSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: NervesMCP.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      start_configured_server()
      {:ok, pid}
    end
  end

  # A connection in config.exs starts the default server; otherwise servers are
  # started by `NervesMCP.start_server/2` or the CLI.
  defp start_configured_server() do
    connection = Application.get_env(:nerves_mcp, :connection, [])

    if Keyword.has_key?(connection, :type) do
      opts = [
        connection: connection,
        port: Application.get_env(:nerves_mcp, :port, NervesMCP.default_port()),
        ip: Application.get_env(:nerves_mcp, :ip, :loopback),
        log_file: Application.get_env(:nerves_mcp, :log_file)
      ]

      with {:error, reason} <- NervesMCP.start_server(:default, opts) do
        Logger.error("NervesMCP could not start the configured server: #{inspect(reason)}")
      end
    end
  end
end
