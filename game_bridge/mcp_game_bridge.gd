extends Node
class_name MCPGameBridge

## Núcleo delgado del bridge de juego: ciclo de vida del autoload,
## despacho de mensajes del depurador y utilidades compartidas.
## La lógica vive en los módulos MCPBridge* (mismo directorio);
## los mensajes del depurador y el protocolo no cambian.

# Cap on frames waited for the main scene to appear before announcing ready
# anyway. The scene is normally added within a frame or two of the bridge
# autoload's _ready; the cap only matters for a scene-less run (a SceneTree-only
# tool), so it never blocks readiness forever. ~10s at 60 fps.
const READY_SCENE_WAIT_FRAMES := 600

var _logger: _MCPGameLogger
var _profiler: MCPFrameProfiler
var _sampler: MCPRuntimeStateSampler
var _exec_holder: Node = null

# Set once the bridge has told the editor the game is ready to drive. Guards the
# announcement against firing twice and lets the headless test observe it.
var _ready_announced := false

# Mesh warnings cache: written by MCPBridgeInspect, piggybacked by screenshots.
var _mesh_warnings: Array[String] = []

# Módulos del bridge (lógica extraída; el protocolo no cambia).
var _pred: MCPBridgePredicate
var _input_timeline: MCPBridgeInputTimeline
var _input_seq: MCPBridgeInputSequence
var _freeze: MCPBridgeFreeze
var _step: MCPBridgeStep
var _runtime: MCPBridgeRuntimeState
var _entity: MCPBridgeEntity
var _inspect: MCPBridgeInspect
var _shot: MCPBridgeScreenshot
var _exec: MCPBridgeExec


func _ready() -> void:
	# The bridge must keep processing while the scene tree is paused. Input
	# sequences are driven from _process, so without this a press that toggles
	# `paused = true` freezes the runner mid-sequence: the paired release never
	# fires and the editor-side wait times out (~30s) — pause menus, a primary
	# injection target, become undrivable. The bridge answers to the debugger,
	# not the game's pause state. Children (the sampler) inherit this mode.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Los módulos siempre existen (aunque no haya sesión de debugger), para
	# que _process/_physics_process/is_stepping nunca toquen Nil en una
	# ejecución sin depurador (p. ej. juego exportado o playtest headless).
	_new_modules()
	if not EngineDebugger.is_active():
		return
	_logger = _MCPGameLogger.new()
	OS.add_logger(_logger)
	_profiler = MCPFrameProfiler.new()
	EngineDebugger.register_profiler("mcp_frame_profiler", _profiler)
	_sampler = MCPRuntimeStateSampler.new()
	add_child(_sampler)
	EngineDebugger.register_message_capture("godot_mcp", _on_debugger_message)
	set_physics_process(false)  # only counts ticks during a step window
	MCPLog.info("Game bridge initialized")

	# Launch-frozen: the editor sets this env var just before spawning the game
	# (godot_editor run with frozen=true), so the freeze lands before the first
	# process frame — agent latency between run and the first input costs the
	# game nothing. Scene _ready callbacks still run; processing does not start.
	if OS.get_environment(MCPBridgeFreeze.LAUNCH_FROZEN_ENV) == "1":
		_freeze._launched_frozen = true
		_freeze._engage_freeze()
		MCPLog.info("Game bridge: launched frozen")

	# Tell the editor when the game is actually drivable, so input injected right
	# after `run` is not silently dropped into a half-booted game (see #241).
	_announce_bridge_ready_when_drivable()


func _new_modules() -> void:
	_pred = MCPBridgePredicate.new()
	_input_timeline = MCPBridgeInputTimeline.new()
	_input_seq = MCPBridgeInputSequence.new()
	_freeze = MCPBridgeFreeze.new()
	_step = MCPBridgeStep.new()
	_runtime = MCPBridgeRuntimeState.new()
	_entity = MCPBridgeEntity.new()
	_inspect = MCPBridgeInspect.new()
	_shot = MCPBridgeScreenshot.new()
	_exec = MCPBridgeExec.new()
	for m in [_pred, _input_timeline, _input_seq, _freeze, _step,
			_runtime, _entity, _inspect, _shot, _exec]:
		m.b = self


func _exit_tree() -> void:
	# Guaranteed cleanup: never leave an action latched when the bridge node
	# leaves the tree (game shutdown / scene change). Safe if nothing is held.
	if _input_timeline:
		_input_timeline._release_held_actions()
	if EngineDebugger.is_active():
		EngineDebugger.unregister_message_capture("godot_mcp")
		if _profiler:
			EngineDebugger.unregister_profiler("mcp_frame_profiler")


# The bridge autoload's _ready runs BEFORE the main scene is added to the tree,
# so the debug session is live (and the editor sees has_active_session) while
# current_scene is still null. Input injected in that window is dispatched into a
# game that has nothing to consume it — reported as executed, but a silent no-op
# (#241). Wait for the scene to exist plus one frame (so its own _ready/input
# wiring has run), then announce readiness; the editor gates input on this signal.
func _announce_bridge_ready_when_drivable() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var frames := 0
	while tree.current_scene == null and frames < READY_SCENE_WAIT_FRAMES:
		await tree.process_frame
		frames += 1
	# One more frame so a freshly-added scene has had its first _ready/process pass.
	# process_frame fires even while paused, so launch-frozen runs still report ready.
	await tree.process_frame
	var scene_path := tree.current_scene.scene_file_path if tree.current_scene else ""
	_emit_bridge_ready(scene_path)


func _emit_bridge_ready(scene_path: String) -> void:
	if _ready_announced:
		return
	_ready_announced = true
	EngineDebugger.send_message("godot_mcp:bridge_ready", [scene_path])
	MCPLog.info("Game bridge: ready to drive (%s)" % scene_path)


func _process(delta: float) -> void:
	_freeze._game_time_process(delta)
	_input_seq._sequence_process(delta)
	_inspect._mesh_sniff_process()


func _physics_process(_delta: float) -> void:
	_step._physics_tick()


## Public: true while a godot_game_time step / step_until window is advancing
## the tree (see MCPBridgeStep.is_active). Read it as
## `get_node("/root/MCPGameBridge").is_stepping()`.
func is_stepping() -> bool:
	return _step and _step.is_active()


# Processing is needed by three independent features; only switch it off when
# none of them is active (the frozen monitor must run every frame, so the old
# "disable after the sequence" shortcut no longer applies unconditionally).
func _update_processing() -> void:
	set_process(_input_seq._sequence_running or _freeze._frozen or _step._step_active)


func _on_debugger_message(message: String, data: Array) -> bool:
	match message:
		"take_screenshot":
			_shot._take_screenshot_deferred.call_deferred(data)
			return true
		"get_performance_metrics":
			_inspect._handle_get_performance_metrics()
			return true
		"find_nodes":
			_inspect._handle_find_nodes(data)
			return true
		"get_input_map":
			_input_seq._handle_get_input_map()
			return true
		"execute_input_sequence":
			_input_seq._handle_execute_input_sequence(data)
			return true
		"type_text":
			_input_seq._handle_type_text(data)
			return true
		"get_profiler_data":
			_inspect._handle_get_profiler_data()
			return true
		"get_active_processes":
			_inspect._handle_get_active_processes()
			return true
		"get_signal_connections":
			_inspect._handle_get_signal_connections(data)
			return true
		"get_runtime_state":
			_runtime._handle_get_runtime_state(data)
			return true
		"watch_start":
			_runtime._handle_watch_start(data)
			return true
		"watch_collect":
			_runtime._handle_watch_collect()
			return true
		"watch_stop":
			_runtime._handle_watch_stop()
			return true
		"game_time_freeze":
			_freeze._handle_game_time_freeze(data)
			return true
		"game_time_step":
			_step._handle_game_time_step(data)
			return true
		"game_time_step_until":
			_step._handle_game_time_step_until(data)
			return true
		"game_time_thaw":
			_freeze._handle_game_time_thaw(data)
			return true
		"game_time_status":
			_freeze._handle_game_time_status(data)
			return true
		"exec_run":
			_exec._handle_exec_run(data)
			return true
		"exec_list":
			_exec._handle_exec_list(data)
			return true
		"exec_remove":
			_exec._handle_exec_remove(data)
			return true
		"exec_clear":
			_exec._handle_exec_clear(data)
			return true
		"validate_meshes":
			_inspect._handle_validate_meshes(data)
			return true
	return false


# Absolute tree path. Identical to the old "/root/<scene>/<relative>" form for
# scene nodes, and correct (not "/root/Main/../Conductor") for autoloads and
# other nodes beside the scene now that walkers can reach them (#369).
func node_path_string(node: Node, _scene_root: Node) -> String:
	return str(node.get_path())


# Where a node lives relative to the running scene: "scene", "autoload", "exec"
# (attached by godot_exec under the holder), or "root" (anything else beside
# the scene). The bridge's own node is filtered out by callers.
func _node_location(node: Node, scene_root: Node) -> String:
	var tree := get_tree()
	var n := node
	while n != null and n.get_parent() != tree.root:
		n = n.get_parent()
	if n == null:
		return "root"
	if n == scene_root:
		return "scene"
	if n == _exec_holder:
		return "exec"
	if ProjectSettings.has_setting("autoload/" + String(n.name)):
		return "autoload"
	return "root"


func ensure_exec_holder() -> Node:
	if _exec_holder != null and is_instance_valid(_exec_holder):
		return _exec_holder
	_exec_holder = Node.new()
	_exec_holder.name = "MCPExecHolder"
	# Stamp attach time on whatever user scripts add, so exec_list can report an
	# age without trusting the script to record one.
	_exec_holder.child_entered_tree.connect(func(child: Node) -> void:
		child.set_meta("mcp_exec_attached_ms", Time.get_ticks_msec()))
	get_tree().root.add_child(_exec_holder)
	return _exec_holder


# A stable position in the logger stream (survives ring-buffer trims): lines
# appended ever = dropped + currently held.
func _exec_logger_mark() -> int:
	return (_logger.get_dropped() + _logger.get_output().size()) if _logger else 0


# The window of logger lines produced since `mark` (an _exec_logger_mark
# value), error lines only. Process-wide, not per-script: a concurrent game
# error inside the window rides along — acceptable for an honest "what went
# wrong" echo. If the ring buffer trimmed past the mark (a >1000-line script),
# the lost stretch is reported instead of silently misattributed.
func _exec_logger_delta(mark: int) -> Array:
	var out: Array = []
	if _logger == null:
		return out
	var lines := _logger.get_output()
	var start := mark - _logger.get_dropped()
	if start < 0:
		out.append("... (log buffer overflowed; %d earlier lines lost — see the game console)" % -start)
		start = 0
	for i in range(start, lines.size()):
		if not lines[i].begins_with("[ERROR] "):
			continue
		if out.size() >= MCPBridgeExec.EXEC_MAX_ERROR_LINES:
			out.append("... (more errors truncated; see the game console)")
			break
		out.append(lines[i].substr(8))
	return out


class _MCPGameLogger extends Logger:
	var _output: PackedStringArray = []
	var _max_lines := 1000
	# Lines trimmed off the front of the ring buffer, ever. Lets a caller hold a
	# STABLE mark (dropped + size) across trims instead of a raw index that
	# silently drifts when the buffer overflows (exec's runtime-error window).
	var _dropped := 0
	var _mutex := Mutex.new()

	func _log_message(message: String, error: bool) -> void:
		_mutex.lock()
		var prefix := "[ERROR] " if error else ""
		_output.append(prefix + message)
		if _output.size() > _max_lines:
			_output.remove_at(0)
			_dropped += 1
		_mutex.unlock()

	func _log_error(function: String, file: String, line: int, code: String,
					rationale: String, editor_notify: bool, error_type: int,
					script_backtraces: Array[ScriptBacktrace]) -> void:
		_mutex.lock()
		var msg := "[%s:%d] %s: %s" % [file.get_file(), line, code, rationale]
		_output.append("[ERROR] " + msg)
		if _output.size() > _max_lines:
			_output.remove_at(0)
			_dropped += 1
		_mutex.unlock()

	func get_output() -> PackedStringArray:
		return _output

	func get_dropped() -> int:
		return _dropped
