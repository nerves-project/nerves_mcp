# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

import Config

# MCP server port (CLI --port overrides this)
# config :nerves_mcp, :port, 13000

# Address to listen on (CLI --ip overrides this). Loopback only by default.
# config :nerves_mcp, :ip, :any

# Append everything the device prints to a file (CLI --log-file overrides this)
# config :nerves_mcp, :log_file, "nerves_mcp.log"

# UART connection (CLI args override these)
# config :nerves_mcp, :connection,
#   type: :uart,
#   port: "/dev/ttyUSB0",
#   speed: 115_200

# SSH connection (CLI args override these)
# config :nerves_mcp, :connection,
#   type: :ssh,
#   host: "nerves.local",
#   user: "root",
#   port: 22

config :bun, :version, "1.4.4"
