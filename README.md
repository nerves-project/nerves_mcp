<!--
  SPDX-FileCopyrightText: 2026 Lars Wikman
  SPDX-License-Identifier: CC-BY-4.0
-->

# NervesMCP

[![Hex version](https://img.shields.io/hexpm/v/nerves_mcp.svg "Hex version")](https://hex.pm/packages/nerves_mcp)
[![API docs](https://img.shields.io/hexpm/v/nerves_mcp.svg?label=hexdocs "API docs")](https://nerves-mcp.hexdocs.pm/NervesMCP.html)
[![Nerves compatibility](https://compatibility.nerves-project.org/badge/nerves_mcp.svg)](https://compatibility.nerves-project.org/packages/nerves_mcp)
[![CI](https://github.com/nerves-project/nerves_mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/nerves-project/nerves_mcp/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/nerves-project/nerves_mcp)](https://api.reuse.software/info/github.com/nerves-project/nerves_mcp)

An MCP (Model Context Protocol) server for interacting with Nerves devices. Enables AI assistants to evaluate Elixir code on embedded devices connected via UART or SSH.

## Installation

Add to your dependencies:

```elixir
def deps do
  [
    # For library use, such as in tooling remove runtime: false
    {:nerves_mcp, "~> 0.1", only: :dev, targets: :host, runtime: false}
  ]
end
```

## Usage

NervesMCP is run as a Mix task. The first argument is either a serial device path or an SSH host. NervesMCP auto-detects which based on the path.

### Mix task

```bash
# Serial, auto-detected from leading /
mix nerves_mcp /dev/ttyUSB0
mix nerves_mcp /dev/ttyUSB0 --speed 9600

# SSH, anything that isn't a serial path is treated as a hostname
mix nerves_mcp nerves.local
mix nerves_mcp nerves.local --user root --ssh-port 2222
```

### Use as a library

An application can run one MCP server per device, each on its own port, without any `:nerves_mcp` configuration:

```elixir
{:ok, server} =
  NervesMCP.start_server("nerves-1234.local",
    connection: [type: :ssh, host: "nerves-1234.local", user: "root"]
  )

server.url
#=> "http://localhost:13000/mcp"

NervesMCP.servers()
NervesMCP.stop_server("nerves-1234.local")
```

The first argument is an id of your choosing. Ports are handed out from 13000 upwards, skipping any that are taken. To keep a device on the port it had last time, remember `server.port` and put it first:

```elixir
NervesMCP.start_server(id, connection: connection, port: [saved_port | Enum.to_list(13000..13099)])
```

To collect what goes on with a device, pass a function as `:on_output`. It is called with everything the device prints, including what the MCP tools cause, in pieces as they arrive:

```elixir
NervesMCP.start_server(id,
  connection: connection,
  on_output: fn data -> MyApp.DeviceLog.append(id, data) end
)
```

The function runs in the connection process, so keep it quick. `:log_file` takes a path and appends the same output to that file.

`NervesMCP.Connection` evaluates code on a running server's device directly, e.g. `NervesMCP.Connection.eval(id, "1 + 1")`.

### Options

| Flag           | Description                        | Default   |
|----------------|------------------------------------|-----------|
| `--port`       | MCP server HTTP port               | `13000`   |
| `--ip`         | Address to listen on, or `any`     | loopback  |
| `--speed`      | Serial baud rate                   | `115200`  |
| `--user`       | SSH username                       | `root`    |
| `--ssh-port`   | SSH port                           | `22`      |
| `--pass`       | SSH password (needs `sshpass`)     |           |
| `--log-file`   | Append device output to this file  | not kept  |
| `--serial`     | Force serial mode (pass device)    |           |
| `--ssh`        | Force SSH mode (pass host)         |           |

Short aliases: `-p` (port), `-s` (speed), `-u` (user).

### Configuration file

Connection settings can also be defined in `config/config.exs`. CLI arguments override config values.

```elixir
# Serial
config :nerves_mcp, :port, 13000
config :nerves_mcp, :connection,
  type: :uart,
  port: "/dev/ttyUSB0",
  speed: 115_200

# Or SSH
config :nerves_mcp, :connection,
  type: :ssh,
  host: "nerves.local",
  user: "root",
  port: 22
```

Device output is not written to disk unless you ask for it, with `--log-file` or in config. The file holds everything that passed over the console, which can include secrets.

```elixir
config :nerves_mcp, :log_file, "nerves_mcp.log"
```

With config in place, you can start without any arguments:

```bash
mix nerves_mcp
```

Or override specific values:

```bash
mix nerves_mcp --speed 9600    # use config but change baud rate
mix nerves_mcp other.local     # switch to a different host entirely
```

### Auto-detection

If the first argument starts with `/` for typically `/dev/tty`, `/dev/cu.`, or `/dev/serial`, it is treated as a serial device. Otherwise it is treated as an SSH host. Use `--serial` or `--ssh` to be explicit:

```bash
mix nerves_mcp --serial /dev/ttyACM0
mix nerves_mcp --ssh 192.168.1.100
```

### Connecting to the MCP server

Once running, the MCP server is available at:

```
http://localhost:13000/mcp
```

For Claude Code:

```bash
claude mcp add --transport http nerves http://localhost:13000/mcp
```

For Codex:

```bash
codex mcp add nerves --url http://localhost:13000/mcp
```

For OpenCode:

```bash
opencode mcp add nerves --url http://localhost:13000/mcp
```

### Security

Whoever can reach the MCP port can run code on the device, and there is no authentication. The server therefore only listens on the loopback interface unless you pass `--ip`, set `config :nerves_mcp, :ip`, or give `:ip` to `NervesMCP.start_server/2`. Only do that on a network you trust. Requests from web pages are refused unless the page is served from the same machine.

SSH connections do not check the device's host key, since some Nerves devices get a new one when reflashed.

This is intended as a development tool. If you deploy this you are deploying RCE as a service.

## MCP Tools

The tools on offer follow what is on the other end of the connection, which is probed while the server is idle. A Nerves device gets all of the Elixir tools, a device that runs Elixir without Nerves gets `device_eval` and `device_eval_output`, and a device that answers without running Elixir gets `device_shell_eval` and `device_shell_eval_output`. The status and waiting tools are always there. Requests to a device run one at a time, in the order they arrive.

### device_status

Reports what was detected on the other end and which tools that leads to. Pass `refresh` to probe again right away.

### is_device_up

Waits for the device to answer with a firmware UUID, for instance after a reboot.

### is_device_updated_to

Waits for the device to come up, then checks that it runs the firmware with the expected UUID.

### device_eval

Evaluates Elixir code on the device and returns the expression's return value.

### device_eval_output

Evaluates Elixir code and captures IO output (what the code prints via `IO.puts`, `IO.write`, etc.) in addition to the return value.

### grep_ring_logger

Filters the device's `RingLogger` buffer by a substring or regex pattern. Optional `tail` returns only the last N matches.

### grep_dmesg

Filters the device's `dmesg` (kernel ring buffer) by a substring or regex pattern. Optional `tail` returns only the last N matches.

### device_shell_eval

Runs a shell command and returns its output. Offered when the device answers but does not run Elixir.

### device_shell_eval_output

Runs a shell command and returns stdout, stderr and the exit code.

## Interactive Console & Serial proxying

From IEx or the mix task, you can open an interactive console to the device. This also means you can still use your serial console
while offering it to the LLM:

```elixir
iex> console()
Connected to device console. Commands: #quit, #history
---
```

This lets you interact directly with the device's IEx shell. Commands:

- `#quit` - Exit the console and return to local IEx
- `#history` - Display buffered output history

## Output History

Device output is stored in a circular buffer, even when no console is attached. This includes output from MCP tool calls.

```elixir
iex> history()
```

Or use `#history` while in the console.

## License

Apache-2.0
