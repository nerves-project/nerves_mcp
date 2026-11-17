# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCPTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag capture_log: true

  # Away from the default range so a real server on this machine can't interfere.
  @ports 23_400..23_409

  # A serial port that does not exist: the server runs and keeps retrying.
  defp connection(name), do: [type: :uart, port: "/dev/nerves-mcp-test-#{name}"]

  defp start(id, opts \\ []) do
    opts = Keyword.merge([connection: connection(id), port: @ports, ip: :loopback], opts)
    on_exit(fn -> NervesMCP.stop_server(id) end)
    NervesMCP.start_server(id, opts)
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"localhost", port, [], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end

  defp rpc(id, method, params) do
    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})

    conn(:post, "/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", "test")
    |> NervesMCP.Router.call(NervesMCP.Router.init(id))
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
  end

  describe "start_server/2" do
    test "hands out ports in order, one per server" do
      assert {:ok, %{id: "a", port: 23_400, url: "http://localhost:23400/mcp"}} = start("a")
      assert {:ok, %{id: "b", port: 23_401}} = start("b")

      assert listening?(23_400)
      assert listening?(23_401)
    end

    test "skips a port something else is listening on" do
      {:ok, socket} = :gen_tcp.listen(23_400, ip: :loopback)
      on_exit(fn -> :gen_tcp.close(socket) end)

      assert {:ok, %{port: 23_401}} = start("a")
    end

    test "prefers the first port it is given" do
      assert {:ok, %{port: 23_405}} = start("a", port: [23_405 | Enum.to_list(@ports)])
    end

    test "comes back on the same port after a restart" do
      {:ok, _other} = start("other")
      {:ok, %{port: port}} = start("a")

      assert NervesMCP.stop_server("a") == :ok
      refute listening?(port)

      assert {:ok, %{port: ^port}} = start("a", port: [port | Enum.to_list(@ports)])
    end

    test "refuses a second server with the same id" do
      {:ok, _server} = start("a")

      assert start("a") == {:error, :already_started}
    end

    test "reports when no port is free" do
      {:ok, _server} = start("a", port: 23_400)

      assert start("b", port: 23_400) == {:error, :no_free_port}
    end

    test "keeps the password out of the description" do
      connection = [type: :ssh, host: "127.0.0.1", port: 1, pass: "secret"]

      # The password option needs sshpass, which a test machine may not have.
      if System.find_executable("sshpass") do
        assert {:ok, server} = start("a", connection: connection)
        refute Keyword.has_key?(server.connection, :pass)
      end
    end
  end

  describe "running servers" do
    test "are listed and looked up by id" do
      {:ok, a} = start("a")
      {:ok, b} = start("b")

      assert NervesMCP.server("a") == a
      assert NervesMCP.server("missing") == nil
      assert Enum.sort_by(NervesMCP.servers(), & &1.id) == [a, b]
    end

    test "stopping one leaves the others running" do
      {:ok, a} = start("a")
      {:ok, b} = start("b")

      assert NervesMCP.stop_server("a") == :ok

      refute listening?(a.port)
      assert listening?(b.port)
      assert NervesMCP.servers() == [b]
      assert NervesMCP.stop_server("a") == {:error, :not_found}
    end

    test "each answers MCP requests for its own device" do
      {:ok, _a} = start("a")
      {:ok, _b} = start("b")

      assert %{"result" => %{"serverInfo" => %{"name" => "nerves-mcp"}}} =
               rpc("a", "initialize", %{
                 protocolVersion: "2025-03-26",
                 capabilities: %{},
                 clientInfo: %{name: "test", version: "1"}
               })

      assert %{"result" => %{"tools" => tools}} = rpc("b", "tools/list", %{})
      assert "device_status" in Enum.map(tools, & &1["name"])

      assert %{"result" => %{"content" => [%{"text" => text}]}} =
               rpc("b", "tools/call", %{name: "device_status", arguments: %{}})

      assert text =~ "Detected mode:"
    end

    test "keep their output history apart" do
      {:ok, _a} = start("a")
      {:ok, _b} = start("b")

      NervesMCP.History.push("a", "from a")

      assert NervesMCP.History.get("a") == "from a"
      assert NervesMCP.History.get("b") == ""
    end
  end

  describe "NervesMCP.Connection" do
    test "reports a server that is not running instead of crashing" do
      assert {:error, "Device connection not available" <> _} =
               NervesMCP.Connection.eval("missing", "1 + 1")

      assert NervesMCP.Connection.probe("missing") == :down
      assert NervesMCP.Connection.type("missing") == nil
    end

    test "reports a device that is not connected" do
      {:ok, _a} = start("a")

      assert NervesMCP.Connection.type("a") == :uart
      assert {:error, "Device not connected" <> _} = NervesMCP.Connection.eval("a", "1 + 1")
    end
  end
end
