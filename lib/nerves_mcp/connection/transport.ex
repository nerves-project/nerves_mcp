# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.Transport do
  @moduledoc false

  # A way of carrying bytes to and from a device. The process that calls
  # `open/1` owns the link and receives its messages.

  @type handle() :: term()

  @callback open(config :: keyword()) :: {:ok, handle()} | {:error, term()}
  @callback write(handle(), iodata()) :: :ok | {:error, term()}
  @callback close(handle()) :: :ok

  @doc "Sorts a message the owner received into device output, a lost link, or neither."
  @callback handle_message(handle(), message :: term()) ::
              {:data, binary()} | {:closed, term()} | :ignore

  @doc "The bytes of `text` as the device prints it on a line of its own."
  @callback frame(text :: String.t()) :: String.t()
end
