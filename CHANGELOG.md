# Changelog

## v0.1.0

Initial version.

Includes support for starting an MCP server against a Nerves device over either
SSH or a serial console. It will expose a variety of tools. Primarily running
code on the device and watching for a device returning from an update.

The library can be used both via a mix task or as a library for tools that want
to start a Nerves MCP server.
