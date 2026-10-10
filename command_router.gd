@tool
extends RefCounted
class_name MCPCommandRouter

var _commands: Dictionary = {}
var _handlers: Array[MCPBaseCommand] = []

# Registro de tools custom (ver reload_custom_tools): nombre -> Callable.
# Vive separado del mapa estático para poder descargarlo sin tocar los
# comandos built-in.
var _custom_commands: Dictionary = {}
var _custom_handlers: Array = []
var _plugin: EditorPlugin

const CUSTOM_TOOLS_DIR := "res://addons/godot_mcp/commands/custom"
# Directorio project-side para tools custom del juego. Vive fuera del
# addon para que cada proyecto registre sus propias tools sin tocar el
# código del addon. Se escanea después de CUSTOM_TOOLS_DIR (legacy).
const PROJECT_TOOLS_DIR := "res://mcp_tools"


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_register_handler(MCPSystemCommands.new(), plugin)
	_register_handler(MCPSceneCommands.new(), plugin)
	_register_handler(MCPNodeCommands.new(), plugin)
	_register_handler(MCPSelectionCommands.new(), plugin)
	_register_handler(MCPProjectCommands.new(), plugin)
	_register_handler(MCPDebugCommands.new(), plugin)
	_register_handler(MCPScreenshotCommands.new(), plugin)
	_register_handler(MCPAnimationCommands.new(), plugin)
	_register_handler(MCPTilemapCommands.new(), plugin)
	_register_handler(MCPResourceCommands.new(), plugin)
	_register_handler(MCPScene3DCommands.new(), plugin)
	_register_handler(MCPInputCommands.new(), plugin)
	_register_handler(MCPIntrospectionCommands.new(), plugin)
	_register_handler(MCPProfilerCommands.new(), plugin)
	_register_handler(MCPRuntimeStateCommands.new(), plugin)
	_register_handler(MCPGameTimeCommands.new(), plugin)
	_register_handler(MCPExecCommands.new(), plugin)
	_register_handler(MCPMeshCommands.new(), plugin)
	reload_custom_tools()


func _register_handler(handler: MCPBaseCommand, plugin: EditorPlugin) -> void:
	handler.setup(plugin)
	_handlers.append(handler)
	var cmds := handler.get_commands()
	for cmd_name in cmds:
		_commands[cmd_name] = cmds[cmd_name]


func handle_command(command: String, params: Dictionary):
	if _custom_commands.has(command):
		var custom: Callable = _custom_commands[command]
		var custom_result = await custom.call(params)
		return custom_result
	if not _commands.has(command):
		return MCPUtils.error("UNKNOWN_COMMAND", "Unknown command: %s" % command)

	var callable: Callable = _commands[command]
	var result = await callable.call(params)
	return result


## Registra una tool custom bajo [param name]. No pisa comandos built-in:
## devuelve un error si el nombre ya existe en cualquier mapa.
func register_tool(name: String, callable: Callable) -> Dictionary:
	if name.is_empty() or not callable.is_valid():
		return MCPUtils.error("INVALID_PARAMS", "register_tool needs a name and a valid Callable")
	if _commands.has(name) or _custom_commands.has(name):
		return MCPUtils.error("DUPLICATE_TOOL", "Tool already registered: %s" % name)
	_custom_commands[name] = callable
	return MCPUtils.success({"tool": name})


## Da de baja una tool custom. Los comandos built-in no se pueden descargar.
func unregister_tool(name: String) -> Dictionary:
	if not _custom_commands.has(name):
		return MCPUtils.error("NOT_FOUND", "No custom tool registered: %s" % name)
	_custom_commands.erase(name)
	return MCPUtils.success({"removed": name})


func has_command(command: String) -> bool:
	return _commands.has(command) or _custom_commands.has(command)


## Hot-reload de tools custom: descarga las anteriores y vuelve a escanear
## CUSTOM_TOOLS_DIR (legacy, dentro del addon) y PROJECT_TOOLS_DIR
## (project-side, fuera del addon). Cada .gd que extienda MCPBaseCommand
## se instancia con setup() y sus comandos entran al mapa custom. Nunca
## toca los built-in. Devuelve {reloaded, tools, errors}; sin directorios
## devuelve {reloaded: 0}.
func reload_custom_tools() -> Dictionary:
	_custom_commands.clear()
	_custom_handlers.clear()
	var loaded: Array = []
	var errors: Array = []
	var scanned := 0
	if DirAccess.dir_exists_absolute(CUSTOM_TOOLS_DIR):
		scanned += 1
		_scan_custom_dir(CUSTOM_TOOLS_DIR, loaded, errors)
	if DirAccess.dir_exists_absolute(PROJECT_TOOLS_DIR):
		scanned += 1
		_scan_custom_dir(PROJECT_TOOLS_DIR, loaded, errors)
	if scanned == 0:
		return MCPUtils.success({"reloaded": 0, "tools": [], "errors": [],
			"note": "No custom tools dir: %s" % CUSTOM_TOOLS_DIR})
	return MCPUtils.success({"reloaded": loaded.size(), "tools": loaded, "errors": errors})


## Escanea un directorio de tools custom. Cada fallo por archivo se aísla
## con log + skip: el resto de archivos sigue cargándose.
func _scan_custom_dir(tools_dir: String, loaded: Array, errors: Array) -> void:
	for file in DirAccess.get_files_at(tools_dir):
		if not file.ends_with(".gd"):
			continue
		var path := tools_dir.path_join(file)
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			MCPLog.warn("Tool custom omitida (%s): not a loadable GDScript" % path)
			errors.append({"file": file, "reason": "not a loadable GDScript"})
			continue
		var inst: Object = script.new()
		if not (inst is MCPBaseCommand):
			MCPLog.warn("Tool custom omitida (%s): must extend MCPBaseCommand" % path)
			errors.append({"file": file, "reason": "must extend MCPBaseCommand"})
			continue
		var handler := inst as MCPBaseCommand
		handler.setup(_plugin)
		_custom_handlers.append(handler)
		for cmd_name in handler.get_commands():
			if _commands.has(cmd_name) or _custom_commands.has(cmd_name):
				MCPLog.warn("Tool custom omitida (%s): duplicate tool: %s" % [path, cmd_name])
				errors.append({"file": file, "reason": "duplicate tool: %s" % cmd_name})
				continue
			_custom_commands[cmd_name] = handler.get_commands()[cmd_name]
			loaded.append(cmd_name)
