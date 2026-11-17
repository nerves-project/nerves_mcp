# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.Tools.IsDeviceUpdatedTo do
  @moduledoc false

  @behaviour EMCP.Tool

  alias NervesMCP.Connection

  @impl EMCP.Tool
  def name(), do: "is_device_updated_to"

  @impl EMCP.Tool
  def description(),
    do:
      "Wait for the connected Nerves device to come up and check that it runs the firmware with the expected UUID"

  @impl EMCP.Tool
  def input_schema() do
    %{
      type: :object,
      properties: %{
        expected_uuid: %{
          type: :string,
          description: "The firmware UUID expected after the update"
        },
        timeout: %{
          type: :integer,
          description: "Total timeout in milliseconds to keep retrying (default: 60000)"
        }
      },
      required: [:expected_uuid]
    }
  end

  @impl EMCP.Tool
  def call(_conn, args) do
    id = NervesMCP.Instance.current()
    expected = args["expected_uuid"]

    case Connection.await_firmware_uuid(id, args["timeout"] || 60_000) do
      {:ok, ^expected} ->
        NervesMCP.Tools.respond({:ok, "Device is up and running firmware UUID #{expected}"})

      {:ok, actual} ->
        EMCP.Tool.error(
          "Device came up with firmware UUID #{actual}, expected #{expected}. The firmware may have reverted."
        )

      {:error, reason} ->
        EMCP.Tool.error(reason)
    end
  end
end
