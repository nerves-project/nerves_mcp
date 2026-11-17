# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.DeviceEvalOutput do
  @moduledoc false

  @behaviour EMCP.Tool

  alias NervesMCP.Connection
  alias NervesMCP.Tools

  @impl EMCP.Tool
  def name(), do: "device_eval_output"

  @impl EMCP.Tool
  def description(),
    do:
      "Evaluate Elixir code on the connected Nerves device and return what it printed along with the result"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        code: %{type: :string, description: "Elixir code to evaluate on the device"},
        timeout: %{type: :integer, description: "Timeout in milliseconds (default: 15000)"}
      },
      required: [:code]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    id = NervesMCP.Instance.current()
    Tools.respond(Connection.eval_output(id, args["code"], args["timeout"] || 15_000))
  end
end
