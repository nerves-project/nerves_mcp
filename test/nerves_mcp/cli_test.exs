# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.CLITest do
  use ExUnit.Case, async: true

  alias NervesMCP.CLI

  @config [connection: [], port: 13_000, ip: :loopback]

  defp parse(args, config \\ @config), do: CLI.parse(String.split(args), config)

  test "a serial device path means a serial connection" do
    assert {:ok, settings} = parse("/dev/ttyUSB0 --speed 9600")
    assert Enum.sort(settings[:connection]) == [port: "/dev/ttyUSB0", speed: 9600, type: :uart]
    assert settings[:port] == 13_000
    assert settings[:ip] == :loopback
  end

  test "any absolute path means a serial connection" do
    assert {:ok, settings} = parse("/tmp/pty-device")
    assert settings[:connection][:type] == :uart
    assert settings[:connection][:port] == "/tmp/pty-device"
  end

  test "anything else means an SSH host" do
    assert {:ok, settings} = parse("nerves.local --user me --ssh-port 2222 --port 4000")

    assert Enum.sort(settings[:connection]) ==
             [host: "nerves.local", port: 2222, type: :ssh, user: "me"]

    assert settings[:port] == 4000
  end

  test "the transport can be forced" do
    assert {:ok, settings} = parse("--serial nerves.local")
    assert settings[:connection][:type] == :uart

    assert {:ok, settings} = parse("--ssh /dev/ttyUSB0")
    assert settings[:connection][:type] == :ssh
  end

  test "SSH options leave a serial connection alone" do
    assert {:ok, settings} = parse("/dev/ttyUSB0 --ssh-port 2222 --user me")

    assert Enum.sort(settings[:connection]) ==
             [port: "/dev/ttyUSB0", speed: 115_200, type: :uart]
  end

  test "arguments override the configured connection" do
    config = Keyword.put(@config, :connection, type: :ssh, host: "a.local", user: "me")

    assert {:ok, settings} = parse("", config)
    assert settings[:connection][:host] == "a.local"

    assert {:ok, settings} = parse("b.local", config)
    assert Enum.sort(settings[:connection]) == [host: "b.local", type: :ssh, user: "me"]
  end

  test "the listen address can be widened" do
    assert {:ok, settings} = parse("nerves.local --ip any")
    assert settings[:ip] == :any

    assert {:ok, settings} = parse("nerves.local --ip 192.168.1.5")
    assert settings[:ip] == {192, 168, 1, 5}

    assert {:error, "Not an IP address" <> _} = parse("nerves.local --ip nope")
  end

  test "device output is only logged to a file when asked" do
    assert {:ok, settings} = parse("nerves.local")
    assert settings[:log_file] == nil

    assert {:ok, settings} = parse("nerves.local", Keyword.put(@config, :log_file, "a.log"))
    assert settings[:log_file] == "a.log"

    assert {:ok, settings} = parse("nerves.local --log-file b.log")
    assert settings[:log_file] == "b.log"
  end

  test "unknown options are refused" do
    assert {:error, "Unknown or malformed option: --sped" <> _} = parse("nerves.local --sped 1")
    assert {:error, "Unknown or malformed option: --port" <> _} = parse("nerves.local --port x")
  end

  test "nothing to connect to gives the usage" do
    assert {:error, "Usage:" <> _} = parse("")
  end
end
