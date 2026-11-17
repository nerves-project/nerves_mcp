defmodule NervesMCP do
  @moduledoc """
  MCP Server for interacting with Nerves devices.

  ## Running the Server

  Start with `mix run --no-halt` or `iex -S mix`.

  The MCP server will be available at: `http://localhost:8080/mcp`

  ## Configuration

  Configure in your `config/config.exs`:

  ### HTTP Server Port

      config :nerves_mcp, :port, 8080

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
  """

  alias NervesMCP.Connection
  alias NervesMCP.Instance

  @default_port 13_000
  @port_span 100

  @type id :: term()
  @type server :: %{id: id(), port: :inet.port_number(), url: String.t(), connection: keyword()}

  @doc "The port the first server listens on unless told otherwise."
  @spec default_port() :: :inet.port_number()
  def default_port, do: @default_port

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
      all interfaces; pass `:loopback` to accept local clients only.

  Returns `{:error, :already_started}` if a server with this id is running and
  `{:error, :no_free_port}` if none of the ports could be used.
  """
  @spec start_server(id(), keyword()) :: {:ok, server()} | {:error, term()}
  def start_server(id, opts) do
    connection = Keyword.fetch!(opts, :connection)
    ip = Keyword.take(opts, [:ip])

    ports =
      case Keyword.get(opts, :port, @default_port..(@default_port + @port_span - 1)) do
        port when is_integer(port) -> [port]
        ports -> ports
      end

    if server(id) do
      {:error, :already_started}
    else
      start_on_first_free(id, connection, ip, Enum.to_list(ports), :no_free_port)
    end
  end

  defp start_on_first_free(_id, _connection, _ip, [], last_error), do: {:error, last_error}

  defp start_on_first_free(id, connection, ip, [port | rest], last_error) do
    if port_free?(port, ip) do
      spec = {Instance, [id: id, connection: connection, port: port] ++ ip}

      case DynamicSupervisor.start_child(NervesMCP.InstanceSupervisor, spec) do
        {:ok, _pid} -> {:ok, server(id)}
        {:error, {:already_started, _pid}} -> {:error, :already_started}
        # Something else took the port between the check and the bind.
        {:error, reason} -> start_on_first_free(id, connection, ip, rest, reason)
      end
    else
      start_on_first_free(id, connection, ip, rest, last_error)
    end
  end

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
  def servers, do: Enum.map(Instance.all(), &describe/1)

  defp describe(info), do: Map.put(info, :url, "http://localhost:#{info.port}/mcp")

  @doc """
  Opens an interactive console to the connected device.

  Displays all incoming data from the device and allows you to send
  commands directly. Type `#quit` to exit the console and return to IEx.
  """
  def console(id \\ :default) do
    # Start a process to receive and display console data
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
      # Clean up: stop receiver and detach console
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
  def history(id \\ :default) do
    IO.puts(NervesMCP.History.get(id))
    :ok
  end

  def exit do
    IO.puts("Exiting...")
    System.halt(0)
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
        # Write any remaining buffer on exit
        if byte_size(buffer) > 0 do
          IO.write(buffer)
        end

        :ok
    end
  end

  # Split binary into complete UTF-8 characters and trailing incomplete bytes
  defp split_utf8(binary) do
    size = byte_size(binary)

    if size == 0 do
      {<<>>, <<>>}
    else
      # Find how many trailing bytes might be incomplete
      incomplete_count = trailing_incomplete_bytes(binary, size)
      complete_size = size - incomplete_count
      <<complete::binary-size(^complete_size), incomplete::binary>> = binary
      {complete, incomplete}
    end
  end

  # Count trailing bytes that form an incomplete UTF-8 sequence
  defp trailing_incomplete_bytes(binary, size) do
    # Check last 1-4 bytes for incomplete sequence
    check_from = max(0, size - 4)

    size
    |> Range.new(check_from + 1, -1)
    |> Enum.reduce_while(0, fn pos, _acc ->
      idx = pos - 1
      <<_::binary-size(^idx), byte, _rest::binary>> = binary

      cond do
        # ASCII or valid end of multi-byte - everything complete
        byte <= 127 ->
          {:halt, 0}

        # Continuation byte (10xxxxxx) - keep looking back
        byte in 128..191 ->
          {:cont, size - idx}

        # 2-byte start (110xxxxx) - need 1 more
        byte in 192..223 ->
          remaining = size - idx
          {:halt, if(remaining < 2, do: remaining, else: 0)}

        # 3-byte start (1110xxxx) - need 2 more
        byte in 224..239 ->
          remaining = size - idx
          {:halt, if(remaining < 3, do: remaining, else: 0)}

        # 4-byte start (11110xxx) - need 3 more
        byte in 240..247 ->
          remaining = size - idx
          {:halt, if(remaining < 4, do: remaining, else: 0)}

        # Invalid UTF-8 byte - treat as complete to avoid infinite buffering
        true ->
          {:halt, 0}
      end
    end)
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
