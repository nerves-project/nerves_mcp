# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.History do
  @moduledoc false

  # Recent device output in a circular buffer, one per server.

  use Agent

  alias NervesMCP.Instance

  @default_size 10_000

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    id = Keyword.get(opts, :id, :default)
    size = Keyword.get(opts, :size, @default_size)
    Agent.start_link(fn -> CircularBuffer.new(size) end, name: Instance.via(id, :history))
  end

  @spec push(term(), binary()) :: :ok
  def push(id, data) when is_binary(data) do
    Agent.update(Instance.via(id, :history), fn buffer ->
      CircularBuffer.insert(buffer, {System.monotonic_time(), data})
    end)
  end

  @spec get(term()) :: binary()
  def get(id) do
    Agent.get(Instance.via(id, :history), fn buffer ->
      buffer
      |> CircularBuffer.to_list()
      |> Enum.map_join(fn {_ts, data} -> data end)
    end)
  end

  @spec clear(term()) :: :ok
  def clear(id) do
    Agent.update(Instance.via(id, :history), fn buffer ->
      CircularBuffer.new(buffer.max_size)
    end)
  end
end
