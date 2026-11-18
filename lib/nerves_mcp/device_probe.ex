# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.DeviceProbe do
  @moduledoc """
  Detects what is on the other end of the device connection and decides which
  MCP tools should be exposed.

  When no MCP activity has happened for `idle_threshold` ms, a small probe is
  sent to the device. The probe evaluates the Nerves firmware UUID and classifies
  the connection into one of:

    * `:nerves`  - Elixir evaluated and a firmware UUID came back (confirmed Nerves)
    * `:elixir`  - Elixir evaluated but no UUID (Elixir runs, not a Nerves device)
    * `:shell`   - bytes came back but no valid Elixir result (some other serial)
    * `:down`    - nothing came back at all
    * `:unknown` - not probed yet / could not determine

  The probe is resilient: a device that returns *some* output but cannot run
  Elixir degrades to `:shell` rather than reporting failure, so the server can
  still offer the shell tools.

  `NervesMCP.Server.server/0` reads `mode/1` on every request and lists tools
  accordingly. On a mode change we broadcast `notifications/tools/list_changed`
  so connected clients refetch the tool list immediately.
  """

  use GenServer

  alias EMCP.SessionStore
  alias EMCP.Transport.StreamableHTTP

  require Logger

  @type mode() :: :nerves | :elixir | :shell | :down | :unknown
  @type status() :: %{
          mode: mode(),
          detail: String.t(),
          idle_ms: integer() | nil,
          last_probe_ms_ago: integer() | nil
        }

  @idle_threshold 10_000
  @tick 2_000
  @probe_timeout 4_000

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: name(id))
  end

  defp name(id), do: NervesMCP.Instance.via(id, :probe)

  @doc "Current detected mode. Fast, non-blocking; falls back to `:unknown`."
  @spec mode(term()) :: mode()
  def mode(id) do
    GenServer.call(name(id), :mode, 1_000)
  catch
    :exit, _ -> :unknown
  end

  @doc "Full status map for the device_status tool."
  @spec status(term()) :: status()
  def status(id) do
    GenServer.call(name(id), :status, 1_000)
  catch
    :exit, _ ->
      %{mode: :unknown, detail: "probe not running", idle_ms: nil, last_probe_ms_ago: nil}
  end

  @doc "Record MCP activity so the idle timer does not probe during active use."
  @spec touch(term()) :: :ok
  def touch(id) do
    GenServer.cast(name(id), :touch)
  end

  @doc "Run a probe synchronously in the caller and update the cached mode."
  @spec refresh(term(), timeout()) :: {mode() | :busy, String.t()}
  def refresh(id, timeout \\ @probe_timeout) do
    result = run_probe(id, timeout)
    GenServer.cast(name(id), {:set_result, result})
    result
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    schedule_tick()
    # Start as if already idle so we probe shortly after boot.
    now = mono()

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       mode: :unknown,
       detail: "not yet probed",
       last_activity: now - @idle_threshold,
       last_probe: nil,
       probing?: false,
       task_ref: nil
     }}
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  def handle_call(:status, _from, state) do
    now = mono()

    status = %{
      mode: state.mode,
      detail: state.detail,
      idle_ms: now - state.last_activity,
      last_probe_ms_ago: state.last_probe && now - state.last_probe
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_activity: mono()}}
  end

  def handle_cast({:set_result, result}, state) do
    {:noreply, %{apply_result(state, result) | last_probe: mono()}}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, maybe_probe(state)}
  end

  def handle_info({:probe_result, result}, state) do
    state = apply_result(state, result)
    {:noreply, %{state | probing?: false, task_ref: nil, last_probe: mono()}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    # Backstop: if the probe task crashed before replying, clear the flag so we
    # do not get stuck never probing again.
    if reason == :normal do
      {:noreply, state}
    else
      {:noreply, %{state | probing?: false, task_ref: nil, last_probe: mono()}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Probing

  defp maybe_probe(%{probing?: true} = state), do: state

  defp maybe_probe(state) do
    now = mono()
    idle = now - state.last_activity
    since_probe = if state.last_probe, do: now - state.last_probe, else: @idle_threshold

    if idle >= @idle_threshold and since_probe >= @idle_threshold do
      start_probe(state)
    else
      state
    end
  end

  defp start_probe(state) do
    parent = self()
    id = state.id

    {_pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:probe_result, run_probe(id, @probe_timeout)})
      end)

    %{state | probing?: true, task_ref: ref}
  end

  @doc false
  @spec run_probe(term(), timeout()) :: {mode() | :busy, String.t()}
  def run_probe(id, timeout) do
    raw =
      try do
        NervesMCP.Connection.probe(id, timeout)
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    classify(raw)
  end

  defp classify({:ok, result}) do
    trimmed = String.trim(result)

    cond do
      trimmed == "" ->
        {:elixir, "Elixir responded with no output"}

      trimmed == "nil" ->
        {:elixir, "Elixir runs; no firmware UUID (not provisioned?)"}

      Regex.match?(~r/^"[^"\s]+"$/, trimmed) ->
        {:nerves, "firmware UUID #{String.trim(trimmed, ~s|"|)}"}

      true ->
        {:elixir, "Elixir runs; unexpected UUID response"}
    end
  end

  defp classify({:eval_error, _message}),
    do: {:elixir, "Elixir runs; Nerves.Runtime unavailable"}

  defp classify(:noise), do: {:shell, "serial responded but did not run Elixir"}
  defp classify(:down), do: {:down, "no response from device"}
  defp classify(:busy), do: {:busy, "device busy (evaluation in flight or console in use)"}
  defp classify({:error, reason}), do: {:unknown, "probe error: #{inspect(reason)}"}

  # Don't overwrite a known mode just because the device was momentarily busy.
  defp apply_result(state, {:busy, _detail}), do: state

  defp apply_result(state, {mode, detail}) do
    if mode != state.mode do
      Logger.info("DeviceProbe: #{state.mode} -> #{mode} (#{detail})")
      broadcast_tools_changed()
    end

    %{state | mode: mode, detail: detail}
  end

  defp broadcast_tools_changed() do
    StreamableHTTP.broadcast(SessionStore.ETS, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp schedule_tick(), do: Process.send_after(self(), :tick, @tick)

  defp mono(), do: System.monotonic_time(:millisecond)
end
