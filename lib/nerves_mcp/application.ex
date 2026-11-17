# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    EMCP.SessionStore.ETS.init()

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
  defp start_configured_server do
    connection = Application.get_env(:nerves_mcp, :connection, [])

    if Keyword.has_key?(connection, :type) do
      port = Application.get_env(:nerves_mcp, :port, NervesMCP.default_port())
      {:ok, _server} = NervesMCP.start_server(:default, connection: connection, port: port)
    end
  end
end
