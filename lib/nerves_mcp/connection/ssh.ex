# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.SSH do
  @moduledoc false

  # An interactive session through the system `ssh`, run as a port.

  @behaviour NervesMCP.Connection.Transport

  # Nerves devices get a new host key with every fresh firmware, so the key is
  # not checked.
  @base_args [
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "ServerAliveInterval=60"
  ]

  # Kills the process named in $0 once stdin closes, which it does when the
  # port is closed and when the VM goes away without closing anything.
  @watch ~s(cat >/dev/null; kill "$0" 2>/dev/null)

  @impl NervesMCP.Connection.Transport
  def open(config) do
    with {:ok, executable, args, env} <- command(config) do
      port =
        Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args, env: env])

      {:ok, {port, watch(port)}}
    end
  rescue
    error -> {:error, error}
  end

  # An interactive ssh outlives its stdin being closed, so it has to be killed.
  defp watch(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         sh when is_binary(sh) <- System.find_executable("sh") do
      Port.open({:spawn_executable, sh}, args: ["-c", @watch, Integer.to_string(pid)])
    else
      _unavailable -> nil
    end
  end

  @impl NervesMCP.Connection.Transport
  def write({port, _watcher}, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl NervesMCP.Connection.Transport
  def close({port, watcher}) do
    for open <- [port, watcher], is_port(open) and Port.info(open) != nil, do: Port.close(open)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl NervesMCP.Connection.Transport
  def handle_message({port, _watcher}, {port, {:data, data}}), do: {:data, data}

  def handle_message({port, _watcher}, {port, {:exit_status, status}}),
    do: {:closed, {:exit_status, status}}

  def handle_message(_handle, _message), do: :ignore

  @impl NervesMCP.Connection.Transport
  def frame(text), do: text <> "\r\n"

  @doc "Checks that the programs this connection needs are installed."
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(config) do
    case command(config) do
      {:ok, _executable, _args, _env} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp command(config) do
    host = Keyword.fetch!(config, :host)
    user = Keyword.get(config, :user, "root")
    port = Keyword.get(config, :port, 22)
    destination = ["-p", "#{port}", "-tt", "#{user}@#{host}"]

    case {Keyword.get(config, :pass), System.find_executable("ssh")} do
      {_pass, nil} ->
        {:error, "ssh executable not found in PATH"}

      {nil, ssh} ->
        {:ok, ssh, @base_args ++ ["-o", "BatchMode=yes"] ++ destination, []}

      {pass, _ssh} ->
        with_sshpass(pass, @base_args ++ destination)
    end
  end

  # The password goes through the environment so it does not show up in `ps`.
  defp with_sshpass(pass, args) do
    case System.find_executable("sshpass") do
      nil ->
        {:error, "a password needs the sshpass executable, which was not found in PATH"}

      sshpass ->
        {:ok, sshpass, ["-e", "ssh" | args], [{~c"SSHPASS", String.to_charlist(pass)}]}
    end
  end
end
