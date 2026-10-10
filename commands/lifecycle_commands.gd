@tool
extends MCPBaseCommand
class_name MCPLifecycleCommands

# Cuarteto de ciclo de vida del árbol de escena: crear, instanciar,
# duplicar y eliminar nodos. Los cuatro comandos mutan la escena y por
# eso van envueltos en EditorUndoRedoManager (una acción por llamada,
# nombres verbatim de specs §2.2) para que Ctrl+Z restaure el estado
# previo y la escena quede marcada como modificada. Toda validación
# corre ANTES de crear la acción: un fallo nunca toca la escena.


func get_commands() -> Dictionary:
	return {
		"create_node": create_node,
		"instantiate_scene": instantiate_scene,
		"duplicate_node": duplicate_node,
		"delete_node": delete_node,
	}


# Crea un nodo de la clase indicada como hijo del padre resuelto.
# Parámetros: { parent_path: String, class_name: String, name?: String,
# properties?: Dictionary, owner_to_scene: bool = true }.
func create_node(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var parent_path: String = str(params.get("parent_path", ""))
	if parent_path.is_empty():
		return _error("INVALID_PARAMS", "parent_path is required and must not be empty")
	var target_class: String = str(params.get("class_name", ""))
	if target_class.is_empty():
		return _error("INVALID_PARAMS", "class_name is required and must not be empty")

	var parent := _get_node(parent_path)
	if parent == null:
		return _error("NODE_NOT_FOUND", "Parent node not found: %s" % parent_path)
	if not ClassDB.class_exists(target_class):
		return _error("INVALID_PARAMS", "Unknown class_name: %s" % target_class)

	var node := ClassDB.instantiate(target_class) as Node
	if node == null:
		return _error("INVALID_PARAMS", "Cannot instantiate class as Node: %s" % target_class)
	if params.has("name"):
		var wanted: String = str(params["name"])
		if wanted.is_empty():
			node.free()
			return _error("INVALID_PARAMS", "name must not be empty")
		node.name = wanted

	# Pre-validación TOTAL antes de add_child: una clave desconocida
	# aborta sin creación parcial (el nodo sonda se libera).
	var properties: Dictionary = params.get("properties", {})
	for key in properties:
		if not (key in node):
			node.free()
			return _error("INVALID_PARAMS", "Unknown property for %s: %s" % [target_class, str(key)])
	# Claves válidas: se aplican los valores deserializados.
	for key in properties:
		node.set(key, MCPUtils.deserialize_value(properties[key]))

	var scene_root := EditorInterface.get_edited_scene_root()
	var owner_to_scene := bool(params.get("owner_to_scene", true))
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Create %s %s" % [target_class, node.name])
	undo_redo.add_do_method(parent, "add_child", node)
	if owner_to_scene:
		undo_redo.add_do_method(node, "set_owner", scene_root)
	undo_redo.add_undo_method(parent, "remove_child", node)
	undo_redo.add_undo_method(node, "queue_free")
	undo_redo.commit_action()

	return _success({"node_path": _usable_path(scene_root, node), "class_name": target_class})


# Instancia una escena (.tscn) como hija del padre resuelto.
# Parámetros: { parent_path: String, scene_path: String (con alcance),
# name?: String, owner_to_scene: bool = true }.
func instantiate_scene(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var parent_path: String = str(params.get("parent_path", ""))
	if parent_path.is_empty():
		return _error("INVALID_PARAMS", "parent_path is required and must not be empty")
	var scene_path: String = str(params.get("scene_path", ""))
	if scene_path.is_empty():
		return _error("INVALID_PARAMS", "scene_path is required and must not be empty")

	var parent := _get_node(parent_path)
	if parent == null:
		return _error("NODE_NOT_FOUND", "Parent node not found: %s" % parent_path)

	# Guardia de alcance: absolutas y ".." se rechazan con INVALID_PARAMS
	# (la familia de specs §1.2 no incluye PATH_OUT_OF_SCOPE hacia afuera).
	var scoped := MCPUtils.validate_scoped_path(scene_path)
	if scoped.has("error"):
		return _error("INVALID_PARAMS", "scene_path out of scope: %s" % scene_path)
	scene_path = str(scoped["path"])

	if not FileAccess.file_exists(scene_path):
		return _error("FILE_NOT_FOUND", "Scene file not found: %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return _error("INVALID_PARAMS", "Not a loadable scene: %s" % scene_path)
	var instance := packed.instantiate()
	if instance == null:
		return _error("INVALID_PARAMS", "Could not instantiate scene: %s" % scene_path)
	if params.has("name"):
		var wanted: String = str(params["name"])
		if wanted.is_empty():
			instance.free()
			return _error("INVALID_PARAMS", "name must not be empty")
		instance.name = wanted

	var scene_root := EditorInterface.get_edited_scene_root()
	var owner_to_scene := bool(params.get("owner_to_scene", true))
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Instantiate %s" % scene_path.get_file())
	undo_redo.add_do_method(parent, "add_child", instance)
	if owner_to_scene:
		undo_redo.add_do_method(instance, "set_owner", scene_root)
	undo_redo.add_undo_method(parent, "remove_child", instance)
	undo_redo.add_undo_method(instance, "queue_free")
	undo_redo.commit_action()

	return _success({"node_path": _usable_path(scene_root, instance), "scene_path": scene_path})


# Duplica un nodo como hermano siguiente, con el dueño de escena fijado.
# Parámetros: { node_path: String, new_name?: String }.
func duplicate_node(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var node_path: String = str(params.get("node_path", ""))
	if node_path.is_empty():
		return _error("INVALID_PARAMS", "node_path is required and must not be empty")

	var node := _get_node(node_path)
	if node == null:
		return _error("NODE_NOT_FOUND", "Node not found: %s" % node_path)
	var scene_root := EditorInterface.get_edited_scene_root()
	if node == scene_root:
		return _error("INVALID_PARAMS", "Cannot duplicate the scene root: %s" % node_path)
	var parent := node.get_parent()
	if parent == null:
		return _error("INVALID_PARAMS", "Node has no parent: %s" % node_path)

	var copy := node.duplicate()
	if params.has("new_name"):
		var wanted: String = str(params["new_name"])
		if wanted.is_empty():
			copy.free()
			return _error("INVALID_PARAMS", "new_name must not be empty")
		copy.name = wanted
	var index := parent.get_children().find(node)

	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Duplicate %s" % node.name)
	undo_redo.add_do_method(parent, "add_child", copy)
	undo_redo.add_do_method(parent, "move_child", copy, index + 1)
	undo_redo.add_do_method(copy, "set_owner", scene_root)
	undo_redo.add_undo_method(parent, "remove_child", copy)
	undo_redo.add_undo_method(copy, "queue_free")
	undo_redo.commit_action()

	return _success({"node_path": _usable_path(scene_root, copy), "source": node_path})


# Elimina un nodo previa confirmación del nombre hoja. El lado do solo
# desvincula (SIN queue_free) para que el undo reintegre la instancia.
# Parámetros: { node_path: String, confirm_name: String }.
func delete_node(params: Dictionary) -> Dictionary:
	var scene_check := _require_scene_open()
	if not scene_check.is_empty():
		return scene_check

	var node_path: String = str(params.get("node_path", ""))
	if node_path.is_empty():
		return _error("INVALID_PARAMS", "node_path is required and must not be empty")
	var confirm_name: String = str(params.get("confirm_name", ""))
	if confirm_name.is_empty():
		return _error("INVALID_PARAMS", "confirm_name is required and must not be empty")

	var node := _get_node(node_path)
	if node == null:
		return _error("NODE_NOT_FOUND", "Node not found: %s" % node_path)
	if node.name != confirm_name:
		return _error("CONFIRM_MISMATCH", "confirm_name mismatch: expected %s (got: %s)" % [node.name, confirm_name])
	var scene_root := EditorInterface.get_edited_scene_root()
	if node == scene_root:
		return _error("CANNOT_DELETE_ROOT", "Cannot delete the scene root")
	var old_parent := node.get_parent()
	if old_parent == null:
		return _error("INVALID_PARAMS", "Node has no parent: %s" % node_path)
	var old_index := old_parent.get_children().find(node)

	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("Delete %s" % node.name)
	undo_redo.add_do_method(old_parent, "remove_child", node)
	undo_redo.add_undo_method(old_parent, "add_child", node)
	undo_redo.add_undo_method(old_parent, "move_child", node, old_index)
	undo_redo.commit_action()

	return _success({"deleted": true, "node_path": node_path})


# Ruta utilizable "/root/<Escena>/..." como en node_commands.gd:107-113.
func _usable_path(scene_root: Node, node: Node) -> String:
	var usable := "/root/" + scene_root.name
	var relative := scene_root.get_path_to(node)
	if relative != NodePath("."):
		usable += "/" + str(relative)
	return usable
