# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.ShellEval do
  @moduledoc false

  @behaviour EMCP.Tool

  alias NervesMCP.Connection
  alias NervesMCP.Tools

  @impl EMCP.Tool
  def name(), do: "shell_eval"

  @impl EMCP.Tool
  def description(),
    do:
      "Run a shell command on the connected device and return its output (offered when the device is not running Elixir)"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        command: %{type: :string, description: "Shell command to run on the device"},
        timeout: %{type: :integer, description: "Timeout in milliseconds (default: 15000)"}
      },
      required: [:command]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    id = NervesMCP.Instance.current()
    Tools.respond(Connection.shell_eval(id, args["command"], args["timeout"] || 15_000))
  end
end
