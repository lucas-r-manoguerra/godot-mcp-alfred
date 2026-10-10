@tool
extends MCPBaseCommand
class_name MCPRuntimeStateCommands

const GENERIC_TIMEOUT := 5.0
# Tope del acumulador de trace_signal (heredado del sampler MAX_EVENTS).
const MAX_EVENTS := 200
# Ventana del sampler en ms (clamp 100–5000 del sampler, §2.3 usa 5000).
const TRACE_WINDOW_MS := 5000
var _last_error: Dictionary = {}


func get_commands() -> Dictionary:
	return {
		"get_runtime_state": get_runtime_state,
		"watch_start": watch_start,
		"watch_collect": watch_collect,
		"watch_stop": watch_stop,
		"trace_signal": trace_signal,
	}


func get_runtime_state(params: Dictionary) -> Dictionary:
	var result = await _send_and_wait("get_runtime_state", [params])
	if result == null:
		return _last_error
	if result is Dictionary:
		return _success(result)
	return _success({"data": result})


func watch_start(params: Dictionary) -> Dictionary:
	var specs: Array = params.get("specs", [])
	var hz: int = params.get("hz", 20)
	var duration_ms: int = params.get("duration_ms", 1000)
	var sigs: Array = params.get("signals", [])
	var result = await _send_and_wait("watch_start", [specs, hz, duration_ms, sigs])
	if result == null:
		return _last_error
	if result is Dictionary:
		return _success(result)
	return _success({"started": true})


func watch_collect(_params: Dictionary) -> Dictionary:
	var result = await _send_and_wait("watch_collect", [])
	if result == null:
		return _last_error
	if result is Dictionary:
		return _success(result)
	return _success({"data": result})


func watch_stop(_params: Dictionary) -> Dictionary:
	var result = await _send_and_wait("watch_stop", [])
	if result == null:
		return _last_error
	if result is Dictionary:
		return _success(result)
	return _success({"stopped": true})


# Traza una señal del juego durante duration_s segundos componiendo el
# camino watch existente (sin cambios al sampler ni mensajes nuevos).
# Parámetros: { node_path: String, signal: String,
# duration_s: positivo, máximo 300, por defecto 10 }.
# Secuencia de specs §2.3: puerta de parámetros → puerta de reposo
# (NOT_RUNNING sin juego) → UN watch_start → N ventanas de watch_collect
# → watch_stop OBLIGATORIO en todos los caminos → {events, truncated}.
func trace_signal(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", ""))
	if node_path.is_empty():
		return _error("INVALID_PARAMS", "node_path is required and must not be empty")
	var sig: String = str(params.get("signal", ""))
	if sig.is_empty():
		return _error("INVALID_PARAMS", "signal is required and must not be empty")
	var raw_duration: Variant = params.get("duration_s", 10.0)
	if not (raw_duration is int) and not (raw_duration is float):
		return _error("INVALID_PARAMS", "duration_s must be a positive number up to 300")
	var duration_s := float(raw_duration)
	if duration_s <= 0.0 or duration_s > 300.0:
		return _error("INVALID_PARAMS", "duration_s must be a positive number up to 300 (got: %s)" % str(raw_duration))

	if not EditorInterface.is_playing_scene():
		return _error("NOT_RUNNING", "No game is currently running")

	var start := await watch_start({"specs": [], "hz": 20, "duration_ms": TRACE_WINDOW_MS, "signals": [{"path": node_path, "signal": sig}]})
	if str(start.get("status", "")) == "error":
		return start

	var events: Array = []
	var truncated := false
	var exit_error: Dictionary = {}
	var seen := 0
	var total_ms := int(duration_s * 1000.0)
	var windows := int(ceil(duration_s / 5.0))
	var trace_start := Time.get_ticks_msec()
	var window_start := trace_start
	for _i in windows:
		while true:
			await Engine.get_main_loop().process_frame
			if not EditorInterface.is_playing_scene():
				exit_error = _error("NOT_RUNNING", "The game exited during trace_signal")
				break
			var now := Time.get_ticks_msec()
			if now - window_start >= TRACE_WINDOW_MS or now - trace_start >= total_ms:
				break
		if not exit_error.is_empty():
			break
		var chunk := await watch_collect({})
		if str(chunk.get("status", "")) == "error":
			var chunk_error: Dictionary = chunk.get("error", {})
			var code: String = str(chunk_error.get("code", ""))
			if code == "TIMEOUT":
				exit_error = chunk
			else:
				exit_error = _error("NOT_RUNNING", "Trace interrupted (%s): %s" % [code, str(chunk_error.get("message", ""))])
			break
		var collected: Dictionary = chunk.get("result", {})
		if bool(collected.get("events_truncated", false)):
			truncated = true
		# collect() devuelve el acumulado desde el inicio: solo se agregan
		# los eventos nuevos desde la última ventana (sin duplicar).
		var fresh: Array = (collected.get("events", []) as Array).slice(seen)
		seen += fresh.size()
		for ev in fresh:
			if events.size() >= MAX_EVENTS:
				break
			events.append(ev)
		if events.size() >= MAX_EVENTS:
			truncated = true
			break
		window_start = Time.get_ticks_msec()
		if window_start - trace_start >= total_ms:
			break

	# Parada obligatoria en TODOS los caminos (disciplina try/finally sin
	# retornos tempranos arriba que la salten); su propio fallo se traga.
	var _stop := await watch_stop({})
	if not exit_error.is_empty():
		return exit_error
	return _success({"events": events, "truncated": truncated})


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
