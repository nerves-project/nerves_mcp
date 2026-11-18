# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.Protocol do
  @moduledoc false

  # What is written to the device for each kind of request, and how the answer
  # is picked out of everything the device sends back.

  @type style() :: :elixir | :shell
  @type frame() :: (String.t() -> String.t())

  @inspect_opts "pretty: true, limit: :infinity, printable_limit: :infinity"

  @spec marker() :: String.t()
  def marker(), do: Base.encode16(:crypto.strong_rand_bytes(8))

  @spec firmware_uuid_code() :: String.t()
  def firmware_uuid_code(), do: ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|

  @doc """
  Elixir that evaluates `code` and prints the inspected value between markers.

  The closing marker is `_END` when the code returned and `_FAIL` when it
  raised, threw or exited.
  """
  @spec eval(String.t(), String.t()) :: String.t()
  def eval(code, marker) do
    """
    (fn ->
      {status, text} = try do
        {value, _binding} = Code.eval_string(#{literal(code)})
        {"END", inspect(value, #{@inspect_opts})}
      rescue
        e -> {"FAIL", Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {"FAIL", Exception.format(kind, reason, __STACKTRACE__)}
      end
      IO.puts("#{marker}_START")
      IO.puts(text)
      IO.puts("#{marker}_" <> status)
      :ok
    end).()

    """
  end

  @doc "Like `eval/2`, with whatever the code printed in front of the result."
  @spec eval_output(String.t(), String.t()) :: String.t()
  def eval_output(code, marker) do
    """
    (fn ->
      {:ok, capture_pid} = StringIO.open("")
      old_gl = Process.group_leader()
      Process.group_leader(self(), capture_pid)

      {status, text} = try do
        {value, _binding} = Code.eval_string(#{literal(code)})
        {"END", inspect(value, #{@inspect_opts})}
      rescue
        e -> {"FAIL", "ERROR: " <> Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {"FAIL", "ERROR: " <> Exception.format(kind, reason, __STACKTRACE__)}
      end

      Process.group_leader(self(), old_gl)
      {:ok, {_input, output}} = StringIO.close(capture_pid)

      IO.puts("#{marker}_START")
      IO.puts("OUTPUT:")
      IO.write(output)
      IO.puts("RESULT:")
      IO.puts(text)
      IO.puts("#{marker}_" <> status)
      :ok
    end).()

    """
  end

  # One command, so the shell prints no prompt or echo between the markers.
  # The quotes keep the marker itself out of what the terminal echoes back.
  # A bare `eval` that cannot parse its command makes ash and dash drop the
  # rest of the line, end marker included. `command eval` carries on, and
  # unlike a subshell it keeps the working directory and variables.
  @spec shell(String.t(), String.t()) :: String.t()
  def shell(command, marker) do
    "echo '#{marker}''_START'; command eval #{shell_quote(command)}; echo '#{marker}''_END'\n"
  end

  @spec shell_output(String.t(), String.t()) :: String.t()
  def shell_output(command, marker) do
    "echo '#{marker}''_START'; echo 'OUTPUT:'; command eval #{shell_quote(command)} 2>&1; " <>
      "__mcp_rc=$?; echo 'RESULT:'; echo \"Exit code: $__mcp_rc\"; echo '#{marker}''_END'\n"
  end

  defp shell_quote(command), do: "'" <> String.replace(command, "'", "'\\''") <> "'"

  @doc """
  Looks for a finished answer in what has arrived so far.

  `frame` turns a marker into the bytes of that marker printed on a line of its
  own, which is how Elixir answers are told apart from the echoed source.
  Returns the text still worth keeping when the answer is not complete.
  """
  @spec extract(String.t(), String.t(), style(), frame()) ::
          {:done, :ok | :error, String.t()} | {:cont, String.t()}
  def extract(acc, marker, :elixir, frame) do
    acc = after_start(acc, frame.(marker <> "_START"))

    case {before(acc, frame.(marker <> "_END")), before(acc, frame.(marker <> "_FAIL"))} do
      {nil, nil} -> {:cont, acc}
      {text, nil} -> {:done, :ok, clean(text)}
      {nil, text} -> {:done, :error, clean(text)}
      {ok, fail} when byte_size(ok) <= byte_size(fail) -> {:done, :ok, clean(ok)}
      {_ok, fail} -> {:done, :error, clean(fail)}
    end
  end

  def extract(acc, marker, :shell, _frame) do
    acc = after_start(acc, marker <> "_START")

    case before(acc, marker <> "_END") do
      nil -> {:cont, acc}
      text -> {:done, :ok, clean(text)}
    end
  end

  defp after_start(acc, start) do
    case String.split(acc, start, parts: 2) do
      [_before, rest] -> rest
      [_all] -> acc
    end
  end

  defp before(acc, ending) do
    case String.split(acc, ending, parts: 2) do
      [text, _rest] -> text
      [_all] -> nil
    end
  end

  defp clean(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  defp literal(code), do: inspect(code, limit: :infinity, printable_limit: :infinity)
end
