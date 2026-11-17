# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.ProtocolTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias NervesMCP.Connection.Protocol

  @marker "MARK"

  defp frame(text), do: text <> "\n"

  # Runs what would be sent to the device here, and reads the answer back.
  defp run_elixir(payload) do
    printed = capture_io(fn -> Code.eval_string(payload) end)
    Protocol.extract(payload <> printed, @marker, :elixir, &frame/1)
  end

  defp run_shell(payload) do
    {printed, 0} = System.cmd("sh", ["-c", payload])
    Protocol.extract(payload <> printed, @marker, :shell, &frame/1)
  end

  describe "eval/2" do
    test "gives the inspected value" do
      assert run_elixir(Protocol.eval("1 + 1", @marker)) == {:done, :ok, "2"}
    end

    test "reports code that raises as an error" do
      assert {:done, :error, "** (RuntimeError) boom" <> _} =
               run_elixir(Protocol.eval(~s|raise "boom"|, @marker))
    end

    test "reports code that throws as an error" do
      assert {:done, :error, "** (throw) :ball" <> _} =
               run_elixir(Protocol.eval("throw(:ball)", @marker))
    end

    test "carries long code and long values whole" do
      text = String.duplicate("a", 10_000)

      assert run_elixir(Protocol.eval(inspect(text, printable_limit: :infinity), @marker)) ==
               {:done, :ok, inspect(text, printable_limit: :infinity)}
    end
  end

  describe "eval_output/2" do
    test "gives what was printed and the value" do
      assert run_elixir(Protocol.eval_output(~s|IO.puts("hi"); :done|, @marker)) ==
               {:done, :ok, "OUTPUT:\nhi\nRESULT:\n:done"}
    end

    test "keeps what was printed before a failure" do
      assert {:done, :error, "OUTPUT:\nhi\nRESULT:\nERROR: ** (RuntimeError) boom" <> _} =
               run_elixir(Protocol.eval_output(~s|IO.puts("hi"); raise "boom"|, @marker))
    end
  end

  describe "shell commands" do
    test "give their output" do
      assert run_shell(Protocol.shell("echo hi", @marker)) == {:done, :ok, "hi"}
    end

    test "give their output and exit code" do
      assert run_shell(Protocol.shell_output("echo hi; false", @marker)) ==
               {:done, :ok, "OUTPUT:\nhi\nRESULT:\nExit code: 1"}
    end
  end

  describe "extract/4" do
    test "waits for the closing marker" do
      assert Protocol.extract("noise MARK_START\npart", @marker, :elixir, &frame/1) ==
               {:cont, "part"}
    end

    test "is not fooled by the echoed source" do
      echoed = ~s|IO.puts("MARK_START")\nIO.puts("MARK_" <> status)\n|
      assert Protocol.extract(echoed, @marker, :elixir, &frame/1) == {:cont, echoed}
    end

    test "turns terminal line endings into plain ones" do
      assert Protocol.extract(
               "MARK_START\r\na\r\nb\r\nMARK_END\r\n",
               @marker,
               :elixir,
               &(&1 <> "\r\n")
             ) ==
               {:done, :ok, "a\nb"}
    end
  end
end
