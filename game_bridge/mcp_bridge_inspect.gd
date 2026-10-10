extends RefCounted
class_name MCPBridgeInspect

## Inspección del árbol en ejecución: find_nodes, métricas, profiler,
## procesos activos, señales y sniff de mallas.
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

const MeshValidator := preload("mesh_validator.gd")

var b: MCPGameBridge

# On-scene-load mesh-integrity sniff. Corrupt procedural meshes render with no
# error anywhere (inside-out winding, dropped triangles), so the warning must
# come TO the agent: the server appends these one-liners to screenshot results
# — the moment the agent looks at the game is the moment a wrong-looking render
# becomes actionable. Full diagnosis lives in the validate_meshes command.
const SNIFF_DELAY_FRAMES := 30  # let _ready-time procedural level builds finish
const SNIFF_MAX_WARNINGS := 8

var _sniff_scene_id: int = 0
var _sniff_countdown: int = -1


func _mesh_sniff_process() -> void:
	# The autoload ships in exports and _process runs even when _ready bailed
	# out early — without this gate, non-debug runs (including shipped games)
	# would pay full mesh-array copies on every scene load for a result
	# nothing consumes.
	if not EngineDebugger.is_active():
		return
	var tree := b.get_tree()
	if tree == null or tree.current_scene == null:
		return
	var sid := tree.current_scene.get_instance_id()
	if sid != _sniff_scene_id:
		_sniff_scene_id = sid
		_sniff_countdown = SNIFF_DELAY_FRAMES
	if _sniff_countdown > 0:
		_sniff_countdown -= 1
		if _sniff_countdown == 0:
			_run_mesh_sniff(tree.current_scene)


func _run_mesh_sniff(scene_root: Node) -> void:
	b._mesh_warnings.clear()
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.push_back(child)
		for w in MeshValidator.sniff(n):
			b._mesh_warnings.append(w)
			if b._mesh_warnings.size() >= SNIFF_MAX_WARNINGS:
				return


func _handle_validate_meshes(data: Array) -> void:
	var params: Dictionary = data[0] if data.size() > 0 and data[0] is Dictionary else {}
	var max_findings: int = params.get("max_findings", 25)
	var tree := b.get_tree()
	var result: Dictionary
	if tree == null or tree.current_scene == null:
		result = {"checked_meshes": 0, "checked_surfaces": 0, "total_findings": 0, "findings": [], "note": "no current scene"}
	else:
		result = MeshValidator.validate(tree.current_scene, max_findings)
	EngineDebugger.send_message("godot_mcp:game_response", ["validate_meshes", result])


func _get_node_from_path(path: String, scene_root: Node) -> Node:
	if path == "/" or path.is_empty():
		return scene_root

	if path.begins_with("/root/"):
		var parts := path.split("/")
		if parts.size() >= 3 and parts[2] == scene_root.name:
			var relative := "/".join(parts.slice(3))
			if relative.is_empty():
				return scene_root
			return scene_root.get_node_or_null(relative)

	if path.begins_with("/root/") or path == "/root":
		# Absolute path beside the scene: an autoload, the exec holder, etc. (#369)
		var tree := b.get_tree()
		return tree.root.get_node_or_null(path.trim_prefix("/root").trim_prefix("/")) if tree else null

	if path.begins_with("/"):
		path = path.substr(1)

	return scene_root.get_node_or_null(path)


func _handle_find_nodes(data: Array) -> void:
	var name_pattern: String = data[0] if data.size() > 0 else ""
	var type_filter: String = data[1] if data.size() > 1 else ""
	var root_path: String = data[2] if data.size() > 2 else ""

	var tree := b.get_tree()
	var scene_root := tree.current_scene if tree else null
	if not scene_root:
		EngineDebugger.send_message("godot_mcp:find_nodes_result", [[], 0, "No scene running"])
		return

	var search_root: Node = scene_root
	if not root_path.is_empty():
		search_root = _get_node_from_path(root_path, scene_root)
		if not search_root:
			EngineDebugger.send_message("godot_mcp:find_nodes_result", [[], 0, "Root not found: " + root_path])
			return

	var matches: Array = []
	_find_recursive(search_root, scene_root, name_pattern, type_filter, matches)
	EngineDebugger.send_message("godot_mcp:find_nodes_result", [matches, matches.size(), ""])


func _find_recursive(node: Node, scene_root: Node, name_pattern: String, type_filter: String, results: Array) -> void:
	var name_matches := name_pattern.is_empty() or node.name.matchn(name_pattern)
	var type_matches := type_filter.is_empty() or node.is_class(type_filter)

	if name_matches and type_matches:
		results.append({"path": b.node_path_string(node, scene_root), "type": node.get_class()})

	for child in node.get_children():
		_find_recursive(child, scene_root, name_pattern, type_filter, results)


func _handle_get_performance_metrics() -> void:
	var metrics := {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_time_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_time_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"navigation_time_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
		"render_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"render_draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"render_video_mem": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"render_texture_mem": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		"render_buffer_mem": int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)),
		"physics_2d_active_objects": int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"physics_2d_collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
		"physics_2d_island_count": int(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT)),
		"physics_3d_active_objects": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"physics_3d_collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		"physics_3d_island_count": int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		"audio_output_latency": Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY),
		"object_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"object_resource_count": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"object_node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"object_orphan_node_count": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"memory_static": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"memory_static_max": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"memory_msg_buffer_max": int(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX)),
		"navigation_active_maps": int(Performance.get_monitor(Performance.NAVIGATION_ACTIVE_MAPS)),
		"navigation_region_count": int(Performance.get_monitor(Performance.NAVIGATION_REGION_COUNT)),
		"navigation_agent_count": int(Performance.get_monitor(Performance.NAVIGATION_AGENT_COUNT)),
		"navigation_link_count": int(Performance.get_monitor(Performance.NAVIGATION_LINK_COUNT)),
		"navigation_polygon_count": int(Performance.get_monitor(Performance.NAVIGATION_POLYGON_COUNT)),
		"navigation_edge_count": int(Performance.get_monitor(Performance.NAVIGATION_EDGE_COUNT)),
		"navigation_edge_merge_count": int(Performance.get_monitor(Performance.NAVIGATION_EDGE_MERGE_COUNT)),
		"navigation_edge_connection_count": int(Performance.get_monitor(Performance.NAVIGATION_EDGE_CONNECTION_COUNT)),
		"navigation_edge_free_count": int(Performance.get_monitor(Performance.NAVIGATION_EDGE_FREE_COUNT)),
		"navigation_obstacle_count": int(Performance.get_monitor(Performance.NAVIGATION_OBSTACLE_COUNT)),
		"pipeline_compilations_canvas": int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS)),
		"pipeline_compilations_mesh": int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)),
		"pipeline_compilations_surface": int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)),
		"pipeline_compilations_draw": int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)),
		"pipeline_compilations_specialization": int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)),
	}

	var rid := b.get_viewport().get_viewport_rid()
	metrics["viewport_render_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.viewport_get_measured_render_time_gpu(rid)
	metrics["viewport_render_gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(rid)

	EngineDebugger.send_message("godot_mcp:performance_metrics_result", [metrics])


func _handle_get_profiler_data() -> void:
	var data := b._profiler.get_buffer_data() if b._profiler else {}
	EngineDebugger.send_message("godot_mcp:game_response", ["get_profiler_data", data])


func _handle_get_active_processes() -> void:
	var tree := b.get_tree()
	var scene_root := tree.current_scene if tree else null
	if not scene_root:
		EngineDebugger.send_message("godot_mcp:game_response", ["get_active_processes", {"processes": []}])
		return

	# Walk the whole tree, not just the scene: autoloads and exec-attached
	# nodes are exactly the per-frame cost sources a scene walk misses (#369).
	var script_map: Dictionary = {}
	for child in tree.root.get_children():
		if child == b:
			continue
		_collect_processes(child, scene_root, script_map)

	var processes: Array = []
	for script_path in script_map:
		processes.append(script_map[script_path])

	processes.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool:
		return a.instance_count > b2.instance_count
	)

	EngineDebugger.send_message("godot_mcp:game_response", ["get_active_processes", {"processes": processes}])


func _collect_processes(node: Node, scene_root: Node, script_map: Dictionary) -> void:
	var is_proc := node.is_processing()
	var is_phys := node.is_physics_processing()

	if is_proc or is_phys:
		var script_path := ""
		var script := node.get_script()
		if script and script is Script:
			script_path = script.resource_path
		if script_path.is_empty():
			script_path = node.get_class()

		if not script_map.has(script_path):
			script_map[script_path] = {
				"script_path": script_path,
				"has_process": false,
				"has_physics_process": false,
				"instance_count": 0,
				"example_paths": [],
				"locations": [],
			}

		var entry: Dictionary = script_map[script_path]
		if is_proc:
			entry.has_process = true
		if is_phys:
			entry.has_physics_process = true
		entry.instance_count += 1
		if entry.example_paths.size() < 3:
			entry.example_paths.append(b.node_path_string(node, scene_root))
		var loc := b._node_location(node, scene_root)
		if not entry.locations.has(loc):
			entry.locations.append(loc)

	for child in node.get_children():
		_collect_processes(child, scene_root, script_map)


func _handle_get_signal_connections(data: Array) -> void:
	var node_path: String = data[0] if data.size() > 0 else ""

	var tree := b.get_tree()
	var scene_root := tree.current_scene if tree else null
	if not scene_root:
		EngineDebugger.send_message("godot_mcp:game_response", ["get_signal_connections", {"connections": []}])
		return

	var connections: Array = []
	if node_path.is_empty():
		# Whole tree minus the bridge: an autoload's outgoing connections (a beat
		# clock driving scene nodes) are invisible to a scene-rooted walk (#369).
		for child in tree.root.get_children():
			if child == b:
				continue
			_collect_signal_connections(child, scene_root, connections, 0)
	else:
		var search_root := _get_node_from_path(node_path, scene_root)
		if not search_root:
			EngineDebugger.send_message("godot_mcp:game_response", ["get_signal_connections", {"connections": [], "error": "Node not found: " + node_path}])
			return
		_collect_signal_connections(search_root, scene_root, connections, 0)

	EngineDebugger.send_message("godot_mcp:game_response", ["get_signal_connections", {"connections": connections}])


const MAX_SIGNAL_CONNECTIONS := 200
const MAX_SIGNAL_DEPTH := 20


func _collect_signal_connections(node: Node, scene_root: Node, connections: Array, depth: int) -> void:
	if connections.size() >= MAX_SIGNAL_CONNECTIONS or depth > MAX_SIGNAL_DEPTH:
		return

	var source_path := b.node_path_string(node, scene_root)

	for sig_info in node.get_signal_list():
		var sig_name: String = sig_info.name
		for conn in node.get_signal_connection_list(sig_name):
			if connections.size() >= MAX_SIGNAL_CONNECTIONS:
				return
			var target: Object = conn.callable.get_object()
			var target_path := ""
			if target is Node:
				target_path = b.node_path_string(target as Node, scene_root)
			else:
				target_path = str(target)
			connections.append({
				"source_path": source_path,
				"signal_name": sig_name,
				"target_path": target_path,
				"method_name": conn.callable.get_method(),
			})

	for child in node.get_children():
		if connections.size() >= MAX_SIGNAL_CONNECTIONS:
			return
		_collect_signal_connections(child, scene_root, connections, depth + 1)
