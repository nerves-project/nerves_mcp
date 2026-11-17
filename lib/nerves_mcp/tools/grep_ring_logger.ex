# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.GrepRingLogger do
  @moduledoc false

  @behaviour EMCP.Tool

  @impl EMCP.Tool
  def name(), do: "grep_ring_logger"

  @impl EMCP.Tool
  def description(),
    do: "Filter the connected Nerves device's RingLogger buffer by a substring or regex pattern"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        pattern: %{
          type: :string,
          description: "Substring (or regex if `regex` is true) to match log lines against"
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

      format = fn level, msg ->
        text =
          try do
            IO.iodata_to_binary(msg)
          rescue
            _ -> inspect(msg)
          end

        "[" <> to_string(level) <> "] " <> text
      end

      entries =
        try do
          RingLogger.get(0)
        rescue
          UndefinedFunctionError -> {:error, :ring_logger_unavailable}
          e -> {:error, Exception.message(e)}
        end

      case entries do
        {:error, :ring_logger_unavailable} ->
          IO.puts("RingLogger is not available on this device")

        {:error, msg} ->
          IO.puts("Error fetching RingLogger entries: " <> msg)

        list when is_list(list) ->
          lines =
            list
            |> Enum.map(fn
              %{level: level, message: msg} -> format.(level, msg)
              {level, {_logger, msg, _ts, _meta}} -> format.(level, msg)
              other -> inspect(other)
            end)
            |> Enum.filter(matcher)

          lines = if tail, do: Enum.take(lines, -tail), else: lines
          Enum.each(lines, &IO.puts/1)
          length(lines)
      end
    end).()
    """
  end
end
