# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.GrepDmesg do
  @moduledoc false

  @behaviour EMCP.Tool

  @impl EMCP.Tool
  def name(), do: "grep_dmesg"

  @impl EMCP.Tool
  def description(),
    do: "Filter the connected Nerves device's `dmesg` output by a substring or regex pattern"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        pattern: %{
          type: :string,
          description: "Substring (or regex if `regex` is true) to match dmesg lines against"
        },
        regex: %{
          type: :boolean,
          description: "Treat pattern as an Elixir regex (default: false)"
        },
        tail: %{
          type: :integer,
          description: "Return only the last N matching lines"
        },
        timeout: %{
          type: :integer,
          description: "Timeout in milliseconds (default: 15000)"
        }
      },
      required: [:pattern]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    pattern = args["pattern"]
    regex? = args["regex"] || false
    tail = args["tail"]
    timeout = args["timeout"] || 15_000

    code = build_code(pattern, regex?, tail)

    NervesMCP.Instance.current()
    |> NervesMCP.Connection.eval_output(code, timeout)
    |> NervesMCP.Tools.respond()
  end

  defp build_code(pattern, regex?, tail) do
    tail_literal = if is_integer(tail), do: Integer.to_string(tail), else: "nil"

    """
    (fn ->
      pattern = #{inspect(pattern)}
      regex? = #{regex?}
      tail = #{tail_literal}

      matcher =
        if regex? do
          re = Regex.compile!(pattern)
          fn line -> Regex.match?(re, line) end
        else
          fn line -> String.contains?(line, pattern) end
        end

      output =
        try do
          :os.cmd(~c"dmesg") |> to_string()
        rescue
          e -> {:error, Exception.message(e)}
        end

      case output do
        {:error, msg} ->
          IO.puts("Error running dmesg: " <> msg)

        binary when is_binary(binary) ->
          lines =
            binary
            |> String.split("\n", trim: true)
            |> Enum.filter(matcher)

          lines = if tail, do: Enum.take(lines, -tail), else: lines
          Enum.each(lines, &IO.puts/1)
          length(lines)
      end
    end).()
    """
  end
end
