# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.CLI do
  @moduledoc """
  CLI argument parsing and connection setup for NervesMCP.

  CLI args override values from config/config.exs. If no args are provided
  but config exists, the config values are used as-is.

  Supports two connection modes:

  **Serial (UART):**
      nerves_mcp /dev/ttyUSB0
      nerves_mcp --serial /dev/ttyUSB0 --speed 115200

  **SSH:**
      nerves_mcp nerves.local
      nerves_mcp --ssh nerves.local --user root --ssh-port 22

  Common options:
      --port PORT    MCP server port (default: 13000)
      --ip ADDRESS   Address to listen on (default: loopback), or "any"

  The escript build only supports SSH, since the serial driver cannot be
  packed into an escript. Use `mix nerves_mcp` for serial devices.
  """

  @serial_patterns ["/dev/tty", "/dev/cu.", "/dev/serial"]

  @switches [
    serial: :string,
    ssh: :string,
    port: :integer,
    ip: :string,
    speed: :integer,
    user: :string,
    ssh_port: :integer,
    pass: :string
  ]

  @usage """
  Usage: nerves_mcp <device-or-host> [options]

  Examples:
    nerves_mcp /dev/ttyUSB0                   # Serial connection
    nerves_mcp /dev/ttyUSB0 --speed 9600      # Serial with custom baud rate
    nerves_mcp nerves.local                    # SSH connection
    nerves_mcp nerves.local --user root        # SSH with custom user
    nerves_mcp --serial /dev/ttyACM0           # Explicit serial
    nerves_mcp --ssh 192.168.1.100             # Explicit SSH

  Options:
    --port PORT        MCP server port (default: 13000)
    --ip ADDRESS       Address to listen on, or "any" (default: loopback only)
    --speed BAUD       Serial baud rate (default: 115200)
    --user USER        SSH user (default: root)
    --ssh-port PORT    SSH port (default: 22)
    --pass PASSWORD    SSH password (requires sshpass; not for high-security use)

  Connection can also be configured in config/config.exs.
  CLI arguments override config values.
  """

  @doc "Entry point of the escript."
  @spec main([String.t()]) :: :ok
  def main(args) do
    run(args, serial?: false)
    repl()
  end

  @spec repl() :: :ok
  def repl() do
    case IO.gets("> ") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      input when is_binary(input) ->
        input
        |> String.trim()
        |> handle_command()

        repl()
    end
  end

  defp handle_command("console"), do: NervesMCP.console()
  defp handle_command("history"), do: NervesMCP.history()
  defp handle_command("exit"), do: System.halt(0)
  defp handle_command("help"), do: IO.puts("Commands: console, history, exit, help")
  defp handle_command(""), do: :ok
  defp handle_command(other), do: IO.puts("Unknown command: #{other}. Type 'help' for commands.")

  @doc """
  Starts the default server from command line arguments, halting with a
  message when they do not describe a usable connection.
  """
  @spec run([String.t()], keyword()) :: :ok
  def run(args, opts \\ []) do
    config = [
      connection: Application.get_env(:nerves_mcp, :connection, []),
      port: Application.get_env(:nerves_mcp, :port, NervesMCP.default_port()),
      ip: Application.get_env(:nerves_mcp, :ip, :loopback)
    ]

    with {:ok, settings} <- parse(args, config),
         :ok <- check_transport(settings[:connection], Keyword.get(opts, :serial?, true)),
         {:ok, server} <- start(settings) do
      IO.puts("NervesMCP started at #{server.url} via #{describe(settings[:connection])}")
      maybe_print_claude_hint(server.url)
    else
      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc """
  Works out the server settings from command line arguments and the settings
  already configured, which the arguments override.
  """
  @spec parse([String.t()], keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def parse(args, config) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: aliases())

    with :ok <- check_invalid(invalid),
         {:ok, ip} <- parse_ip(opts[:ip], config[:ip]),
         {:ok, connection} <- resolve_connection(opts, positional, config[:connection]) do
      {:ok, [connection: connection, port: Keyword.get(opts, :port, config[:port]), ip: ip]}
    end
  end

  defp aliases(), do: [p: :port, s: :speed, u: :user]

  defp check_invalid([]), do: :ok

  defp check_invalid(invalid) do
    flags = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
    {:error, "Unknown or malformed option: #{flags}\n\n#{@usage}"}
  end

  defp parse_ip(nil, configured), do: {:ok, configured}
  defp parse_ip("any", _configured), do: {:ok, :any}
  defp parse_ip("loopback", _configured), do: {:ok, :loopback}

  defp parse_ip(address, _configured) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, "Not an IP address: #{address}"}
    end
  end

  defp check_transport(connection, serial?) do
    if connection[:type] == :uart and not serial? do
      {:error,
       "Serial devices are not supported by the escript. Run `mix nerves_mcp` in a project that depends on nerves_mcp instead."}
    else
      :ok
    end
  end

  defp start(settings) do
    # A connection in config.exs has already started the default server.
    NervesMCP.stop_server(:default)

    case NervesMCP.start_server(:default, settings) do
      {:ok, server} ->
        {:ok, server}

      {:error, {:invalid_connection, message}} ->
        {:error, "Cannot connect: #{message}"}

      {:error, reason} ->
        {:error, "Could not start NervesMCP on port #{settings[:port]}: #{inspect(reason)}"}
    end
  end

  defp describe(connection) do
    case Keyword.fetch!(connection, :type) do
      :uart ->
        "serial #{connection[:port]} @ #{Keyword.get(connection, :speed, 115_200)}"

      :ssh ->
        "ssh #{Keyword.get(connection, :user, "root")}@#{connection[:host]}:#{Keyword.get(connection, :port, 22)}"
    end
  end

  defp maybe_print_claude_hint(url) do
    if System.find_executable("claude") do
      IO.puts("""

      Claude Code detected. Add this MCP server with:
        claude mcp add --transport http nerves #{url}
      """)
    end
  end

  defp resolve_connection(opts, positional, configured) do
    cond do
      opts[:serial] -> {:ok, serial_config(opts[:serial], opts, configured)}
      opts[:ssh] -> {:ok, ssh_config(opts[:ssh], opts, configured)}
      positional != [] -> {:ok, positional_config(hd(positional), opts, configured)}
      Keyword.has_key?(configured, :type) -> {:ok, apply_overrides(configured, opts)}
      true -> {:error, @usage}
    end
  end

  defp positional_config(target, opts, configured) do
    if Enum.any?(@serial_patterns, &String.starts_with?(target, &1)) do
      serial_config(target, opts, configured)
    else
      ssh_config(target, opts, configured)
    end
  end

  defp serial_config(device, opts, configured) do
    base =
      if configured[:type] == :uart, do: configured, else: [type: :uart, speed: 115_200]

    base
    |> Keyword.put(:port, device)
    |> apply_overrides(opts)
  end

  defp ssh_config(host, opts, configured) do
    base =
      if configured[:type] == :ssh, do: configured, else: [type: :ssh, user: "root", port: 22]

    base
    |> Keyword.put(:host, host)
    |> apply_overrides(opts)
  end

  defp apply_overrides(config, opts) do
    case config[:type] do
      :uart ->
        maybe_put(config, :speed, opts[:speed])

      :ssh ->
        config
        |> maybe_put(:user, opts[:user])
        |> maybe_put(:port, opts[:ssh_port])
        |> maybe_put(:pass, opts[:pass])
    end
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)
end
