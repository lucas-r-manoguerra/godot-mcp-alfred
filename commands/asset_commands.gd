@tool
extends MCPBaseCommand
class_name MCPAssetCommands

# Trío de activos con guardia de alcance: importar, resolver UID y
# listar. Efectos sobre el sistema de archivos, por eso SIN undo
# (no son ediciones de escena, specs §2.5). Plantilla de
# escaneo/reimportación: system_commands.gd (rescan_filesystem).
# Códigos internos de otros handlers nunca se filtran hacia afuera:
# filesystem nulo → INVALID_PARAMS (no NO_FILESYSTEM), brecha del
# sondeo → TIMEOUT (no SCAN_TIMEOUT).


const SCAN_TIMEOUT_SEC := 60
const DEFAULT_LIMIT := 200
const MAX_LIMIT := 200


func get_commands() -> Dictionary:
	return {
		"import_asset": import_asset,
		"uid_resolve": uid_resolve,
		"list_assets": list_assets,
	}


# Escanea el sistema de archivos y reimporta la ruta indicada solo
# cuando reimport=true. Falla rápido con FILE_NOT_FOUND antes de
# escanear. Parámetros: { path: String (con alcance),
# reimport: bool = false }.
func import_asset(params: Dictionary) -> Dictionary:
	var raw_path: String = str(params.get("path", ""))
	if raw_path.is_empty():
		return _error("INVALID_PARAMS", "path is required and must not be empty")
	var scoped := MCPUtils.validate_scoped_path(raw_path)
	if scoped.has("error"):
		return _error("INVALID_PARAMS", "path out of scope: %s" % raw_path)
	var path: String = str(scoped["path"])

	# Fallo rápido: sin escaneo cuando el archivo no existe
	# (riesgo R6 de specs §7).
	if not FileAccess.file_exists(path):
		return _error("FILE_NOT_FOUND", "Asset file not found: %s" % path)

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return _error("INVALID_PARAMS", "Resource filesystem is not available")
	var reimport := bool(params.get("reimport", false))

	var start := Time.get_ticks_msec()
	efs.scan()
	while efs.is_scanning():
		if (Time.get_ticks_msec() - start) / 1000.0 > SCAN_TIMEOUT_SEC:
			return _error("TIMEOUT",
				"Filesystem scan did not finish within %ds; the editor may still be importing in the background." % SCAN_TIMEOUT_SEC)
		await Engine.get_main_loop().process_frame

	var messages: Array = []
	var status := "scanned-clean"
	if reimport:
		# Reimportación acotada a la ruta (nunca todo el árbol).
		efs.reimport_files(PackedStringArray([path]))
		status = "imported"
	# Nota: "failed" queda reservado en el vocabulario de specs §2.5
	# para futuros informes del importador; la API actual del motor
	# no devuelve fallo por archivo, así que las rutas de éxito usan
	# "imported" (con reimport) o "scanned-clean" (idempotente).
	return _success({"path": path, "status": status, "messages": messages})


# Resuelve un uid:// a su ruta res:// (null cuando está bien formado
# pero no registrado). Parámetros: { uid: String (^uid://) }.
func uid_resolve(params: Dictionary) -> Dictionary:
	var uid: String = str(params.get("uid", ""))
	if not uid.begins_with("uid://"):
		return _error("INVALID_PARAMS", "uid must match ^uid:// (got: %s)" % uid)
	var res_path: Variant = null
	var id := ResourceUID.text_to_id(uid)
	if ResourceUID.has_id(id):
		res_path = ResourceUID.get_id_path(id)
	return _success({"uid": uid, "res_path": res_path})


# Lista activos con el glob evaluado DURANTE el recorrido (no
# después), con .godot/ excluido y corte en limit + truncated.
# Parámetros: { glob: String (min 1), base?: String (con alcance,
# default res://), limit: int = 200 }.
func list_assets(params: Dictionary) -> Dictionary:
	var glob: String = str(params.get("glob", ""))
	if glob.is_empty():
		return _error("INVALID_PARAMS", "glob is required and must not be empty")
	var base: String = str(params.get("base", "res://"))
	var scoped := MCPUtils.validate_scoped_path(base)
	if scoped.has("error"):
		return _error("INVALID_PARAMS", "base out of scope: %s" % base)
	base = str(scoped["path"])

	var limit := int(params.get("limit", DEFAULT_LIMIT))
	if limit <= 0:
		return _error("INVALID_PARAMS", "limit must be a positive integer (got: %s)" % str(params.get("limit", DEFAULT_LIMIT)))
	var truncated := false
	if limit > MAX_LIMIT:
		limit = MAX_LIMIT
		truncated = true

	var paths: Array[String] = []
	var cut: Array = [false]
	_walk_dir(base, glob, paths, limit, cut)
	if bool(cut[0]):
		# El recorrido se cortó al llegar a limit: pudo haber más
		# coincidencias; el corte nunca es silencioso.
		truncated = true
	return _success({"paths": Array(paths), "truncated": truncated})


# Recorrido recursivo con DirAccess: el glob se evalúa por archivo
# durante el recorrido, los directorios .godot/ se podan y la
# recolección se detiene al llegar a limit (marca cut[0]).
func _walk_dir(dir_path: String, glob: String, collected: Array[String], limit: int, cut: Array) -> void:
	if collected.size() >= limit:
		cut[0] = true
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if collected.size() >= limit:
			cut[0] = true
			break
		if dir.current_is_dir():
			if entry != ".godot":
				_walk_dir(dir_path.path_join(entry), glob, collected, limit, cut)
		else:
			var full := dir_path.path_join(entry)
			if full.match(glob):
				collected.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
