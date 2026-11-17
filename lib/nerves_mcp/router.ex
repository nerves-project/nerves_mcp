defmodule NervesMCP.Router do
  @moduledoc false

  @behaviour Plug

  @logger Plug.Logger.init([])
  @transport [server: NervesMCP.Server]

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
