extends RefCounted
class_name MCPBridgeEntity

## Extracción del estado por nodo para get_runtime_state: transform,
## velocidad, animación, UI, onscreen y _mcp_state()/snapshot.
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

const Onscreen := preload("onscreen.gd")

var b: MCPGameBridge

const _MCP_STATE_MAX_BYTES := 1024


# _mcp_state() contract: return a Dictionary with two categories —
#   (1) live runtime values that change during play (cursor pos, health, score, fill counts)
#   (2) static definition context needed to interpret them (puzzle clues, level layout, config)
# An agent can observe (1) without (2) but cannot verify correctness without both.
# Optionally include layout geometry (bounds, sizes) to enable programmatic layout checks.
# Error handling: _mcp_state() runtime errors are non-fatal in GDScript (Godot prints them
# and the call returns null); the `is Dictionary` check below handles that silently.
func _extract_node_state(node: Node, scene_root: Node, include_fields: Array,
		allow_var_snapshot: bool = false) -> Dictionary:
	var want := include_fields.is_empty()
	var want_transform := want or include_fields.has("transform")
	var want_velocity := want or include_fields.has("velocity")
	var want_anim := want or include_fields.has("anim")
	var want_groups := want or include_fields.has("groups")
	var want_onscreen := want or include_fields.has("onscreen")
	var want_state := want or include_fields.has("state")
	var want_ui := want or include_fields.has("ui")

	var entity: Dictionary = {
		"path": b.node_path_string(node, scene_root),
		"type": node.get_class(),
	}

	if want_groups:
		var groups := node.get_groups().filter(func(g): return not g.begins_with("_"))
		if not groups.is_empty():
			entity["groups"] = groups

	if want_transform and node is Node2D:
		var n2d := node as Node2D
		entity["pos"] = {"x": snapped(n2d.global_position.x, 0.01), "y": snapped(n2d.global_position.y, 0.01)}
		entity["rot"] = snapped(rad_to_deg(n2d.global_rotation), 0.01)
		if n2d.scale != Vector2.ONE:
			entity["scale"] = {"x": snapped(n2d.scale.x, 0.01), "y": snapped(n2d.scale.y, 0.01)}

	if want_transform and node is Node3D:
		var n3d := node as Node3D
		entity["pos"] = {
			"x": snapped(n3d.global_position.x, 0.01),
			"y": snapped(n3d.global_position.y, 0.01),
			"z": snapped(n3d.global_position.z, 0.01),
		}
		entity["rot"] = {
			"x": snapped(rad_to_deg(n3d.global_rotation.x), 0.01),
			"y": snapped(rad_to_deg(n3d.global_rotation.y), 0.01),
			"z": snapped(rad_to_deg(n3d.global_rotation.z), 0.01),
		}

	if want_velocity:
		if node is CharacterBody2D:
			var v := (node as CharacterBody2D).velocity
			entity["vel"] = {"x": snapped(v.x, 0.01), "y": snapped(v.y, 0.01)}
		elif node is RigidBody2D:
			var v := (node as RigidBody2D).linear_velocity
			entity["vel"] = {"x": snapped(v.x, 0.01), "y": snapped(v.y, 0.01)}
			entity["angvel"] = snapped((node as RigidBody2D).angular_velocity, 0.01)
		elif node is CharacterBody3D:
			var v := (node as CharacterBody3D).velocity
			entity["vel"] = {"x": snapped(v.x, 0.01), "y": snapped(v.y, 0.01), "z": snapped(v.z, 0.01)}
		elif node is RigidBody3D:
			var v := (node as RigidBody3D).linear_velocity
			entity["vel"] = {"x": snapped(v.x, 0.01), "y": snapped(v.y, 0.01), "z": snapped(v.z, 0.01)}
			var av := (node as RigidBody3D).angular_velocity
			entity["angvel"] = {"x": snapped(av.x, 0.01), "y": snapped(av.y, 0.01), "z": snapped(av.z, 0.01)}

	if want_anim:
		if node is AnimationPlayer:
			var ap := node as AnimationPlayer
			entity["anim"] = ap.current_animation
			entity["anim_pos"] = snapped(ap.current_animation_position, 0.01)
			entity["playing"] = ap.is_playing()
		elif node is AnimatedSprite2D:
			var asp := node as AnimatedSprite2D
			entity["anim"] = asp.animation
			entity["anim_frame"] = asp.frame

	if want_ui and node is Control:
		entity["ui"] = _control_ui_state(node as Control)

	if want_onscreen:
		# Resolve the camera from the node's own viewport (handles SubViewport
		# cameras) and use the correct geometry per dimension — 3D frustum, 2D
		# visible world rect. Returns null when undeterminable; omit the field.
		var onscreen = Onscreen.compute(node)
		if onscreen != null:
			entity["onscreen"] = onscreen

	if want_state:
		if node.has_method("_mcp_state"):
			var raw_state = node._mcp_state()
			if raw_state is Dictionary:
				var serialized := _serialize_mcp_state(raw_state)
				if not serialized.is_empty():
					entity["state"] = serialized
		elif allow_var_snapshot:
			var snap := _snapshot_script_vars(node)
			if not snap.is_empty():
				entity["state"] = snap

	return entity


# Layout-engine facts about a Control that only the running process can
# answer (#360): where it actually landed, whether it is shown, what it says,
# and whether it holds focus. `text` covers Label, Button, LineEdit,
# RichTextLabel and anything else exposing a String `text` property.
func _control_ui_state(c: Control) -> Dictionary:
	var r := c.get_global_rect()
	var ui: Dictionary = {
		"global_rect": {
			"x": snapped(r.position.x, 0.01), "y": snapped(r.position.y, 0.01),
			"w": snapped(r.size.x, 0.01), "h": snapped(r.size.y, 0.01),
		},
		"visible_in_tree": c.is_visible_in_tree(),
		"has_focus": c.has_focus(),
	}
	var text: Variant = c.get("text")
	if text is String:
		ui["text"] = (text as String).substr(0, 200)
	return ui


func _serialize_mcp_state(state: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in state:
		var val = state[key]
		var serializable = null
		match typeof(val):
			TYPE_BOOL, TYPE_STRING:
				serializable = val
			TYPE_INT:
				serializable = int(val)
			TYPE_FLOAT:
				serializable = snapped(float(val), 0.01)
			TYPE_ARRAY:
				serializable = val
			TYPE_DICTIONARY:
				serializable = val
			# skip non-serializable types (Objects, NodePaths, RIDs, etc.)
		if serializable == null:
			continue
		result[str(key)] = serializable
		if JSON.stringify(result).length() > _MCP_STATE_MAX_BYTES:
			result.erase(str(key))
			result["_truncated"] = true
			break
	return result


# Snapshot a node's own script variables (PROPERTY_USAGE_SCRIPT_VARIABLE) as
# JSON-able scalars/arrays. Used for explicitly-requested nodes (e.g. autoload
# singletons) that do not implement _mcp_state(). Private vars (leading "_") are
# skipped; dictionaries/objects/non-serializable values are dropped; total size
# is capped like _serialize_mcp_state.
func _snapshot_script_vars(node: Node) -> Dictionary:
	var result: Dictionary = {}
	for prop in node.get_property_list():
		if not (int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var key: String = str(prop.get("name", ""))
		if key.is_empty() or key.begins_with("_"):
			continue
		var serializable = _to_serializable_scalar(node.get(key))
		if serializable == null:
			continue
		result[key] = serializable
		if JSON.stringify(result).length() > _MCP_STATE_MAX_BYTES:
			result.erase(key)
			result["_truncated"] = true
			break
	return result


# Convert a value to a JSON-able scalar (or array of scalars). Returns null to
# signal "skip" — dictionaries, objects, vectors, and arrays containing any of
# those are intentionally dropped to keep the snapshot small and safe.
func _to_serializable_scalar(val) -> Variant:
	match typeof(val):
		TYPE_BOOL, TYPE_STRING:
			return val
		TYPE_STRING_NAME:
			return str(val)
		TYPE_INT:
			return int(val)
		TYPE_FLOAT:
			return snapped(float(val), 0.01)
		TYPE_ARRAY:
			var arr: Array = []
			for e in val:
				var s = _to_serializable_scalar(e)
				if s == null:
					return null
				arr.append(s)
			return arr
	return null
