# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Connection.WorkerTest do
  use ExUnit.Case, async: true

  alias NervesMCP.Connection

  @moduletag capture_log: true

  setup context do
    id = {__MODULE__, context.test}
    start_supervised!({NervesMCP.History, id: id})

    worker =
      start_supervised!(
        {Connection.Worker,
         id: id, type: :uart, transport: NervesMCP.FakeTransport, config: [test: self()]}
      )

    assert_receive {:opened, ^worker}
    %{id: id, worker: worker}
  end

  defp request(fun), do: Task.async(fun)

  defp sent_marker() do
    assert_receive {:written, payload}
    [_all, marker] = Regex.run(~r/([0-9A-F]{16})_START/, payload)
    marker
  end

  defp answer(worker, marker, text, ending \\ "END") do
    send(worker, {:device, "#{marker}_START\n#{text}\n#{marker}_#{ending}\n"})
  end

  test "answers a request with what the device printed", %{id: id, worker: worker} do
    task = request(fn -> Connection.eval(id, "1 + 1") end)
    answer(worker, sent_marker(), "2")

    assert Task.await(task) == {:ok, "2"}
  end

  test "reports failed evaluation as an error", %{id: id, worker: worker} do
    task = request(fn -> Connection.eval(id, "raise :boom") end)
    answer(worker, sent_marker(), "** (ArgumentError) boom", "FAIL")

    assert Task.await(task) == {:error, "** (ArgumentError) boom"}
  end

  test "puts an answer together from pieces", %{id: id, worker: worker} do
    task = request(fn -> Connection.eval(id, "1 + 1") end)
    marker = sent_marker()

    for piece <- ["#{marker}_ST", "ART\n4", "2\n#{marker}_E", "ND\n"] do
      send(worker, {:device, piece})
    end

    assert Task.await(task) == {:ok, "42"}
  end

  test "hands device output to every output function, even after one fails", %{id: id} do
    test = self()
    id = {id, :outputs}
    start_supervised!({NervesMCP.History, id: id}, id: :outputs_history)

    worker =
      start_supervised!(
        {Connection.Worker,
         id: id,
         type: :uart,
         transport: NervesMCP.FakeTransport,
         config: [test: test],
         outputs: [fn _data -> raise "boom" end, &send(test, {:output, &1})]},
        id: :outputs_worker
      )

    assert_receive {:opened, ^worker}

    send(worker, {:device, "booting"})
    assert_receive {:output, "booting"}

    task = request(fn -> Connection.eval(id, "1 + 1") end)
    answer(worker, sent_marker(), "2")
    assert Task.await(task) == {:ok, "2"}
    assert_receive {:output, answered}
    assert answered =~ "_START\n2\n"
  end

  test "runs requests one at a time, in order", %{id: id, worker: worker} do
    first = request(fn -> Connection.eval(id, ":first") end)
    first_marker = sent_marker()

    second = request(fn -> Connection.eval(id, ":second") end)
    refute_receive {:written, _payload}, 50

    answer(worker, first_marker, ":first")
    answer(worker, sent_marker(), ":second")

    assert Task.await(first) == {:ok, ":first"}
    assert Task.await(second) == {:ok, ":second"}
  end

  test "times out a request and carries on with the next", %{id: id, worker: worker} do
    assert {:error, "Timeout" <> _} = Connection.eval(id, "slow", 10)
    _stale = sent_marker()

    task = request(fn -> Connection.eval(id, ":next") end)
    answer(worker, sent_marker(), ":next")

    assert Task.await(task) == {:ok, ":next"}
  end

  test "ignores a late answer to a request that timed out", %{id: id, worker: worker} do
    assert {:error, "Timeout" <> _} = Connection.eval(id, "slow", 10)
    stale = sent_marker()

    task = request(fn -> Connection.eval(id, ":next") end)
    marker = sent_marker()
    answer(worker, stale, ":late")
    answer(worker, marker, ":next")

    assert Task.await(task) == {:ok, ":next"}
  end

  test "answers everything waiting when the link is lost, then reopens", context do
    %{id: id, worker: worker} = context
    first = request(fn -> Connection.eval(id, ":first") end)
    _marker = sent_marker()
    second = request(fn -> Connection.eval(id, ":second") end)
    _ = :sys.get_state(worker)

    send(worker, {:device_lost, :unplugged})

    assert {:error, "Device connection lost" <> _} = Task.await(first)
    assert {:error, "Device connection lost" <> _} = Task.await(second)
    assert_receive :closed
    assert {:error, "Device not connected" <> _} = Connection.eval(id, "1")

    send(worker, :reconnect)
    assert_receive {:opened, ^worker}
  end

  test "probe tells an answering device from a silent or noisy one", %{id: id, worker: worker} do
    task = request(fn -> Connection.probe(id) end)
    answer(worker, sent_marker(), ~s|"uuid-1"|)
    assert Task.await(task) == {:ok, ~s|"uuid-1"|}

    task = request(fn -> Connection.probe(id) end)
    answer(worker, sent_marker(), "** (UndefinedFunctionError)", "FAIL")
    assert Task.await(task) == {:eval_error, "** (UndefinedFunctionError)"}

    assert Connection.probe(id, 10) == :down
    _marker = sent_marker()

    task = request(fn -> Connection.probe(id, 50) end)
    _marker = sent_marker()
    send(worker, {:device, "login: "})
    assert Task.await(task) == :noise
  end

  test "probe stays out of the way of a request in flight", %{id: id, worker: worker} do
    task = request(fn -> Connection.eval(id, "1 + 1") end)
    marker = sent_marker()

    assert Connection.probe(id) == :busy

    answer(worker, marker, "2")
    assert Task.await(task) == {:ok, "2"}
  end

  test "probe stays out of a line being typed at the console", %{id: id, worker: worker} do
    Connection.send_raw(id, "IO.puts(")
    assert_receive {:written, "IO.puts("}
    assert Connection.probe(id) == :busy

    Connection.send_raw(id, "1)\r")
    assert_receive {:written, "1)\r"}
    assert Connection.probe(id) == :busy

    :ok = Connection.attach_console(id)
    :ok = Connection.detach_console(id)
    task = request(fn -> Connection.probe(id) end)
    answer(worker, sent_marker(), ~s|"uuid-1"|)
    assert Task.await(task) == {:ok, ~s|"uuid-1"|}
  end

  test "firmware_uuid/2 only accepts a UUID", %{id: id, worker: worker} do
    task = request(fn -> Connection.firmware_uuid(id) end)
    answer(worker, sent_marker(), ~s|"1234-abcd"|)
    assert Task.await(task) == {:ok, "1234-abcd"}

    task = request(fn -> Connection.firmware_uuid(id) end)
    answer(worker, sent_marker(), "nil")
    assert {:error, "device has no firmware UUID" <> _} = Task.await(task)
  end

  test "passes device output on to an attached console", %{id: id, worker: worker} do
    :ok = Connection.attach_console(id)
    send(worker, {:device, "hello"})
    assert_receive {:console_data, "hello"}

    :ok = Connection.detach_console(id)
    send(worker, {:device, "again"})
    refute_receive {:console_data, _data}, 50
    assert NervesMCP.History.get(id) == "helloagain"
  end

  test "keeps a request and what trails it off the console", %{id: id, worker: worker} do
    :ok = Connection.attach_console(id)
    task = request(fn -> Connection.eval(id, "1 + 1") end)
    answer(worker, sent_marker(), "2")
    assert Task.await(task) == {:ok, "2"}

    send(worker, {:device, ":ok\niex(2)> "})
    refute_receive {:console_data, _data}, 50

    Process.send_after(worker, {:device, "later"}, 200)
    assert_receive {:console_data, "later"}, 1_000
  end
end
