@tool
extends MCPBaseCommand
class_name MCPIntrospectionCommands

# Introspección de solo lectura sobre ClassDB: listado, detalle y señales.
# Sin acceso a la escena, sin undo y sin relay. Los tres comandos responden
# con la envolvente estándar (_success / _error) y los códigos de la familia
# de specs §1.2. Clase desconocida → éxito con {found: false}, nunca error.


const DEFAULT_LIMIT := 200
const MAX_LIMIT := 200


func get_commands() -> Dictionary:
	return {
		"class_list": class_list,
		"class_describe": class_describe,
		"signals_of": signals_of,
	}


# Lista las clases registradas con filtros opcionales y paginación acotada.
# Parámetros: { search?: String, parent?: String, limit: int = 200 }.
func class_list(params: Dictionary) -> Dictionary:
	var limit := int(params.get("limit", DEFAULT_LIMIT))
	if limit <= 0:
		return _error("INVALID_PARAMS", "limit must be a positive integer (got: %s)" % str(params.get("limit", DEFAULT_LIMIT)))
	var truncated := false
	if limit > MAX_LIMIT:
		limit = MAX_LIMIT
		truncated = true
	var search: String = str(params.get("search", ""))
	var parent: String = str(params.get("parent", ""))
	# Filtro por clase base desconocida: éxito vacío, nunca excepción.
	if not parent.is_empty() and not ClassDB.class_exists(parent):
		return _success({"classes": [], "truncated": false})
	var classes: Array = []
	for cls_name in ClassDB.get_class_list():
		if not search.is_empty() and not cls_name.matchn("*" + search + "*"):
			continue
		if not parent.is_empty() and cls_name != parent and not ClassDB.is_parent_class(cls_name, parent):
			continue
		classes.append({
			"name": cls_name,
			"parent": ClassDB.get_parent_class(cls_name),
			"is_editor_class": _is_editor_class(cls_name),
		})
	if classes.size() > limit:
		classes = classes.slice(0, limit)
		truncated = true
	return _success({"classes": classes, "truncated": truncated})


# Describe una clase: resumen (brief) o detalle completo (full).
# Parámetros: { class_name: String, detail: "brief" | "full" = "brief" }.
func class_describe(params: Dictionary) -> Dictionary:
	var target_class: String = str(params.get("class_name", ""))
	if target_class.is_empty():
		return _error("INVALID_PARAMS", "class_name is required and must not be empty")
	var detail: String = str(params.get("detail", "brief"))
	if detail != "brief" and detail != "full":
		return _error("INVALID_PARAMS", "detail must be \"brief\" or \"full\" (got: %s)" % detail)
	if not ClassDB.class_exists(target_class):
		return _success({"found": false})
	var result := {
		"found": true,
		"name": target_class,
		"parent": ClassDB.get_parent_class(target_class),
		"signal_count": ClassDB.class_get_signal_list(target_class).size(),
		"method_count": ClassDB.class_get_method_list(target_class).size(),
		"property_count": ClassDB.class_get_property_list(target_class).size(),
	}
	if detail == "full":
		result["properties"] = _shape_properties(target_class)
		result["methods"] = _shape_methods(target_class)
		result["signals"] = _shape_signals(target_class)
		result["inheritors"] = ClassDB.get_inheriters_from_class(target_class)
	return _success(result)


# Enumera las señales de una clase con sus argumentos.
# Parámetros: { class_name: String }.
func signals_of(params: Dictionary) -> Dictionary:
	var target_class: String = str(params.get("class_name", ""))
	if target_class.is_empty():
		return _error("INVALID_PARAMS", "class_name is required and must not be empty")
	if not ClassDB.class_exists(target_class):
		return _success({"found": false})
	return _success({
		"found": true,
		"class_name": target_class,
		"signals": _shape_signals(target_class),
	})


# Predicado de specs §2.1: clase de editor si su nombre empieza con
# "Editor" o hereda de EditorPlugin.
func _is_editor_class(cls_name: String) -> bool:
	return cls_name.begins_with("Editor") or ClassDB.is_parent_class(cls_name, "EditorPlugin")


# Da forma a la lista de propiedades: [{ name, type, default, usage }].
# El valor por defecto se lee de una instancia temporal cuando la clase
# lo permite; en caso contrario se informa null. Nunca lanza.
func _shape_properties(target_class: String) -> Array:
	var shaped: Array = []
	var probe: Object = null
	if ClassDB.can_instantiate(target_class):
		probe = ClassDB.instantiate(target_class)
	for prop in ClassDB.class_get_property_list(target_class):
		var prop_name: String = str(prop.get("name", ""))
		var default_value: Variant = null
		if probe != null and prop_name in probe:
			default_value = probe.get(prop_name)
		shaped.append({
			"name": prop_name,
			"type": int(prop.get("type", 0)),
			"default": _serialize_value(default_value),
			"usage": int(prop.get("usage", 0)),
		})
	if probe != null and not (probe is RefCounted):
		probe.free()
	return shaped


# Da forma a la lista de métodos: [{ name, args, return_type }].
func _shape_methods(target_class: String) -> Array:
	var shaped: Array = []
	for method in ClassDB.class_get_method_list(target_class):
		var args: Array = []
		for arg in method.get("args", []):
			args.append({
				"name": str(arg.get("name", "")),
				"type": int(arg.get("type", 0)),
			})
		var return_type := 0
		if method.has("return"):
			return_type = int((method["return"] as Dictionary).get("type", 0))
		shaped.append({
			"name": str(method.get("name", "")),
			"args": args,
			"return_type": return_type,
		})
	return shaped


# Da forma a la lista de señales: [{ name, args: [{ name, type }] }].
func _shape_signals(target_class: String) -> Array:
	var shaped: Array = []
	for sig_info in ClassDB.class_get_signal_list(target_class):
		var args: Array = []
		for arg in sig_info.get("args", []):
			args.append({
				"name": str(arg.get("name", "")),
				"type": int(arg.get("type", 0)),
			})
		shaped.append({
			"name": str(sig_info.get("name", "")),
			"args": args,
		})
	return shaped
