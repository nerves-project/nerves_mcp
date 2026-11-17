# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.UART do
  @moduledoc false

  # A serial console, through `Circuits.UART`.

  @behaviour NervesMCP.Connection.Transport

  @default_speed 115_200

  @impl NervesMCP.Connection.Transport
  def open(config) do
    port = Keyword.fetch!(config, :port)
    speed = Keyword.get(config, :speed, @default_speed)

    with {:ok, uart} <- Circuits.UART.start_link() do
      case Circuits.UART.open(uart, port, speed: speed, active: true) do
        :ok ->
          {:ok, uart}

        {:error, reason} ->
          close(uart)
          {:error, reason}
      end
    end
  end

  @impl NervesMCP.Connection.Transport
  def write(uart, data), do: Circuits.UART.write(uart, data)

  @impl NervesMCP.Connection.Transport
  def close(uart) do
    Circuits.UART.stop(uart)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl NervesMCP.Connection.Transport
  def handle_message(_uart, {:circuits_uart, _port, {:error, reason}}), do: {:closed, reason}
  def handle_message(_uart, {:circuits_uart, _port, data}) when is_binary(data), do: {:data, data}
  def handle_message(uart, {:EXIT, uart, reason}), do: {:closed, reason}
  def handle_message(_uart, _message), do: :ignore

  @impl NervesMCP.Connection.Transport
  def frame(text), do: "\n" <> text <> "\r"
end
