# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.FakeTransport do
  @moduledoc false

  # A device link that reports to the test process named in the config.

  @behaviour NervesMCP.Connection.Transport

  @impl NervesMCP.Connection.Transport
  def open(config) do
    test = Keyword.fetch!(config, :test)
    send(test, {:opened, self()})
    {:ok, test}
  end

  @impl NervesMCP.Connection.Transport
  def write(test, data) do
    send(test, {:written, IO.iodata_to_binary(data)})
    :ok
  end

  @impl NervesMCP.Connection.Transport
  def close(test) do
    send(test, :closed)
    :ok
  end

  @impl NervesMCP.Connection.Transport
  def handle_message(_test, {:device, data}), do: {:data, data}
  def handle_message(_test, {:device_lost, reason}), do: {:closed, reason}
  def handle_message(_test, _message), do: :ignore

  @impl NervesMCP.Connection.Transport
  def frame(text), do: text <> "\n"
end
