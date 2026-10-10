extends RefCounted
class_name MCPBridgeExec

## godot_exec: ejecuta GDScript del agente en este proceso (#243).
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

var b: MCPGameBridge

# Cap on runtime-error lines echoed back per exec — the full text stays in the
# game console either way.
const EXEC_MAX_ERROR_LINES := 20

# ── godot_exec: run agent-provided GDScript in this game process (#243) ───────
#
# One-shot scripts compile as the body of `_mcp_run(<bindings>)` (see
# MCPExecGuard.build_wrapper) and run synchronously right here. Persistent
# behaviors are nodes the script attaches under the `holder` binding — a child
# of /root, NOT of this bridge: bridge children inherit PROCESS_MODE_ALWAYS and
# would keep acting under a freeze, while a root child pauses with the tree
# (bots respect freeze/step) yet survives scene reloads. The game process dying
# on stop is the cleanup guarantee.


func _exec_params(data: Array) -> Dictionary:
	return data[0] if data.size() > 0 and data[0] is Dictionary else {}


# Responses correlate by message type alone in the editor plugin, so a late
# response from a timed-out call could be consumed as the answer to the NEXT
# call of the same type — wrong result, silently. Echoing the relay's call_id
# lets the relay discard mismatches. Absent when the relay pushed none (older
# server): the relay accepts unmatched responses then, so skew is safe both ways.
func _send_exec_response(msg_type: String, result: Dictionary, params: Dictionary) -> void:
	if params.has("call_id"):
		result["call_id"] = params["call_id"]
	EngineDebugger.send_message("godot_mcp:game_response", [msg_type, result])


func _build_exec_context() -> Dictionary:
	# The step_until predicate context (autoloads by name + tree/root), plus
	# `holder`. If a project defines an autoload literally named "holder", the
	# autoload keeps the name (a duplicate parameter would be a parse error);
	# the exec holder is still reachable as root.get_node("MCPExecHolder").
	var ctx := b._pred._build_predicate_context()
	var names: PackedStringArray = ctx["names"]
	var inputs: Array = ctx["inputs"]
	if not ("holder" in names):
		names.append("holder")
		inputs.append(b.ensure_exec_holder())
	return {"names": names, "inputs": inputs}


func _handle_exec_run(data: Array) -> void:
	var params := _exec_params(data)
	var source: String = str(params.get("source", ""))

	var scan := MCPExecGuard.scan_source(source)
	if not scan.get("ok", false):
		_send_exec_response("exec_run", {"error": str(scan.get("message", "exec source rejected"))}, params)
		return

	var ctx := _build_exec_context()
	var script := GDScript.new()
	script.source_code = MCPExecGuard.build_wrapper(source, ctx["names"])

	var mark := b._exec_logger_mark()
	if script.reload() != OK or not script.can_instantiate():
		var detail := "; ".join(PackedStringArray(b._exec_logger_delta(mark)))
		var msg := "exec compile error"
		if detail.is_empty():
			msg += " (parser text not captured; check the game console, e.g. minimal-godot-mcp get_console_output)"
		else:
			msg += ": " + detail
		_send_exec_response("exec_run", {"error": msg}, params)
		return

	var inst: Object = script.new()
	mark = b._exec_logger_mark()
	var t0 := Time.get_ticks_msec()
	# Synchronous and non-preemptible: an infinite loop here hangs the game (the
	# relay/server time out; godot_editor_edit stop kills the process). That is the
	# documented contract — no wall budget is pretended.
	var result: Variant = inst.callv("_mcp_run", ctx["inputs"])
	var duration := Time.get_ticks_msec() - t0

	# Runtime backstop for the scanner's SYNC_ONLY rule (a string-built await
	# can slip past a token scan): a suspended call returns a function state.
	if typeof(result) == TYPE_OBJECT and result != null \
			and result.get_class() == "GDScriptFunctionState":
		_send_exec_response("exec_run", {"error":
			"SCRIPT_SUSPENDED: the script hit an await and suspended (exec is synchronous-only; " +
			"side effects before the await have already run). Use godot_game_time step/step_until to wait."}, params)
		return

	var holder := b._exec_holder
	var out: Dictionary = {
		"completed": true,
		"result": b._pred._sanitize_value(result),
		"duration_ms": duration,
		"holder_children": holder.get_child_count() \
			if holder != null and is_instance_valid(holder) else 0,
	}
	var errs := b._exec_logger_delta(mark)
	if not errs.is_empty():
		out["runtime_errors"] = errs
	_send_exec_response("exec_run", out, params)


func _handle_exec_list(data: Array) -> void:
	var params := _exec_params(data)
	var nodes: Array = []
	var holder := b._exec_holder
	if holder != null and is_instance_valid(holder):
		var now := Time.get_ticks_msec()
		for child in holder.get_children():
			var script_chars := 0
			var s: Variant = child.get_script()
			if s is GDScript:
				script_chars = (s as GDScript).source_code.length()
			nodes.append({
				"name": str(child.name),
				"class": child.get_class(),
				"script_chars": script_chars,
				"age_ms": now - int(child.get_meta("mcp_exec_attached_ms", now)),
				# Internal processing too: Timers and tweened nodes drive
				# themselves internally and would otherwise read as idle.
				"processing": child.is_processing() or child.is_physics_processing() \
					or child.is_processing_internal() or child.is_physics_processing_internal(),
			})
	_send_exec_response("exec_list", {"nodes": nodes, "count": nodes.size()}, params)


func _handle_exec_remove(data: Array) -> void:
	var params := _exec_params(data)
	var node_name := str(params.get("name", ""))
	var holder := b._exec_holder
	var child: Node = null
	if holder != null and is_instance_valid(holder) and not node_name.is_empty():
		# Name EQUALITY against direct children — never a NodePath lookup: a
		# path-like name would traverse out of the holder (".." resolves to
		# /root, "a/b" to a grandchild) and queue_free whatever it lands on.
		for c in holder.get_children():
			if str(c.name) == node_name:
				child = c
				break
	if child == null:
		var have: Array = []
		if holder != null and is_instance_valid(holder):
			for c in holder.get_children():
				have.append(str(c.name))
		_send_exec_response("exec_remove", {"error":
			"NOT_FOUND: no exec node named '%s' (have: %s)" % [
				node_name, ", ".join(PackedStringArray(have)) if not have.is_empty() else "none"]}, params)
		return
	# Detach immediately so a list right after this call already shows it gone;
	# queue_free still frees the detached node at the end of the frame.
	holder.remove_child(child)
	child.queue_free()
	_send_exec_response("exec_remove", {
		"removed": true,
		"name": node_name,
		"remaining": holder.get_child_count(),
	}, params)


func _handle_exec_clear(data: Array) -> void:
	var params := _exec_params(data)
	var holder := b._exec_holder
	var removed := 0
	if holder != null and is_instance_valid(holder):
		for child in holder.get_children():
			holder.remove_child(child)
			child.queue_free()
			removed += 1
	_send_exec_response("exec_clear", {"removed_count": removed}, params)
