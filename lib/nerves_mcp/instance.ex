# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Instance do
  @moduledoc false

  # One MCP server for one device: its HTTP listener, device connection,
  # output history and probe. Every process is registered under the server id,
  # so any number of them can run side by side.

  use Supervisor

  @registry NervesMCP.Registry
  @current :nerves_mcp_instance

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    connection = Keyword.fetch!(opts, :connection)

    info = %{
      port: Keyword.fetch!(opts, :port),
      connection: Keyword.delete(connection, :pass)
    }

    Supervisor.start_link(__MODULE__, opts, name: via(id, :instance, info))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    connection = Keyword.fetch!(opts, :connection)

    bandit =
      [plug: {NervesMCP.Router, id}, port: Keyword.fetch!(opts, :port)] ++
        Keyword.take(opts, [:ip])

    children = [
      {NervesMCP.History, id: id},
      {Bandit, bandit},
      {connection_module(connection), id: id, config: connection},
      {NervesMCP.DeviceProbe, id: id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def via(id, role), do: {:via, Registry, {@registry, {id, role}}}
  def via(id, role, value), do: {:via, Registry, {@registry, {id, role}, value}}

  def lookup(id, role) do
    case Registry.lookup(@registry, {id, role}) do
      [{pid, value}] -> {:ok, pid, value}
      [] -> :error
    end
  end

  def all do
    @registry
    |> Registry.select([{{{:"$1", :instance}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, info} -> Map.put(info, :id, id) end)
  end

  # The MCP transport asks for the server definition without saying which
  # listener the request arrived on, so the router records it for the request.
  def put_current(id), do: Process.put(@current, id)
  def current, do: Process.get(@current, :default)

  defp connection_module(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart -> NervesMCP.Connection.UART
      :ssh -> NervesMCP.Connection.SSH
    end
  end
end
