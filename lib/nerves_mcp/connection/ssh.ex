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

  @impl NervesMCP.Connection.Transport
  def open(config) do
    with {:ok, executable, args, env} <- command(config) do
      {:ok,
       Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args, env: env])}
    end
  rescue
    error -> {:error, error}
  end

  @impl NervesMCP.Connection.Transport
  def write(port, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  # Closing the port only closes ssh's stdin, which an interactive session
  # outlives, so the process itself is told to stop as well.
  @impl NervesMCP.Connection.Transport
  def close(port) do
    os_pid = Port.info(port, :os_pid)
    if Port.info(port), do: Port.close(port)

    with {:os_pid, pid} <- os_pid, kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, [Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl NervesMCP.Connection.Transport
  def handle_message(port, {port, {:data, data}}), do: {:data, data}
  def handle_message(port, {port, {:exit_status, status}}), do: {:closed, {:exit_status, status}}
  def handle_message(_port, _message), do: :ignore

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
