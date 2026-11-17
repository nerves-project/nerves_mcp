# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.DeviceStatus do
  @moduledoc false

  @behaviour EMCP.Tool

  @impl EMCP.Tool
  def name(), do: "device_status"

  @impl EMCP.Tool
  def description(),
    do:
      "Report the detected device state (nerves/elixir/shell/down) that decides which tools are offered"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        refresh: %{
          type: :boolean,
          description:
            "Probe the device now instead of using the last cached result (default: false)"
        }
      },
      required: []
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    id = NervesMCP.Instance.current()
    if args["refresh"], do: NervesMCP.DeviceProbe.refresh(id)

    status = NervesMCP.DeviceProbe.status(id)

    text = """
    Detected mode: #{status.mode}
    Detail: #{status.detail}
    Offered tools: #{offered(status.mode)}
    Idle: #{format_ms(status.idle_ms)}
    Last probe: #{last_probe(status.last_probe_ms_ago)}
    """

    EMCP.Tool.response([%{"type" => "text", "text" => String.trim_trailing(text)}])
  end

  defp offered(:nerves),
    do:
      "device_eval, device_eval_output, grep_ring_logger, grep_dmesg + is_device_up, is_device_updated_to, device_status"

  defp offered(:elixir),
    do: "device_eval, device_eval_output + is_device_up, is_device_updated_to, device_status"

  defp offered(:shell),
    do:
      "device_shell_eval, device_shell_eval_output + is_device_up, is_device_updated_to, device_status"

  defp offered(_), do: "is_device_up, is_device_updated_to, device_status"

  defp format_ms(nil), do: "unknown"
  defp format_ms(ms), do: "#{div(ms, 1000)}s"

  defp last_probe(nil), do: "never"
  defp last_probe(ms), do: "#{div(ms, 1000)}s ago"
end
