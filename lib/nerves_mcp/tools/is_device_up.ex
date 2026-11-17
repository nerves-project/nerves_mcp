# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.IsDeviceUp do
  @moduledoc false

  @behaviour EMCP.Tool

  alias NervesMCP.Connection

  @impl EMCP.Tool
  def name(), do: "is_device_up"

  @impl EMCP.Tool
  def description(),
    do:
      "Wait for the connected Nerves device to be up and answering, and report its firmware UUID"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        timeout: %{
          type: :integer,
          description: "Total timeout in milliseconds to keep retrying (default: 60000)"
        }
      },
      required: []
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    id = NervesMCP.Instance.current()

    case Connection.await_firmware_uuid(id, args["timeout"] || 60_000) do
      {:ok, uuid} -> NervesMCP.Tools.respond({:ok, "Device is up. Firmware UUID: #{uuid}"})
      {:error, reason} -> EMCP.Tool.error(reason)
    end
  end
end
