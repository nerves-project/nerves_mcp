# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools do
  @moduledoc false

  @doc "Turns a connection result into a tool response."
  @spec respond(NervesMCP.Connection.result()) :: map()
  def respond({:ok, text}), do: EMCP.Tool.response([%{"type" => "text", "text" => text}])
  def respond({:error, reason}), do: EMCP.Tool.error(reason)
end
