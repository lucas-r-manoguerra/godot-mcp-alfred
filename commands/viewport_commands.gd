@tool
extends MCPBaseCommand
class_name MCPViewportCommands

# Navegación del viewport 3D del editor y foco de selección.
# Solo navegación: ambos comandos mueven la cámara o la selección sin
# mutar la escena, por eso NO usan undo por regla (specs §2.4).
# Espeja selection_commands.gd (set_2d_viewport como precedente de
# escritura + read path de cámara + NO_VIEWPORT) y design §4
# (matemática de cámara + fallback solo-selección). Sin aplicación
# parcial: todo se valida antes de escribir la cámara, y applied:true
# solo se devuelve tras el read-back.


func get_commands() -> Dictionary:
	return {
		"set_3d_viewport": set_3d_viewport,
		"focus_selection": focus_selection,
	}


# Mueve la cámara 3D del editor a position/rotation (radianes) con
# desplazamiento opcional por foco+distancia.
# Parámetros: { position: {x,y,z}, rotation: {x,y,z},
# distance?: número positivo, focus_path?: String }.
func set_3d_viewport(params: Dictionary) -> Dictionary:
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return _error("NO_VIEWPORT", "Could not access 3D editor viewport")
	var camera := viewport.get_camera_3d()
	if camera == null:
		return _error("NO_VIEWPORT", "No 3D editor camera available")

	var pos_result := _parse_vec3(params.get("position"), "position")
	if pos_result.has("error"):
		return pos_result["error"]
	var rot_result := _parse_vec3(params.get("rotation"), "rotation")
	if rot_result.has("error"):
		return rot_result["error"]
	var pos: Vector3 = pos_result["value"]
	var rot: Vector3 = rot_result["value"]

	var focus_path: String = str(params.get("focus_path", ""))
	var has_focus := not focus_path.is_empty()
	var focus := Vector3.ZERO
	var focus_valid := false
	var degraded_note := ""
	if has_focus:
		var focus_node := _get_node(focus_path)
		if focus_node == null:
			return _error("NODE_NOT_FOUND", "Focus node not found: %s" % focus_path)
		var resolved := _resolve_focus(focus_node)
		if bool(resolved["ok"]):
			focus = resolved["focus"]
			focus_valid = true
		else:
			# Foco irresoluble: se degrada a aplicación sin
			# desplazamiento de foco, con nota y sin lanzar
			# (specs §2.4, design §4.1).
			degraded_note = "focus node has no global position; applied position+rotation without focus offset"

	if params.has("distance"):
		var raw_distance: Variant = params.get("distance")
		if not _is_number(raw_distance):
			return _error("INVALID_PARAMS", "distance must be a positive number")
		var distance := float(raw_distance)
		if distance <= 0.0:
			return _error("INVALID_PARAMS", "distance must be positive (got: %s)" % str(raw_distance))
		if not has_focus:
			return _error("INVALID_PARAMS", "distance needs a focus_path anchor")
		if focus_valid:
			# La cámara mira a lo largo de -Z: el vector atrás es +Z
			# rotado por la rotación pedida (design §4.1).
			var back := (Basis.from_euler(rot) * Vector3(0, 0, 1)).normalized()
			pos = focus + back * distance
		# Con foco degradado la distancia se ignora (nota mediante):
		# solo rotación, sin lanzar.

	# Escritura conjunta: ambas validadas antes de tocar la cámara.
	camera.global_position = pos
	camera.global_rotation = rot

	var apos: Vector3 = camera.global_position
	var arot: Vector3 = camera.global_rotation
	var result := {
		"position": {"x": apos.x, "y": apos.y, "z": apos.z},
		"rotation": {"x": arot.x, "y": arot.y, "z": arot.z},
		"applied": true,
	}
	if not degraded_note.is_empty():
		result["note"] = degraded_note
	return _success(result)


# Foco solo-selección (fallback normativo: no existe verbo scripteable
# de encuadre más allá de clear() + add_node()).
# Parámetros: { node_paths: Array[String] (1..64) }.
func focus_selection(params: Dictionary) -> Dictionary:
	var raw: Variant = params.get("node_paths", null)
	if not (raw is Array):
		return _error("INVALID_PARAMS", "node_paths must be an Array of 1..64 node paths")
	var paths: Array = raw
	if paths.size() < 1 or paths.size() > 64:
		return _error("INVALID_PARAMS", "node_paths needs 1..64 entries (got: %d)" % paths.size())

	# Resolver TODO primero: un fallo deja la selección intacta
	# (sin selección parcial, specs §3).
	var nodes: Array[Node] = []
	for entry in paths:
		if not (entry is String) or (entry as String).is_empty():
			return _error("INVALID_PARAMS", "Every node_paths entry must be a non-empty String")
		var target := _get_node(entry)
		if target == null:
			return _error("NODE_NOT_FOUND", "Node not found: %s" % str(entry))
		nodes.append(target)

	var selection := EditorInterface.get_selection()
	selection.clear()
	for n in nodes:
		selection.add_node(n)
	return _success({
		"focused": nodes.size(),
		"framed": false,
		"note": "selection-only: no scriptable frame verb; framed=false",
	})


# Resuelve el punto de foco de un nodo: global_position si es Node3D,
# centro del AABB llevado a global si es VisualInstance3D, si no un
# fallback con guardas que nunca lanza. Devuelve {"ok", "focus?"}.
func _resolve_focus(focus_node: Node) -> Dictionary:
	if focus_node is Node3D:
		return {"ok": true, "focus": (focus_node as Node3D).global_position}
	# Rama VisualInstance3D tras Node3D por orden de specs §2.4
	# (inalcanzable en la práctica: VisualInstance3D es Node3D).
	if focus_node is VisualInstance3D:
		var visual := focus_node as VisualInstance3D
		return {"ok": true, "focus": visual.to_global(visual.get_aabb().get_center())}
	if "global_position" in focus_node:
		var gv: Variant = focus_node.get("global_position")
		if gv is Vector3:
			return {"ok": true, "focus": gv}
	return {"ok": false}


# Parsea un {x, y, z} numérico a Vector3. Ejes ausentes o no
# numéricos → INVALID_PARAMS. Devuelve {"value"} o {"error"}.
func _parse_vec3(raw: Variant, param_name: String) -> Dictionary:
	if not (raw is Dictionary):
		return {"error": _error("INVALID_PARAMS", "%s must be a {x, y, z} dictionary" % param_name)}
	var spec: Dictionary = raw
	for axis in ["x", "y", "z"]:
		if not spec.has(axis) or not _is_number(spec[axis]):
			return {"error": _error("INVALID_PARAMS", "%s.%s must be a number" % [param_name, axis])}
	return {"value": Vector3(float(spec["x"]), float(spec["y"]), float(spec["z"]))}


# Números JSON llegan como float o int; cualquier otro tipo no es
# una coordenada válida.
func _is_number(value: Variant) -> bool:
	return value is float or value is int
