@tool
extends MCPBaseCommand
class_name MCPInfinityMUCommands

## Tools piloto de Infinity-MU: leen el grupo `mcp_watch` (ver _mcp_state()
## en jugador.gd y enemigo.gd) vía get_runtime_state. Siguen el mismo
## patrón de relay que runtime_state_commands.gd.

const GENERIC_TIMEOUT := 5.0
var _last_error: Dictionary = {}


func get_commands() -> Dictionary:
	return {
		"infinity_mu_party_status": infinity_mu_party_status,
		"infinity_mu_enemy_count": infinity_mu_enemy_count,
	}


## Estado completo del grupo `mcp_watch`: posiciones, vida y banderas
## de cada entidad observada, en una sola llamada.
func infinity_mu_party_status(params: Dictionary) -> Dictionary:
	var query := {
		"select": "group",
		"group": "mcp_watch",
		"max_nodes": int(params.get("max_nodes", 40)),
	}
	var result = await _send_and_wait("get_runtime_state", [query])
	if result == null:
		return _last_error
	if result is Dictionary:
		return _success(result)
	return _success({"data": result})


## Agregado de combate: cuenta enemigos en `mcp_watch` y resume su vida.
## Reutiliza la misma lectura que party_status y agrega en el editor.
func infinity_mu_enemy_count(params: Dictionary) -> Dictionary:
	var query := {
		"select": "group",
		"group": "mcp_watch",
		"max_nodes": int(params.get("max_nodes", 40)),
	}
	var result = await _send_and_wait("get_runtime_state", [query])
	if result == null:
		return _last_error
	if not (result is Dictionary):
		return _success({"data": result})
	var enemies := 0
	var total_hp := 0
	var names: Array = []
	for e in result.get("entities", []):
		if str(e.get("type", "")) != "Enemigo":
			continue
		enemies += 1
		var state: Dictionary = e.get("state", {})
		if state.has("vida"):
			total_hp += int(state["vida"])
		names.append(str(e.get("path", "")))
	return _success({"enemies": enemies, "total_hp": total_hp,
		"paths": names, "scene": result.get("scene", "")})


func _send_and_wait(msg_type: String, args: Array = []):
	if not EditorInterface.is_playing_scene():
		_last_error = _error("NOT_RUNNING", "No game is currently running")
		return null

	var debugger_plugin = _plugin.get_debugger_plugin() if _plugin else null
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		_last_error = _error("NO_SESSION", "No active debug session")
		return null

	var sent: bool = debugger_plugin.send_game_message(msg_type, args)
	if not sent:
		_last_error = _error("SEND_FAILED", "Failed to send message to game")
		return null

	var start_time := Time.get_ticks_msec()
	while not debugger_plugin.has_response(msg_type):
		await Engine.get_main_loop().process_frame
		if not debugger_plugin.has_active_session():
			_last_error = _error("GAME_EXITED", "The game exited while waiting for %s (stopped, quit, or crashed)" % msg_type)
			return null
		if (Time.get_ticks_msec() - start_time) / 1000.0 > GENERIC_TIMEOUT:
			debugger_plugin.clear_response(msg_type)
			_last_error = _error("TIMEOUT", "Timed out waiting for %s response" % msg_type)
			return null

	var response = debugger_plugin.get_response(msg_type)
	debugger_plugin.clear_response(msg_type)
	return response
