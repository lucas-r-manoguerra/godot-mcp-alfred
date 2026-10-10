extends RefCounted
class_name MCPBridgeRuntimeState

## get_runtime_state y watch_* (sampler). La extracción por nodo vive
## en MCPBridgeEntity. Extraído sin cambios de protocolo.

var b: MCPGameBridge


func _handle_get_runtime_state(data: Array) -> void:
	var params: Dictionary = data[0] if data.size() > 0 and data[0] is Dictionary else {}

	var tree := b.get_tree()
	var scene_root := tree.current_scene if tree else null
	if not scene_root:
		EngineDebugger.send_message("godot_mcp:game_response", ["get_runtime_state", {
			"scene": "",
			"selection": "fallback",
			"entity_count": 0,
			"entities": [],
			"hint": "No scene is currently running.",
		}])
		return

	var select_mode: String = params.get("select", "auto")
	var group_name: String = params.get("group", "mcp_watch")
	var name_filter: String = params.get("name", "")
	var type_filter: String = params.get("type", "")
	var max_nodes: int = params.get("max_nodes", 40)
	var include_fields: Array = params.get("include", [])
	max_nodes = clampi(max_nodes, 1, 200)

	# Resolve a 2D camera for the optional camera entity. On-screen checks no
	# longer use this — they resolve the camera per-node from the node's own
	# viewport (see Onscreen.compute), which is what makes SubViewport cameras
	# work correctly.
	var camera_2d: Camera2D = _find_camera_2d()

	# Determine which selection tier to use
	var actual_selection: String = select_mode
	if select_mode == "visible":
		# Explicit request for the visibility tier (#360): reaches runtime-spawned
		# UI and world nodes even when an mcp_watch group or _mcp_state() exists.
		actual_selection = "fallback"
	elif select_mode == "auto":
		if _has_group_members(scene_root, group_name):
			actual_selection = "group"
		elif _has_mcp_state_nodes(scene_root):
			actual_selection = "method"
		else:
			actual_selection = "fallback"

	# Collect entities (skipped entirely when select="none" — explicit paths only)
	var entities: Array = []
	# Matches past the max_nodes cap are counted, not collected, so the
	# response can say how much was left out (#327).
	var walk_stats: Dictionary = {"matched": 0}
	if actual_selection != "none":
		_collect_runtime_state(scene_root, scene_root, actual_selection, group_name,
			name_filter, type_filter, include_fields,
			max_nodes, entities, walk_stats)
	var nodes_returned: int = entities.size()
	var nodes_total_matched: int = walk_stats["matched"]

	# Explicit paths: include nodes the scene walk cannot reach (e.g. autoload
	# singletons under /root). For each, return _mcp_state() if present, else a
	# snapshot of the node's script variables (scalars/arrays, capped). Deduped
	# against tier-selected entities and each other by absolute path.
	var explicit_paths: Array = params.get("paths", [])
	var unresolved_paths: Array = []
	if not explicit_paths.is_empty():
		var seen_paths := {}
		for e in entities:
			seen_paths[str(e.get("path", ""))] = true
		for p in explicit_paths:
			var pstr: String = str(p)
			var n := _resolve_node_abs(pstr)
			if n == null:
				unresolved_paths.append(pstr)
				continue
			var abs_path := str(n.get_path())
			if seen_paths.has(abs_path):
				continue
			seen_paths[abs_path] = true
			var ent := b._entity._extract_node_state(n, scene_root, include_fields, true)
			ent["path"] = abs_path
			entities.append(ent)

	# Extract camera entity separately if present
	var camera_entity = null
	if camera_2d:
		camera_entity = {
			"type": "Camera2D",
			"pos": {"x": snapped(camera_2d.global_position.x, 0.01), "y": snapped(camera_2d.global_position.y, 0.01)},
			"zoom": {"x": snapped(camera_2d.zoom.x, 0.01), "y": snapped(camera_2d.zoom.y, 0.01)},
			"camera": true,
		}

	var autoloads := _list_autoload_paths(scene_root)

	# Which Control has keyboard/controller focus, for UI navigation checks (#360).
	var focus_owner_path := ""
	var scene_viewport := scene_root.get_viewport()
	if scene_viewport != null:
		var focus_owner := scene_viewport.gui_get_focus_owner()
		if focus_owner != null:
			focus_owner_path = b.node_path_string(focus_owner, scene_root)

	var hint := ""
	if actual_selection == "fallback":
		hint = ("No nodes found in group '%s' and no _mcp_state() methods detected; " +
			"showing visible 2D and 3D world nodes (meshes, gridmaps, cameras, lights, " +
			"physics bodies and trigger areas, and visible CanvasItems). " +
			"For richer data: add key nodes to the '%s' group, then implement " +
			"`func _mcp_state() -> Dictionary` on them. " +
			"In _mcp_state(), include both live runtime values (position, health, score) " +
			"AND static definition context (puzzle clues, level config, item data) — " +
			"an agent needs both to understand and verify game state.") % [group_name, group_name]
		if not autoloads.is_empty():
			hint += (" Global game state often lives in autoload singletons (see " +
				"available_autoloads), which this scene walk does not reach — read them " +
				"with select=\"none\" and paths: [...]; each returns _mcp_state() if " +
				"present, else a snapshot of its script variables.")

	var result: Dictionary = {
		"scene": scene_root.scene_file_path,
		"selection": actual_selection,
		"entity_count": entities.size(),
		"entities": entities,
		"nodes_returned": nodes_returned,
		"nodes_total_matched": nodes_total_matched,
		"nodes_truncated": nodes_total_matched > nodes_returned,
	}
	if not autoloads.is_empty():
		result["available_autoloads"] = autoloads
	if camera_entity:
		result["camera"] = camera_entity
	if not focus_owner_path.is_empty():
		result["focus_owner"] = focus_owner_path
	if not hint.is_empty():
		result["hint"] = hint
	if not unresolved_paths.is_empty():
		result["unresolved_paths"] = unresolved_paths

	EngineDebugger.send_message("godot_mcp:game_response", ["get_runtime_state", result])


func _has_group_members(_scene_root: Node, group_name: String) -> bool:
	var tree := b.get_tree()
	if tree == null:
		return false
	return tree.get_nodes_in_group(group_name).size() > 0


func _has_mcp_state_nodes(node: Node) -> bool:
	if node.has_method("_mcp_state"):
		return true
	for child in node.get_children():
		if _has_mcp_state_nodes(child):
			return true
	return false


## Walks the tree collecting up to max_nodes matching entities into results.
## Every match is counted in stats["matched"] whether or not it fit under the
## cap, so callers can report truncation instead of presenting a partial list
## as the whole scene (#327). The walk keeps going past the cap purely to count.
func _collect_runtime_state(node: Node, scene_root: Node, selection: String, group_name: String,
		name_filter: String, type_filter: String, include_fields: Array,
		max_nodes: int, results: Array, stats: Dictionary = {}) -> void:
	if not stats.has("matched"):
		stats["matched"] = 0

	var include_node := false
	match selection:
		"group":
			include_node = node.is_in_group(group_name)
		"method":
			include_node = node.has_method("_mcp_state")
		"fallback":
			# Visible world nodes, by dimension. 2D = any visible CanvasItem.
			# 3D = a curated set of the entities an agent actually cares about:
			# rendered geometry (GeometryInstance3D covers MeshInstance3D,
			# MultiMeshInstance3D, GPUParticles3D, Sprite3D, Label3D, CSG, SoftBody3D)
			# plus Light3D (a VisualInstance3D, NOT a GeometryInstance3D, so named
			# separately). GeometryInstance3D is deliberately narrower than its parent
			# VisualInstance3D, which also drags in bake/helper nodes (ReflectionProbe,
			# VoxelGI, LightmapGI, OccluderInstance3D, Decal, FogVolume, particle
			# field nodes, VisibleOnScreenNotifier3D) — all default-visible noise that
			# would crowd the max_nodes budget. GridMap (extends Node3D directly, NOT a
			# VisualInstance3D) is checked by string because the gridmap module can be
			# compiled out independently — `is GridMap` would be an unresolved parse-time
			# identifier that fails the whole autoload in such a build. Camera3D (also a
			# bare Node3D), and physics bodies / trigger areas (CollisionObject3D — the
			# gameplay entities, e.g. an FPS's enemies and player) round out the set.
			# Pure-structure Node3Ds (Marker3D, Skeleton3D, bone attachments, audio
			# emitters, bare pivots) are skipped. This mirrors the 2D tier, where
			# CharacterBody2D is itself a CanvasItem and so already surfaces.
			if node is CanvasItem:
				include_node = (node as CanvasItem).is_visible_in_tree()
			elif node is Node3D:
				include_node = (node as Node3D).is_visible_in_tree() and (
					node is GeometryInstance3D
					or node is Light3D
					or node.is_class("GridMap")
					or node is Camera3D
					or node is CollisionObject3D)

	if include_node:
		if not name_filter.is_empty() and not node.name.matchn(name_filter):
			include_node = false
		if not type_filter.is_empty() and not node.is_class(type_filter):
			include_node = false

	if include_node:
		stats["matched"] += 1
		if results.size() < max_nodes:
			var entity := b._entity._extract_node_state(node, scene_root, include_fields)
			if entity != null:
				results.append(entity)

	for child in node.get_children():
		_collect_runtime_state(child, scene_root, selection, group_name,
			name_filter, type_filter, include_fields,
			max_nodes, results, stats)


# Resolve an absolute ("/root/Name/...") or scene-relative node path. Unlike the
# digest tree walk (rooted at current_scene), this reaches autoload singletons
# and anything else under the SceneTree root.
func _resolve_node_abs(path: String) -> Node:
	var tree := b.get_tree()
	if tree == null:
		return null
	var root := tree.root
	if root == null:
		return null
	if path == "/root" or path == "/root/":
		return root
	if path.begins_with("/root/"):
		return root.get_node_or_null(path.substr(6))
	if path.begins_with("/"):
		return root.get_node_or_null(path.substr(1))
	var scene_root := tree.current_scene
	return scene_root.get_node_or_null(path) if scene_root else null


# List autoload singleton paths (direct children of /root, excluding the current
# scene and this bridge node). Used to guide callers to global state the scene
# walk cannot reach.
func _list_autoload_paths(scene_root: Node) -> Array:
	var out: Array = []
	var tree := b.get_tree()
	if tree == null or tree.root == null:
		return out
	for child in tree.root.get_children():
		if child == scene_root or child == b or child == b._exec_holder:
			continue
		out.append("/root/" + str(child.name))
	return out


func _find_camera_2d() -> Camera2D:
	var viewport := b.get_viewport()
	if viewport == null:
		return null
	return viewport.get_camera_2d()


func _handle_watch_start(data: Array) -> void:
	if b._sampler == null:
		EngineDebugger.send_message("godot_mcp:game_response", ["watch_start", {"started": false, "error": "Sampler not initialized"}])
		return
	var specs: Array = data[0] if data.size() > 0 else []
	var hz: int = data[1] if data.size() > 1 else 20
	var duration_ms: int = data[2] if data.size() > 2 else 1000
	var signal_specs: Array = data[3] if data.size() > 3 else []
	var start_result := b._sampler.start(specs, hz, duration_ms, signal_specs)
	EngineDebugger.send_message("godot_mcp:game_response", ["watch_start", {
		"started": true,
		"resolved_fields": start_result.get("resolved_fields", 0),
		"unresolved_fields": start_result.get("unresolved_fields", []),
		"connected_signals": start_result.get("connected_signals", 0),
		"unresolved_signals": start_result.get("unresolved_signals", []),
	}])


func _handle_watch_collect() -> void:
	if b._sampler == null:
		EngineDebugger.send_message("godot_mcp:game_response", ["watch_collect", {"window_ms": 0, "sample_count": 0, "fields": {}, "events": [], "events_truncated": false}])
		return
	EngineDebugger.send_message("godot_mcp:game_response", ["watch_collect", b._sampler.collect()])


func _handle_watch_stop() -> void:
	if b._sampler == null:
		EngineDebugger.send_message("godot_mcp:game_response", ["watch_stop", {"window_ms": 0, "sample_count": 0, "fields": {}, "events": [], "events_truncated": false}])
		return
	EngineDebugger.send_message("godot_mcp:game_response", ["watch_stop", b._sampler.stop()])
