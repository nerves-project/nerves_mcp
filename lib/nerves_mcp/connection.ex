# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection do
  @moduledoc """
  Talks to the device behind a running server, whichever transport it uses.

  Every function takes the id the server was started with, see
  `NervesMCP.start_server/2`.

  Requests to one device run one at a time. A request made while another is in
  flight waits its turn, and its timeout starts counting when it is sent to the
  device.
  """

  alias NervesMCP.Connection.Protocol
  alias NervesMCP.Connection.SSH
  alias NervesMCP.Instance

  @type id() :: term()
  @type result() :: {:ok, String.t()} | {:error, String.t()}

  @poll_timeout 5_000
  @poll_pause 2_000

  @doc """
  Evaluates Elixir code on the device and returns the inspected result.

  Code that raises, throws or exits gives `{:error, formatted_exception}`.
  """
  @spec eval(id(), String.t(), timeout()) :: result()
  def eval(id, code, timeout \\ 15_000), do: request(id, {:eval, code, timeout})

  @doc "Evaluates Elixir code on the device, capturing what it prints as well."
  @spec eval_output(id(), String.t(), timeout()) :: result()
  def eval_output(id, code, timeout \\ 15_000), do: request(id, {:eval_output, code, timeout})

  @doc "Runs a shell command on a device that offers a shell rather than IEx."
  @spec shell_eval(id(), String.t(), timeout()) :: result()
  def shell_eval(id, command, timeout \\ 15_000), do: request(id, {:shell_eval, command, timeout})

  @doc "Runs a shell command, capturing stdout, stderr and the exit code."
  @spec shell_eval_output(id(), String.t(), timeout()) :: result()
  def shell_eval_output(id, command, timeout \\ 15_000),
    do: request(id, {:shell_eval_output, command, timeout})

  @doc """
  Reads the UUID of the firmware the device is running.

  Fails when the device does not answer, does not run Nerves, or has no UUID.
  """
  @spec firmware_uuid(id(), timeout()) :: result()
  def firmware_uuid(id, timeout \\ @poll_timeout) do
    with {:ok, value} <- eval(id, Protocol.firmware_uuid_code(), timeout) do
      parse_uuid(value)
    end
  end

  @doc """
  Waits for the device to answer with a firmware UUID, for up to `timeout` ms.

  Useful after a reboot or a firmware update. An SSH connection is re-established
  between attempts, since a session to a rebooted device can hang for a while.
  """
  @spec await_firmware_uuid(id(), non_neg_integer()) :: result()
  def await_firmware_uuid(id, timeout \\ 60_000) do
    poll_firmware_uuid(id, now() + timeout, "no attempt was made")
  end

  defp poll_firmware_uuid(id, deadline, last_error) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, "Timed out waiting for the device to come up (#{last_error})"}
    else
      case firmware_uuid(id, min(@poll_timeout, remaining)) do
        {:ok, uuid} ->
          {:ok, uuid}

        {:error, reason} ->
          reconnect(id)
          Process.sleep(min(@poll_pause, max(0, deadline - now())))
          poll_firmware_uuid(id, deadline, reason)
      end
    end
  end

  @doc false
  @spec parse_uuid(String.t()) :: result()
  def parse_uuid(value) do
    case Regex.run(~r/^"([^"\s]+)"$/, String.trim(value)) do
      [_quoted, uuid] -> {:ok, uuid}
      nil -> {:error, "device has no firmware UUID, it answered: #{String.trim(value)}"}
    end
  end

  @doc """
  Probes what is on the other end. Returns:

    * `{:ok, result}` - Elixir ran and gave this for the firmware UUID
    * `{:eval_error, message}` - Elixir ran, but reading the UUID failed
    * `:noise` - bytes came back but no Elixir result
    * `:down` - not connected, or nothing came back
    * `:busy` - other requests are in flight
  """
  @spec probe(id(), timeout()) ::
          {:ok, String.t()} | {:eval_error, String.t()} | :noise | :down | :busy
  def probe(id, timeout \\ 4_000) do
    GenServer.call(Instance.via(id, :connection), {:probe, timeout}, timeout + 1000)
  catch
    :exit, _reason -> :down
  end

  @doc "Drops and re-establishes the connection. Only SSH needs this; UART is a no-op."
  @spec reconnect(id()) :: :ok | {:error, String.t()}
  def reconnect(id) do
    case type(id) do
      :ssh -> GenServer.call(Instance.via(id, :connection), :reconnect, 10_000)
      _other -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc "Sends everything the device prints outside of requests to `pid` as `{:console_data, binary}`."
  @spec attach_console(id(), pid()) :: :ok
  def attach_console(id, pid \\ self()) do
    GenServer.call(Instance.via(id, :connection), {:attach_console, pid})
  end

  @spec detach_console(id()) :: :ok
  def detach_console(id) do
    GenServer.call(Instance.via(id, :connection), :detach_console)
  end

  @doc "Writes bytes to the device as they are."
  @spec send_raw(id(), iodata()) :: :ok
  def send_raw(id, data) do
    GenServer.cast(Instance.via(id, :connection), {:send_raw, data})
  end

  @doc "The connection process for a server, if it is running."
  @spec whereis(id()) :: pid() | nil
  def whereis(id) do
    case Instance.lookup(id, :connection) do
      {:ok, pid, _type} -> pid
      :error -> nil
    end
  end

  @doc "The transport a server uses: `:ssh`, `:uart`, or `nil` when it is not running."
  @spec type(id()) :: :ssh | :uart | nil
  def type(id) do
    case Instance.lookup(id, :connection) do
      {:ok, _pid, type} -> type
      :error -> nil
    end
  end

  @doc """
  Checks a `:connection` option before a server is started with it.
  """
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  def validate(connection) do
    if Keyword.keyword?(connection) do
      validate_type(Keyword.get(connection, :type), connection)
    else
      {:error, "connection must be a keyword list"}
    end
  end

  defp validate_type(:ssh, connection) do
    if is_binary(connection[:host]) do
      SSH.validate(connection)
    else
      {:error, "an :ssh connection needs a :host"}
    end
  end

  defp validate_type(:uart, connection) do
    if is_binary(connection[:port]), do: :ok, else: {:error, "a :uart connection needs a :port"}
  end

  defp validate_type(other, _connection) do
    {:error, "connection :type must be :ssh or :uart, got: #{inspect(other)}"}
  end

  # The connection always answers, by its own timer at the latest.
  defp request(id, message) do
    GenServer.call(Instance.via(id, :connection), message, :infinity)
  catch
    :exit, {:noproc, _call} ->
      {:error, "Device connection not available (process not running)"}

    :exit, reason ->
      {:error, "Device connection error: #{inspect(reason)}"}
  end

  defp now(), do: System.monotonic_time(:millisecond)
end
