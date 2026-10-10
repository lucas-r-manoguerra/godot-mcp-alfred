# godot-mcp-alfred

Standalone Godot 4 editor addon: a Model Context Protocol bridge between AI coding assistants and the Godot editor (plus the running game via a debugger-channel relay). Drop it into any Godot 4.5+ project and pair it with [godot-mcp-server](https://github.com/lucas-r-manoguerra/godot-mcp-server).

## What it does

- Exposes the edited scene tree, nodes, resources, animations, TileMaps/GridMaps, profiler data, runtime state, screenshots, input injection and deterministic game-time control as MCP tools over a localhost WebSocket (`127.0.0.1:6550` by default).
- Session-token `auth` handshake (rotating token in the editor log), single-client discipline, scoped `res://`/`user://` path guard, `EditorUndoRedo`-wrapped edits, and a plugin API (`register_tool` + hot-reload `commands/custom/`) for project-specific tools.

## Install

As a git submodule (pinned, recommended):

```bash
git submodule add https://github.com/lucas-r-manoguerra/godot-mcp-alfred.git addons/godot_mcp
```

Or copy the `godot_mcp/` directory into your project's `addons/` folder. Then enable the plugin in **Project → Project Settings → Plugins**, and configure the MCP client with the matching server (see `tools/godot-mcp/client-config.json` in your game project or the server repo docs).

## Requirements

- Godot 4.5+ (developed against 4.7.x)
- `godot-mcp-server` 0.1.0+ as the MCP counterpart (older/newer servers negotiate capability via `mcp_handshake`; vanilla no-auth servers work with the server's `--no-auth` mode)

## Layout

- `plugin.gd` / `plugin.cfg` — editor plugin entry, WebSocket lifecycle, bind settings
- `websocket_server.gd` — single-client server, auth gate, stale reaping
- `command_router.gd` — builtin + custom tool registry
- `core/` — envelope, utils, scope guard, logger, debugger plugin
- `commands/` — one handler file per domain (each ≤ 400 lines); project tools go in `commands/custom/`
- `game_bridge/` — running-game autoload (input, screenshots, runtime state, exec guard)
- `ui/` — bottom-panel status UI

## License

MIT — see [LICENSE](LICENSE) (upstream `satelliteoflove/godot-mcp` terms, preserved verbatim).
