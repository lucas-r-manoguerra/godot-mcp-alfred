extends RefCounted
class_name MCPBridgePredicate

## Contexto de predicados e informes del bridge (step_until, report).
## Sin acceso al motor salvo a través del bridge propietario (`b`).
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

var b: MCPGameBridge

# Keep the server-side scope descriptions (game-time.ts, input.ts) in sync.
var EXPRESSION_SINGLETONS: Array = [
	["Engine", Engine], ["Time", Time], ["Performance", Performance],
	["AudioServer", AudioServer], ["Input", Input], ["DisplayServer", DisplayServer],
	["OS", OS],
]


func _build_predicate_context() -> Dictionary:
	# Exposes the running game to a step_until predicate: every autoload by its
	# own name (so `G.wave > 1` just works), plus `tree` (SceneTree) and `root`
	# (root Window) for tree queries like
	# `tree.get_nodes_in_group("enemies").size() >= 1`. Chained calls must run on
	# these input objects, not the Expression base instance, so they are inputs.
	var names: Array = []
	var inputs: Array = []
	var tree := b.get_tree()
	for prop in ProjectSettings.get_property_list():
		var key: String = prop.get("name", "")
		if not key.begins_with("autoload/"):
			continue
		var autoload_name := key.substr("autoload/".length())
		var node := tree.root.get_node_or_null(NodePath(autoload_name))
		if node == null or node == b:
			continue  # skip the bridge's own autoload and any unresolved entry
		names.append(autoload_name)
		inputs.append(node)
	if not names.has("tree"):
		names.append("tree")
		inputs.append(tree)
	if not names.has("root"):
		names.append("root")
		inputs.append(tree.root)
	# Engine singletons (#354): Expression cannot see globals, so
	# `Engine.get_frames_per_second()` or `Time.get_ticks_msec()` only work
	# when they ride in as named inputs like everything else. An autoload
	# that shadows one of these names keeps its slot.
	for entry in EXPRESSION_SINGLETONS:
		var sname: String = entry[0]
		if names.has(sname):
			continue
		names.append(sname)
		inputs.append(entry[1])
	return {"names": PackedStringArray(names), "inputs": inputs}


func _sanitize_value(v: Variant) -> Variant:
	# Report values ride back over the debugger channel. Pass primitives through;
	# never try to serialize Objects/containers — a short string stand-in is
	# enough for the agent to see what an expression evaluated to.
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return v
		_:
			return str(v).substr(0, 200)


func _compile_report(report: Array, names: PackedStringArray, inputs: Array) -> Dictionary:
	# Parse each report expression in the predicate context. Returns
	# {"error": ...} if any fails to parse, else {"report": [{src, expr}, ...]}.
	# Deliberately NOT dry-run executed (#353): the state a report reads is
	# often created by the step itself (a spawned node), so evaluating against
	# the pre-step tree would reject exactly the expressions report is for.
	# Evaluation failures surface per expression at stop time instead.
	var compiled: Array = []
	for item in report:
		var s := str(item).strip_edges()
		if s.is_empty():
			continue
		var e := Expression.new()
		if e.parse(s, names) != OK:
			return {"error": "report expression parse error (%s): %s" % [s, e.get_error_text()]}
		compiled.append({"src": s, "expr": e})
	return {"report": compiled}


func _evaluate_report(report_exprs: Array, inputs: Array) -> Dictionary:
	# Evaluate the compiled report expressions at stop time into {src: value}.
	# An expression that fails maps to {"error": message} rather than failing
	# the call, so the readings that did work still come back.
	var out: Dictionary = {}
	for item in report_exprs:
		var e: Expression = item["expr"]
		# Base instance is the bridge itself, exactly as before the split.
		var v: Variant = e.execute(inputs, b)
		if e.has_execute_failed():
			out[item["src"]] = {"error": e.get_error_text()}
		else:
			out[item["src"]] = _sanitize_value(v)
	return out
