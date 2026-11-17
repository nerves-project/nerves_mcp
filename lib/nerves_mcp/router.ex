# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Router do
  @moduledoc false

  @behaviour Plug

  @logger Plug.Logger.init([])
  # Browsers send an Origin; only pages served from this machine may call in.
  @transport [
    server: NervesMCP.Server,
    validate_origin: true,
    allowed_origins: ["localhost", "127.0.0.1", "::1"]
  ]

  @impl Plug
  def init(id), do: id

  @impl Plug
  def call(conn, id) do
    conn = Plug.Logger.call(conn, @logger)

    case conn.path_info do
      ["mcp" | rest] ->
        NervesMCP.Instance.put_current(id)
        Plug.forward(conn, rest, EMCP.Transport.StreamableHTTP, @transport)

      _ ->
        Plug.Conn.send_resp(conn, 404, "not found")
    end
  end
end
