defmodule NervesMCP.Connection do
  @moduledoc """
  Talks to the device behind a running server, whichever transport it uses.

  Every function takes the id the server was started with, see
  `NervesMCP.start_server/2`.
  """

  alias NervesMCP.Instance

  @type id :: term()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @doc "Evaluate Elixir code on the device and return the inspected result."
  @spec eval(id(), String.t(), timeout()) :: result()
  def eval(id, code, timeout \\ 15_000), do: request(id, {:eval, code, timeout}, timeout)

  @doc "Evaluate Elixir code on the device, capturing what it prints as well."
  @spec eval_output(id(), String.t(), timeout()) :: result()
  def eval_output(id, code, timeout \\ 15_000),
    do: request(id, {:eval_output, code, timeout}, timeout)

  @doc "Run a raw shell command (no Elixir wrapping). Used in degraded shell mode."
  @spec shell_eval(id(), String.t(), timeout()) :: result()
  def shell_eval(id, command, timeout \\ 15_000),
    do: request(id, {:shell_eval, command, timeout}, timeout)

  @doc "Run a raw shell command and capture stdout/stderr plus exit code."
  @spec shell_eval_output(id(), String.t(), timeout()) :: result()
  def shell_eval_output(id, command, timeout \\ 15_000),
    do: request(id, {:shell_eval_output, command, timeout}, timeout)

  @doc """
  Probe what is on the other end. Returns:

    * `{:ok, result}` — an Elixir result came back (classify it upstream)
    * `:noise`        — bytes came back but no valid Elixir result
    * `:down`         — not connected / nothing came back
    * `:busy`         — an evaluation is already in flight
  """
  def probe(id, timeout \\ 4_000) do
    GenServer.call(Instance.via(id, :connection), {:probe, timeout}, timeout + 1000)
  catch
    :exit, _ -> :down
  end

  @doc "Drop and re-establish the connection. Only SSH needs this; UART is a no-op."
  def reconnect(id) do
    case type(id) do
      :ssh -> GenServer.call(Instance.via(id, :connection), :reconnect, 10_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def attach_console(id, pid \\ self()) do
    GenServer.call(Instance.via(id, :connection), {:attach_console, pid})
  end

  def detach_console(id) do
    GenServer.call(Instance.via(id, :connection), :detach_console)
  end

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

  defp request(id, message, timeout) do
    GenServer.call(Instance.via(id, :connection), message, timeout + 1000)
  catch
    :exit, {:noproc, _} ->
      {:error, "Device connection not available (process not running)"}

    :exit, reason ->
      {:error, "Device connection error: #{inspect(reason)}"}
  end
end
