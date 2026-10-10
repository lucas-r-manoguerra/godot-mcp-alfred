extends RefCounted
class_name MCPBridgeStep

## Ventanas de avance de tiempo de juego (step / step_until) con
## predicado, informe y línea de tiempo de entrada.
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

var b: MCPGameBridge

var _step_active := false
var _step_finish_pending := false
var _step_needs_settle := false
var _step_wall_exceeded := false
var _step_target_ms := 0.0
var _step_target_frames := 0
var _step_elapsed_ms := 0.0  # accumulated scaled delta = game time (wall-of-step, includes game-paused stretches)
var _step_gameplay_ms := 0.0  # the unpaused portion: what gameplay actually experienced
var _step_frames := 0
var _step_physics_ticks := 0
var _step_wall_start := 0
var _step_wall_budget_ms := MCPBridgeFreeze.STEP_WALL_BUDGET_MS  # set per-call from the server-pushed wall_budget_ms (#276)
var _step_events: Array = []  # in-step input timeline, scheduled on the game-time clock
var _step_events_fired := 0
var _step_transitions: Array = []
var _step_last_tree_paused := false

# step_until adds a predicate evaluated each frame. _step_predicate is null for a
# fixed-budget step, set for step_until; _step_response_type routes _finish_step's
# reply to the matching command (the relay correlates by message type). _step_report
# is the optional readings the agent wants back at stop time (in one round-trip,
# instead of a separate observation call), for both step kinds — each is
# [{src: String, expr: Expression}]; _step_predicate_inputs is their context.
var _step_predicate: Expression = null
var _step_predicate_inputs: Array = []
var _step_predicate_met := false
var _step_predicate_error := ""
var _step_report: Array = []
var _step_response_type := "game_time_step"
var _step_input_kinds: Dictionary = {}


## Public: true while a godot_game_time step / step_until window is advancing
## the tree, including the report evaluation at its end (#355). Game code that
## corrects itself against a wall-clock source (audio position, network time)
## should hold off while this is true, since wall time kept running through
## the freeze that preceded the step. Read it as
## `get_node("/root/MCPGameBridge").is_stepping()` (guard with
## has_node so the game runs without the addon). Frozen-but-not-stepping is
## just `get_tree().paused`.
func is_active() -> bool:
	return _step_active


func _physics_tick() -> void:
	if _step_active and not _step_finish_pending and not b.get_tree().paused:
		_step_physics_ticks += 1


func _handle_game_time_step(data: Array) -> void:
	var params: Dictionary = data[0] if data.size() > 0 and data[0] is Dictionary else {}
	if _step_active:
		b._freeze._send_game_time_response("game_time_step", {"error": "Step already in progress"})
		return

	# Reset the skew echo up front (see _handle_execute_input_sequence): the
	# step result's input_kinds must reflect this call, never a prior step's.
	_step_input_kinds = b._input_timeline._new_input_kinds()

	var duration_ms: int = int(params.get("duration_ms", 0))
	var frames: int = int(params.get("frames", 0))
	if duration_ms <= 0 and frames <= 0:
		b._freeze._send_game_time_response("game_time_step", {"error": "step requires duration_ms or frames"})
		return
	duration_ms = mini(duration_ms, MCPBridgeFreeze.STEP_MAX_MS)
	frames = mini(frames, MCPBridgeFreeze.STEP_MAX_FRAMES)

	# Validate and schedule the in-step input timeline (start_ms is game-time
	# from window start). Inputs must ride inside the step: an event injected
	# while frozen lands on a frame gameplay never processes, so its
	# is_action_just_pressed edge would be silently missed.
	var compiled := b._input_timeline._compile_input_events(params.get("inputs", []))
	if compiled.has("error"):
		b._freeze._send_game_time_response("game_time_step", {"error": compiled["error"]})
		return
	_step_input_kinds = compiled["kinds"]

	# Optional readings at stop time, same contract as step_until's report (#388):
	# parsed up front in the predicate context, evaluated on the window's last frame.
	var report_compiled: Array = []
	var report_inputs: Array = []
	if not (params.get("report", []) as Array).is_empty():
		var ctx := b._pred._build_predicate_context()
		var report_result := b._pred._compile_report(params.get("report", []), ctx["names"], ctx["inputs"])
		if report_result.has("error"):
			b._freeze._send_game_time_response("game_time_step", {"error": report_result["error"]})
			return
		report_compiled = report_result["report"]
		report_inputs = ctx["inputs"]

	# Step from a running game is allowed — it freezes first, so "advance
	# 500ms then wait for me" is a single atomic call.
	b._freeze._engage_freeze()

	_step_target_ms = float(duration_ms)
	_step_target_frames = frames
	_step_elapsed_ms = 0.0
	_step_gameplay_ms = 0.0
	_step_frames = 0
	_step_physics_ticks = 0
	_step_events = compiled["events"]
	_step_events_fired = 0
	_step_transitions = []
	_step_needs_settle = false
	_step_finish_pending = false
	_step_wall_exceeded = false
	_step_wall_start = Time.get_ticks_msec()
	_step_wall_budget_ms = int(params.get("wall_budget_ms", MCPBridgeFreeze.STEP_WALL_BUDGET_MS))
	_step_predicate = null
	_step_predicate_inputs = report_inputs
	_step_report = report_compiled
	_step_response_type = "game_time_step"
	_step_active = true

	# Open the window: restore the game layer's own pause wish for the
	# duration. If the game's menu is holding it paused, the window still
	# elapses (and reports gameplay_ms ~0) — never deadlock waiting for
	# gameplay time that cannot come.
	var tree := b.get_tree()
	tree.paused = b._freeze._game_paused
	_step_last_tree_paused = tree.paused
	b.set_physics_process(true)
	b._update_processing()


func _handle_game_time_step_until(data: Array) -> void:
	var params: Dictionary = data[0] if data.size() > 0 and data[0] is Dictionary else {}
	if _step_active:
		b._freeze._send_game_time_response("game_time_step_until", {"error": "Step already in progress"})
		return

	# Reset the skew echo up front (see _handle_execute_input_sequence).
	_step_input_kinds = b._input_timeline._new_input_kinds()

	var src: String = str(params.get("until", "")).strip_edges()
	if src.is_empty():
		b._freeze._send_game_time_response("game_time_step_until", {"error": "step_until requires a non-empty `until` expression"})
		return

	var max_ms: int = int(params.get("max_ms", MCPBridgeFreeze.STEP_DEFAULT_MS))
	if max_ms <= 0:
		max_ms = MCPBridgeFreeze.STEP_DEFAULT_MS
	max_ms = mini(max_ms, MCPBridgeFreeze.STEP_MAX_MS)

	# Compile and validate the predicate against the live tree before committing
	# to a step. Expression.parse() is lenient (a malformed string can parse
	# clean), so a dry-run execute is what actually catches unknown identifiers
	# and bad member access.
	var ctx := b._pred._build_predicate_context()
	var ctx_names: PackedStringArray = ctx["names"]
	var ctx_inputs: Array = ctx["inputs"]
	var expr := Expression.new()
	if expr.parse(src, ctx_names) != OK:
		b._freeze._send_game_time_response("game_time_step_until", {"error": "predicate parse error: %s" % expr.get_error_text()})
		return
	var first_value: Variant = expr.execute(ctx_inputs, b)
	if expr.has_execute_failed():
		b._freeze._send_game_time_response("game_time_step_until", {"error": "predicate failed to evaluate: %s" % expr.get_error_text()})
		return

	# Optional readings to return at stop time, validated up front in the same context.
	var report_result := b._pred._compile_report(params.get("report", []), ctx_names, ctx_inputs)
	if report_result.has("error"):
		b._freeze._send_game_time_response("game_time_step_until", {"error": report_result["error"]})
		return
	var report_compiled: Array = report_result["report"]

	var compiled := b._input_timeline._compile_input_events(params.get("inputs", []))
	if compiled.has("error"):
		b._freeze._send_game_time_response("game_time_step_until", {"error": compiled["error"]})
		return
	_step_input_kinds = compiled["kinds"]

	b._freeze._engage_freeze()

	# Predicate already holds: advance nothing, stay frozen, report it.
	# input_kinds still rides along — its absence is the version-skew signal a
	# new server reads, so every success shape must carry it.
	if bool(first_value):
		var sc_result: Dictionary = {
			"completed": true,
			"frozen": true,
			"elapsed_ms": 0,
			"gameplay_ms": 0,
			"frames": 0,
			"physics_ticks": 0,
			"game_paused": b._freeze._game_paused,
			"predicate_met": true,
			"input_kinds": _step_input_kinds,
		}
		if not report_compiled.is_empty():
			sc_result["report"] = b._pred._evaluate_report(report_compiled, ctx_inputs)
		b._freeze._send_game_time_response("game_time_step_until", sc_result)
		return

	_step_target_ms = float(max_ms)
	_step_target_frames = 0
	_step_elapsed_ms = 0.0
	_step_gameplay_ms = 0.0
	_step_frames = 0
	_step_physics_ticks = 0
	_step_events = compiled["events"]
	_step_events_fired = 0
	_step_transitions = []
	_step_needs_settle = false
	_step_finish_pending = false
	_step_wall_exceeded = false
	_step_wall_start = Time.get_ticks_msec()
	_step_wall_budget_ms = int(params.get("wall_budget_ms", MCPBridgeFreeze.STEP_WALL_BUDGET_MS))
	_step_predicate = expr
	_step_predicate_inputs = ctx_inputs
	_step_predicate_met = false
	_step_predicate_error = ""
	_step_report = report_compiled
	_step_response_type = "game_time_step_until"
	_step_active = true

	var tree := b.get_tree()
	tree.paused = b._freeze._game_paused
	_step_last_tree_paused = tree.paused
	b.set_physics_process(true)
	b._update_processing()


func _step_process(delta: float) -> void:
	var tree := b.get_tree()

	# The bridge processes before the scene, so a frame is counted here BEFORE
	# gameplay runs it. Ending the window therefore always defers one frame:
	# pausing in the same _process call would steal the frame just counted.
	if _step_finish_pending:
		_finish_step()
		return

	# Game-layer pause flips during the window are the game's own doing (a
	# stepped input opened the menu, an auto-pausing cutscene). Track intent
	# and report; never fight it mid-window.
	if tree.paused != _step_last_tree_paused:
		_step_last_tree_paused = tree.paused
		b._freeze._game_paused = tree.paused
		if _step_transitions.size() < MCPBridgeFreeze.STEP_MAX_TRANSITIONS:
			_step_transitions.append({"at_ms": roundi(_step_elapsed_ms), "paused": tree.paused})

	_step_frames += 1
	_step_elapsed_ms += delta * 1000.0
	if not tree.paused:
		_step_gameplay_ms += delta * 1000.0

	while _step_events.size() > 0 and _step_events[0].time <= _step_elapsed_ms:
		var ev: Dictionary = _step_events.pop_front()
		b._input_timeline._inject_timeline_event(ev)
		_step_events_fired += 1
		_step_needs_settle = true

	var done := false
	if _step_target_frames > 0:
		done = _step_frames >= _step_target_frames
	else:
		done = _step_elapsed_ms >= _step_target_ms

	# step_until: re-evaluate the predicate each frame against the advancing
	# game. A truthy result stops the window early; a runtime failure (e.g. a
	# watched node was freed mid-window) ends it honestly with the error attached.
	if _step_predicate != null:
		var v: Variant = _step_predicate.execute(_step_predicate_inputs, b)
		if _step_predicate.has_execute_failed():
			_step_predicate_error = _step_predicate.get_error_text()
			done = true
		elif bool(v):
			_step_predicate_met = true
			done = true

	if Time.get_ticks_msec() - _step_wall_start > _step_wall_budget_ms:
		# Slow-mo, Engine.time_scale = 0, or a pause-held window can starve
		# the game-time clock; the wall budget guarantees the call returns
		# (partial, honestly reported) before the editor relay gives up.
		_step_wall_exceeded = true
		done = true

	if done:
		if _step_needs_settle:
			# Injected events flush at the top of the NEXT frame; gameplay
			# needs that frame unpaused or the final just_pressed edge is
			# lost. Run exactly one settle frame, then finish.
			_step_needs_settle = false
		else:
			_step_finish_pending = true


func _finish_step() -> void:
	# Releases are guaranteed cleanup, never queued steps: no holds survive
	# across the freeze boundary (cross-step holds are a deliberate non-goal).
	var forced := b._input_timeline._held_count()
	b._input_timeline._release_held_actions()
	var dropped := _step_events.size()
	_step_events.clear()

	b.get_tree().paused = true  # the freeze layer re-engages
	_step_last_tree_paused = true

	# Read the report while is_stepping() is still true (#355): game code that
	# gates wall-clock resyncs on it must see the same answer during the last
	# processed frame and at report time.
	var report_values: Dictionary = {}
	if not _step_report.is_empty():
		report_values = b._pred._evaluate_report(_step_report, _step_predicate_inputs)

	_step_active = false
	_step_finish_pending = false
	b.set_physics_process(false)
	b._update_processing()

	var result: Dictionary = {
		"completed": true,
		"frozen": true,
		"elapsed_ms": roundi(_step_elapsed_ms),
		"gameplay_ms": roundi(_step_gameplay_ms),
		"frames": _step_frames,
		"physics_ticks": _step_physics_ticks,
		"game_paused": b._freeze._game_paused,
		"input_kinds": _step_input_kinds,
	}
	if _step_events_fired > 0:
		result["events_fired"] = _step_events_fired
	if forced > 0:
		result["forced_releases"] = forced
	if dropped > 0:
		result["events_dropped"] = dropped
	if not _step_transitions.is_empty():
		result["pause_transitions"] = _step_transitions
	if _step_wall_exceeded:
		result["wall_budget_exceeded"] = true
	# report carries the readings the agent asked for (the "what advanced" hint,
	# so it need not re-observe), for step and step_until alike (#388).
	if not _step_report.is_empty():
		result["report"] = report_values
	if _step_predicate != null:
		# step_until: predicate_met is the headline. A non-met return means the
		# cap or wall budget ran out first.
		result["predicate_met"] = _step_predicate_met
		if not _step_predicate_error.is_empty():
			result["predicate_error"] = _step_predicate_error

	# Route the reply to the originating command — the relay correlates by type.
	var response_type := _step_response_type
	_step_predicate = null
	_step_predicate_inputs = []
	_step_report = []
	b._freeze._send_game_time_response(response_type, result)
