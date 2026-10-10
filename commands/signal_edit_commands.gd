@tool
extends MCPBaseCommand
class_name MCPSignalEditCommands

# Conexiones persistentes de señales del editor: conectar y desconectar.
# Ambos comandos mutan la escena y por eso van envueltos en
# EditorUndoRedoManager (una acción por llamada, nombres verbatim de
# specs §2.3) para que Ctrl+Z restaure el estado previo y la conexión
# persista al guardar. Toda validación corre ANTES de crear la acción:
# un fallo nunca toca la escena. El mismo Callable con binds se registra
# en los lados do/undo para que disconnect coincida.


func get_commands() -> Dictionary:
	return {
		"connect_signal": connect_signal,
		"disconnect_signal": disconnect_signal,
	}


# Conecta una señal del emisor al método del objetivo.
# Parámetros: { node_path: String, signal: String, target_path: String,
# method: String, binds: Array = [] }.
func connect_signal(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var link := _validated_link(params)
	if link.has("error"):
		return link["error"]
	var emitter: Node = link["emitter"]
	var sig: String = link["signal"]
	var method: String = link["method"]
	var bound: Callable = link["callable"]
	if emitter.is_connected(StringName(sig), bound):
		return _error("ALREADY_CONNECTED", "Signal already connected: %s → %s" % [sig, method])

	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Connect %s → %s" % [sig, method])
	undo_redo.add_do_method(emitter, "connect", StringName(sig), bound)
	undo_redo.add_undo_method(emitter, "disconnect", StringName(sig), bound)
	undo_redo.commit_action()

	return _success({"connected": true})


# Desconecta una señal del emisor (par inverso de connect_signal).
# Parámetros: { node_path: String, signal: String, target_path: String,
# method: String, binds: Array = [] }.
func disconnect_signal(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var link := _validated_link(params)
	if link.has("error"):
		return link["error"]
	var emitter: Node = link["emitter"]
	var sig: String = link["signal"]
	var method: String = link["method"]
	var bound: Callable = link["callable"]
	if not emitter.is_connected(StringName(sig), bound):
		return _error("INVALID_PARAMS", "Signal not connected: %s → %s" % [sig, method])

	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Disconnect %s → %s" % [sig, method])
	undo_redo.add_do_method(emitter, "disconnect", StringName(sig), bound)
	undo_redo.add_undo_method(emitter, "connect", StringName(sig), bound)
	undo_redo.commit_action()

	return _success({"disconnected": true})


# Valida el enlace en el orden de specs §2.3 (el primer fallo gana):
# emisor/objetivo → NODE_NOT_FOUND; señal en emitter.get_signal_list() →
# SIGNAL_NOT_FOUND; target.has_method → METHOD_NOT_FOUND; ajuste de
# aridad de binds → INVALID_PARAMS. Devuelve el enlace resuelto o
# {"error": <envolvente>} sin tocar la escena.
func _validated_link(params: Dictionary) -> Dictionary:
	var node_path: String = str(params.get("node_path", ""))
	if node_path.is_empty():
		return {"error": _error("INVALID_PARAMS", "node_path is required and must not be empty")}
	var sig: String = str(params.get("signal", ""))
	if sig.is_empty():
		return {"error": _error("INVALID_PARAMS", "signal is required and must not be empty")}
	var target_path: String = str(params.get("target_path", ""))
	if target_path.is_empty():
		return {"error": _error("INVALID_PARAMS", "target_path is required and must not be empty")}
	var method: String = str(params.get("method", ""))
	if method.is_empty():
		return {"error": _error("INVALID_PARAMS", "method is required and must not be empty")}
	var raw_binds: Variant = params.get("binds", [])
	if not (raw_binds is Array):
		return {"error": _error("INVALID_PARAMS", "binds must be an Array")}
	var binds: Array = raw_binds

	var emitter := _get_node(node_path)
	if emitter == null:
		return {"error": _error("NODE_NOT_FOUND", "Emitter node not found: %s" % node_path)}
	var target := _get_node(target_path)
	if target == null:
		return {"error": _error("NODE_NOT_FOUND", "Target node not found: %s" % target_path)}

	var signal_arg_count := _signal_arg_count(emitter, sig)
	if signal_arg_count < 0:
		return {"error": _error("SIGNAL_NOT_FOUND", "Signal not found on %s: %s" % [node_path, sig])}
	if not target.has_method(method):
		return {"error": _error("METHOD_NOT_FOUND", "Method not found on %s: %s" % [target_path, method])}

	# Los binds se agregan tras los argumentos de la señal: el total no
	# debe superar la aridad del método objetivo.
	var method_arity := _method_arg_count(target, method)
	if method_arity >= 0 and signal_arg_count + binds.size() > method_arity:
		return {"error": _error("INVALID_PARAMS", "Too many binds for %s: signal has %d args, method takes %d, binds has %d" % [method, signal_arg_count, method_arity, binds.size()])}

	var base := Callable(target, StringName(method))
	var bound: Callable = base.bindv(binds) if not binds.is_empty() else base
	return {"emitter": emitter, "target": target, "signal": sig, "method": method, "callable": bound}


# Cuenta los argumentos de una señal (cubre señales de script y
# nativas). -1 si la señal no existe.
func _signal_arg_count(emitter: Node, sig: String) -> int:
	for info in emitter.get_signal_list():
		if str(info.get("name", "")) == sig:
			return (info.get("args", []) as Array).size()
	return -1


# Cuenta los argumentos de un método del objetivo. -1 si no figura en
# get_method_list (caso que no debe darse tras has_method).
func _method_arg_count(target: Object, method: String) -> int:
	for info in target.get_method_list():
		if str(info.get("name", "")) == method:
			return (info.get("args", []) as Array).size()
	return -1
