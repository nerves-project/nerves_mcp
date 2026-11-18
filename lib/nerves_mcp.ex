# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP do
  @moduledoc """
  MCP Server for interacting with Nerves devices.

  ## Running the Server

  Start with `mix nerves_mcp`, or with `iex -S mix` when a connection is
  configured.

  The MCP server will be available at: `http://localhost:13000/mcp`

  ## Configuration

  Configure in your `config/config.exs`:

  ### HTTP Server Port

      config :nerves_mcp, :port, 13000

  The server only accepts connections from this machine. To listen on every
  interface, on a network you trust:

      config :nerves_mcp, :ip, :any

  ### UART (Serial) Connection

      config :nerves_mcp, :connection,
        type: :uart,
        port: "/dev/ttyUSB2",
        speed: 115_200

  ### SSH Connection

      config :nerves_mcp, :connection,
        type: :ssh,
        host: "nerves.local",
        user: "root",
        port: 22

  ### Logging device output

  Nothing the device prints is written to disk unless you ask for it. To append
  everything the default server receives to a file:

      config :nerves_mcp, :log_file, "nerves_mcp.log"

  The file holds whatever passed over the console, which can include secrets.

  ## Interactive Console

  Call `NervesMCP.console()` to enter an interactive console session.
  Type `#quit` to exit and return to IEx, or `#history` to view buffered output.

  ## Output History

  Device output that arrives when no console is attached is stored in a
  circular buffer. Call `NervesMCP.history()` to view it, or use `#history`
  in the console.

  ## Use as a library

  A host application can run one server per device, each on its own port:

      {:ok, server} =
        NervesMCP.start_server("nerves-1234.local",
          connection: [type: :ssh, host: "nerves-1234.local"]
        )

      server.url
      #=> "http://localhost:13000/mcp"

  Ports are handed out from `default_port/0` upwards, so the first server lands
  on 13000, the next on 13001, and so on. Pass `:port` to choose where to look,
  see `start_server/2`.

  To collect what goes on with a device, pass a function as `:on_output`. It is
  given everything the device prints, including what the MCP tools cause:

      NervesMCP.start_server(id,
        connection: connection,
        on_output: fn data -> MyApp.DeviceLog.append(id, data) end
      )
  """

  alias NervesMCP.Connection
  alias NervesMCP.Instance

  @default_port 13_000
  @port_span 100

  @type id :: term()
  @type server :: %{id: id(), port: :inet.port_number(), url: String.t(), connection: keyword()}

  @doc "The port the first server listens on unless told otherwise."
  @spec default_port() :: :inet.port_number()
  def default_port(), do: @default_port

  @doc """
  Starts an MCP server for one device.

  `id` names the server and is what every other function takes to refer to it.
  Any term works; a hostname or serial port path is a natural choice.

  ## Options

    * `:connection` (required) - how to reach the device, in the same shape as
      the `:connection` application config: `[type: :ssh, host: "nerves.local",
      user: "root", port: 22]` or `[type: :uart, port: "/dev/ttyUSB0", speed:
      115_200]`.
    * `:port` - the HTTP port to listen on. Either one port, or an enumerable of
      ports to try in order, of which the first free one is used. Defaults to
      #{@default_port}..#{@default_port + @port_span - 1}. To keep a device on
      the port it had last time, put that port first.
    * `:ip` - the address to listen on, as Bandit's `:ip` option. Defaults to
      `:loopback`, which accepts local clients only. Anyone who can reach the
      port can run code on the device, so only pass `:any` on a trusted network.
    * `:on_output` - a function that is called with each piece of output the
      device sends, as a binary. Pieces arrive as they come off the wire, so
      they do not line up with lines. The function runs in the connection
      process and holds up the device while it does, so keep it quick. Not set
      by default.
    * `:log_file` - a file to append all device output to. Not set by default.

  Returns `{:error, :already_started}` if a server with this id is running,
  `{:error, :no_free_port}` if none of the ports could be used,
  `{:error, {:invalid_connection, message}}` if the connection cannot work and
  `{:error, {:invalid_option, message}}` if another option cannot be used.
  """
  @spec start_server(id(), keyword()) :: {:ok, server()} | {:error, term()}
  def start_server(id, opts) do
    connection = Keyword.fetch!(opts, :connection)
    ip = Keyword.get(opts, :ip, :loopback)

    ports =
      case Keyword.get(opts, :port, @default_port..(@default_port + @port_span - 1)) do
        port when is_integer(port) -> [port]
        ports -> ports
      end

    with nil <- server(id),
         :ok <- Connection.validate(connection),
         {:ok, outputs} <- outputs(opts) do
      settings = [id: id, connection: connection, ip: ip, outputs: outputs]
      start_on_first_free(settings, Enum.to_list(ports))
    else
      %{} -> {:error, :already_started}
      {:error, {:invalid_option, _message}} = error -> error
      {:error, message} -> {:error, {:invalid_connection, message}}
    end
  end

  defp outputs(opts) do
    with {:ok, callback} <- callback_output(opts[:on_output]),
         {:ok, log} <- log_output(opts[:log_file]) do
      {:ok, callback ++ log}
    end
  end

  defp callback_output(nil), do: {:ok, []}
  defp callback_output(fun) when is_function(fun, 1), do: {:ok, [fun]}

  defp callback_output(_other),
    do: {:error, {:invalid_option, ":on_output must be a function that takes one argument"}}

  defp log_output(nil), do: {:ok, []}

  defp log_output(path) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "", [:append]) do
      {:ok, [&File.write!(path, &1, [:append])]}
    else
      {:error, reason} ->
        {:error,
         {:invalid_option, "cannot write to log file #{path}: #{:file.format_error(reason)}"}}
    end
  end

  defp log_output(_other), do: {:error, {:invalid_option, ":log_file must be a path"}}

  defp start_on_first_free(_settings, []), do: {:error, :no_free_port}

  defp start_on_first_free(settings, [port | rest]) do
    case try_port(settings, port) do
      :taken -> start_on_first_free(settings, rest)
      result -> result
    end
  end

  defp try_port(settings, port) do
    id = Keyword.fetch!(settings, :id)
    spec = {Instance, [port: port] ++ settings}

    with true <- port_free?(port, Keyword.take(settings, [:ip])),
         {:ok, _pid} <- DynamicSupervisor.start_child(NervesMCP.InstanceSupervisor, spec) do
      {:ok, server(id)}
    else
      false -> :taken
      {:error, {:already_started, _pid}} -> {:error, :already_started}
      # Something else may have taken the port between the check and the bind.
      {:error, reason} -> if address_in_use?(reason), do: :taken, else: {:error, reason}
    end
  end

  defp address_in_use?(:eaddrinuse), do: true

  defp address_in_use?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&address_in_use?/1)

  defp address_in_use?(_reason), do: false

  defp port_free?(port, ip) do
    case :gen_tcp.listen(port, ip) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc "Stops a server and closes its device connection."
  @spec stop_server(id()) :: :ok | {:error, :not_found}
  def stop_server(id) do
    case Instance.lookup(id, :instance) do
      {:ok, pid, _info} -> DynamicSupervisor.terminate_child(NervesMCP.InstanceSupervisor, pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Describes a running server, or returns `nil` if there is none with this id."
  @spec server(id()) :: server() | nil
  def server(id) do
    case Instance.lookup(id, :instance) do
      {:ok, _pid, info} -> describe(Map.put(info, :id, id))
      :error -> nil
    end
  end

  @doc "Describes every running server."
  @spec servers() :: [server()]
  def servers(), do: Enum.map(Instance.all(), &describe/1)

  defp describe(info), do: Map.put(info, :url, "http://localhost:#{info.port}/mcp")

  @doc """
  Opens an interactive console to the connected device.

  Displays all incoming data from the device and allows you to send
  commands directly. Type `#quit` to exit the console and return to IEx.
  """
  @spec console(id()) :: :ok
  def console(id \\ :default) do
    receiver =
      spawn_link(fn ->
        monitor_and_attach(id)
        receive_loop(id)
      end)

    IO.puts("Connected to device console. Commands: #quit, #history")
    IO.puts("---")

    try do
      input_loop(id)
    after
      send(receiver, :stop)
      Connection.detach_console(id)
    end

    IO.puts("---")
    IO.puts("Console closed.")
    :ok
  end

  @doc """
  Prints the buffered device output history.

  All device output that arrives when no console is attached is stored
  in a circular buffer. Use this to view what you might have missed.
  """
  @spec history(id()) :: :ok
  def history(id \\ :default) do
    IO.puts(NervesMCP.History.get(id))
    :ok
  end

  defp monitor_and_attach(id) do
    pid = wait_for_process(id)
    Process.monitor(pid)
    Connection.attach_console(id, self())
  end

  defp wait_for_process(id) do
    case Connection.whereis(id) do
      nil ->
        Process.sleep(200)
        wait_for_process(id)

      pid ->
        pid
    end
  end

  defp receive_loop(id, buffer \\ <<>>) do
    receive do
      {:console_data, data} ->
        combined = buffer <> data
        {complete, incomplete} = split_utf8(combined)

        if byte_size(complete) > 0 do
          IO.write(complete)
        end

        receive_loop(id, incomplete)

      {:DOWN, _ref, :process, _pid, _reason} ->
        IO.puts("\r\n--- Connection lost, reconnecting... ---")
        monitor_and_attach(id)
        IO.puts("--- Reconnected ---")
        receive_loop(id)

      :stop ->
        if byte_size(buffer) > 0 do
          IO.write(buffer)
        end

        :ok
    end
  end

  # Holds back a character that has only partly arrived.
  defp split_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      {:incomplete, complete, rest} -> {complete, rest}
      {:error, _valid, _rest} -> {binary, <<>>}
      complete -> {complete, <<>>}
    end
  end

  defp input_loop(id) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      input when is_binary(input) ->
        trimmed = String.trim_trailing(input, "\n")

        case trimmed do
          "#quit" ->
            :ok

          "#history" ->
            IO.puts("--- History ---")
            IO.puts(NervesMCP.History.get(id))
            IO.puts("--- End History ---")
            input_loop(id)

          _ ->
            Connection.send_raw(id, input)
            input_loop(id)
        end
    end
  end
end
