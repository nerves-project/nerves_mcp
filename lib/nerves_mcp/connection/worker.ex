# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.Worker do
  @moduledoc false

  # Owns the link to one device. Requests run one at a time, in the order they
  # arrive, and the link is reopened with a growing delay whenever it is lost.

  use GenServer

  alias NervesMCP.Connection.Protocol
  alias NervesMCP.History

  require Logger

  @initial_retry_delay 1_000
  @max_retry_delay 30_000
  @not_connected "Device not connected (reconnecting...)"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    type = Keyword.fetch!(opts, :type)
    GenServer.start_link(__MODULE__, opts, name: NervesMCP.Instance.via(id, :connection, type))
  end

  @impl GenServer
  def init(opts) do
    # Lets terminate/2 run on shutdown so the link is closed.
    Process.flag(:trap_exit, true)

    state = %{
      id: Keyword.fetch!(opts, :id),
      config: Keyword.fetch!(opts, :config),
      transport: Keyword.fetch!(opts, :transport),
      handle: nil,
      current: nil,
      queue: :queue.new(),
      console: nil,
      outputs: Keyword.get(opts, :outputs, []),
      retry_delay: @initial_retry_delay,
      retry_timer: nil,
      reported_down?: false
    }

    {:ok, open(state)}
  end

  @impl GenServer
  def handle_call({:attach_console, pid}, _from, state) do
    state = detach(state)
    {:reply, :ok, %{state | console: {pid, Process.monitor(pid)}}}
  end

  def handle_call(:detach_console, _from, state) do
    {:reply, :ok, detach(state)}
  end

  def handle_call(:reconnect, _from, state) do
    state = state |> drop("Device connection is being re-established") |> open()
    {:reply, if(state.handle, do: :ok, else: {:error, "reconnect failed"}), state}
  end

  def handle_call({:probe, _timeout}, _from, %{handle: nil} = state) do
    {:reply, :down, state}
  end

  def handle_call({:probe, _timeout} = request, from, state) do
    if state.current == nil and :queue.is_empty(state.queue) do
      {:noreply, start(state, from, request)}
    else
      {:reply, :busy, state}
    end
  end

  def handle_call({_kind, _text, _timeout}, _from, %{handle: nil} = state) do
    {:reply, {:error, @not_connected}, state}
  end

  def handle_call({_kind, _text, _timeout} = request, from, state) do
    {:noreply, next(%{state | queue: :queue.in({from, request}, state.queue)})}
  end

  @impl GenServer
  def handle_cast({:send_raw, data}, state) do
    if state.handle, do: state.transport.write(state.handle, data)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:reconnect, %{handle: nil} = state) do
    {:noreply, open(%{state | retry_timer: nil})}
  end

  def handle_info({:request_timeout, marker}, %{current: %{marker: marker}} = state) do
    %{from: from, kind: kind, acc: acc} = state.current

    reply =
      cond do
        kind != :probe -> {:error, "Timeout waiting for device response"}
        String.trim(acc) == "" -> :down
        true -> :noise
      end

    GenServer.reply(from, reply)
    {:noreply, next(%{state | current: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{console: {_console, ref}} = state) do
    {:noreply, %{state | console: nil}}
  end

  def handle_info(_message, %{handle: nil} = state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    case state.transport.handle_message(state.handle, message) do
      {:data, data} -> {:noreply, received(state, data)}
      {:closed, reason} -> {:noreply, lost(state, reason)}
      :ignore -> {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.handle, do: state.transport.close(state.handle)
    :ok
  end

  defp open(state) do
    case state.transport.open(state.config) do
      {:ok, handle} ->
        Logger.info("NervesMCP #{inspect(state.id)}: device link opened")
        to_console(state, "\r\n--- Connected ---\r\n")
        %{state | handle: handle}

      {:error, reason} ->
        retry(state, reason)
    end
  end

  defp lost(state, reason) do
    to_console(state, "\r\n--- Connection lost, reconnecting... ---\r\n")
    state |> drop("Device connection lost: #{inspect(reason)}") |> retry(reason)
  end

  # Closes the link and answers everything that was waiting on it.
  defp drop(state, message) do
    if state.handle, do: state.transport.close(state.handle)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)

    if state.current do
      Process.cancel_timer(state.current.timer)
      GenServer.reply(state.current.from, failure(state.current.kind, message))
    end

    for {from, {kind, _text, _timeout}} <- :queue.to_list(state.queue) do
      GenServer.reply(from, failure(kind, message))
    end

    %{state | handle: nil, current: nil, queue: :queue.new(), retry_timer: nil}
  end

  defp failure(:probe, _message), do: :down
  defp failure(_kind, message), do: {:error, message}

  defp retry(state, reason) do
    message = "NervesMCP #{inspect(state.id)}: no device link (#{inspect(reason)}), retrying"
    if state.reported_down?, do: Logger.debug(message), else: Logger.warning(message)

    %{
      state
      | retry_timer: Process.send_after(self(), :reconnect, state.retry_delay),
        retry_delay: min(state.retry_delay * 2, @max_retry_delay),
        reported_down?: true
    }
  end

  defp received(state, data) do
    History.push(state.id, data)
    emit(state, data)
    # Only a link that carries data counts as working again.
    state = %{state | retry_delay: @initial_retry_delay, reported_down?: false}

    case state.current do
      nil ->
        to_console(state, data)
        state

      %{marker: marker, style: style} = current ->
        frame = &state.transport.frame(&1)

        case Protocol.extract(current.acc <> data, marker, style, frame) do
          {:done, status, text} ->
            Process.cancel_timer(current.timer)
            GenServer.reply(current.from, result(current.kind, status, text))
            next(%{state | current: nil})

          {:cont, acc} ->
            %{state | current: %{current | acc: acc}}
        end
    end
  end

  # A failing output function must not take the device link down with it.
  defp emit(state, data) do
    for output <- state.outputs do
      try do
        output.(data)
      catch
        kind, reason ->
          Logger.warning(
            "NervesMCP #{inspect(state.id)}: output function failed: " <>
              Exception.format_banner(kind, reason)
          )
      end
    end
  end

  defp result(:probe, :error, text), do: {:eval_error, text}
  defp result(_kind, status, text), do: {status, text}

  defp next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {from, request}}, queue} -> start(%{state | queue: queue}, from, request)
      {:empty, _queue} -> state
    end
  end

  defp next(state), do: state

  defp start(state, from, request) do
    marker = Protocol.marker()
    {kind, style, payload, timeout} = encode(request, marker)
    state.transport.write(state.handle, payload)

    current = %{
      from: from,
      kind: kind,
      marker: marker,
      style: style,
      acc: "",
      timer: Process.send_after(self(), {:request_timeout, marker}, timeout)
    }

    %{state | current: current}
  end

  defp encode({:eval, code, timeout}, marker),
    do: {:eval, :elixir, Protocol.eval(code, marker), timeout}

  defp encode({:eval_output, code, timeout}, marker),
    do: {:eval, :elixir, Protocol.eval_output(code, marker), timeout}

  defp encode({:shell_eval, command, timeout}, marker),
    do: {:eval, :shell, Protocol.shell(command, marker), timeout}

  defp encode({:shell_eval_output, command, timeout}, marker),
    do: {:eval, :shell, Protocol.shell_output(command, marker), timeout}

  defp encode({:probe, timeout}, marker),
    do: {:probe, :elixir, Protocol.eval(Protocol.firmware_uuid_code(), marker), timeout}

  defp detach(%{console: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | console: nil}
  end

  defp detach(state), do: state

  defp to_console(%{console: {pid, _ref}}, data), do: send(pid, {:console_data, data})
  defp to_console(_state, _data), do: :ok
end
