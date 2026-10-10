extends RefCounted
class_name MCPBridgeInputSequence

## Secuencias de entrada en tiempo real, mapa de entrada, type_text y
## capturas mid-sequence (#239/#240). Delega la compilación/inyección
## en MCPBridgeInputTimeline. Extraído sin cambios de protocolo.

var b: MCPGameBridge

# Builtin ui_* actions worth listing: the ones an agent can inject for menu
# navigation. Keep in sync with INJECTABLE_UI_ACTIONS in input_commands.gd so
# the game-sourced and project-sourced maps agree (#348).
const INJECTABLE_UI_ACTIONS: Array[String] = [
	"ui_up", "ui_down", "ui_left", "ui_right",
	"ui_accept", "ui_cancel", "ui_focus_next", "ui_focus_prev",
]

var _sequence_events: Array = []
var _sequence_start_time: int = 0
var _sequence_running: bool = false
var _actions_completed: int = 0
var _actions_total: int = 0
# Entry counts by kind ({action, joy_button, axis}) for the current sequence /
# step window. Echoed in results: its PRESENCE is the version-skew signal a new
# server uses to detect an old bridge that silently dropped joypad entries.
var _sequence_input_kinds: Dictionary = {}
# Game time (unpaused, scaled) accumulated across the sequence window — compared
# against wall time in the result to flag a sequence that ran under a pause/freeze.
var _sequence_gameplay_ms: float = 0.0
# Drain phase: after the timeline empties, hold for a few frames so an effect
# probe's `after` reflects the final input before the result is sent.
var _sequence_draining: bool = false
var _sequence_settle_remaining: int = 0
const SEQUENCE_SETTLE_FRAMES := 2
# Optional effect probe (#240): compiled GDScript expressions [{src, expr}]
# evaluated in the step_until predicate context, once before the first input and
# again after the last, to prove the sequence changed something.
var _sequence_report: Array = []
var _sequence_report_inputs: Array = []
var _sequence_report_before: Dictionary = {}
# Mid-sequence frame capture (#239): offsets (ms from start, sorted) still to be
# captured during the real-time run, the capture params, and the count of
# deferred captures not yet sent — the result is held until this reaches zero.
var _sequence_capture_offsets: Array = []
var _sequence_captures_pending: int = 0
var _sequence_capture_max_width: int = 640
const SEQUENCE_MAX_CAPTURES := 8
# Non-binding sanity backstop only (#276). The server derives the per-call
# timeout from the sequence span and rejects offsets beyond what the ceiling
# permits before they ever reach here, so this just guards a malformed direct
# message. Kept far above any server-permitted budget so it never silently
# clamps a legitimate offset (which would reintroduce the cross-layer drift
# that #276 removed).
const SEQUENCE_MAX_CAPTURE_OFFSET_MS := 300000


func _sequence_process(delta: float) -> void:
	if not _sequence_running:
		return

	var tree := b.get_tree()

	# Drain phase: the timeline is exhausted, but a requested effect probe still
	# needs its `after` reading. The bridge runs BEFORE the scene and injected
	# events flush at the top of the NEXT frame, so a snapshot taken the instant
	# the queue empties would precede gameplay processing the final input — a real
	# effect would read as a no-op. Let a couple of gameplay frames elapse first.
	if _sequence_draining:
		if tree and not tree.paused:
			_sequence_gameplay_ms += delta * 1000.0
		if _sequence_settle_remaining > 0:
			_sequence_settle_remaining -= 1
		# Finalize only once the settle frames have elapsed (so an effect probe's
		# `after` reflects the final input) AND every deferred frame capture has
		# been sent back.
		if _sequence_settle_remaining <= 0 and _sequence_captures_pending == 0:
			_emit_sequence_result()
		return

	# Game time the sequence actually advanced (unpaused, scaled) vs. wall time
	# is a no-setup no-op signal: a sequence that ran entirely under a pause or
	# freeze shows gameplay_ms ~= 0 against a full wall_ms.
	if tree and not tree.paused:
		_sequence_gameplay_ms += delta * 1000.0

	var elapsed := Time.get_ticks_msec() - _sequence_start_time

	while _sequence_events.size() > 0 and _sequence_events[0].time <= elapsed:
		var seq_event: Dictionary = _sequence_events.pop_front()
		_actions_completed += b._input_timeline._inject_timeline_event(seq_event)

	# Trigger any frame captures whose offset has arrived (#239). Capture is
	# deferred to frame_post_draw, so it completes a frame or two later; the
	# pending count keeps the result from being sent until every frame is in.
	while _sequence_capture_offsets.size() > 0 and int(_sequence_capture_offsets[0]) <= elapsed:
		var off: int = int(_sequence_capture_offsets.pop_front())
		_sequence_captures_pending += 1
		_capture_sequence_frame.call_deferred(off)

	# Done when both the input timeline and the capture schedule are exhausted;
	# captures scheduled past the last input keep the window open until their
	# offsets arrive.
	if _sequence_events.is_empty() and _sequence_capture_offsets.is_empty():
		if not _sequence_report.is_empty():
			# Defer so the effect probe's `after` reflects the final input.
			_sequence_draining = true
			_sequence_settle_remaining = SEQUENCE_SETTLE_FRAMES
		elif _sequence_captures_pending == 0:
			_emit_sequence_result()
		else:
			# No probe, but captures are still resolving — wait for them.
			_sequence_draining = true
			_sequence_settle_remaining = 0


# Assemble and send the input-sequence result, then reset probe state. Carries an
# effect signal (#240): always-on context (scene / pause / freeze / game-vs-wall
# time) plus, when the caller attached a `report`, the per-expression before->after
# delta and an `any_changed` summary — enough to tell "inputs changed the world"
# from "inputs fell into the void" in one round-trip.
func _emit_sequence_result() -> void:
	_sequence_running = false
	_sequence_draining = false
	b._update_processing()

	var tree := b.get_tree()
	var result: Dictionary = {
		"completed": true,
		"actions_executed": _actions_completed,
		"scene": tree.current_scene.scene_file_path if tree and tree.current_scene else "",
		"tree_paused": tree.paused if tree else false,
		"frozen": b._freeze._frozen,
		"gameplay_ms": roundi(_sequence_gameplay_ms),
		"wall_ms": Time.get_ticks_msec() - _sequence_start_time,
		"input_kinds": _sequence_input_kinds,
	}

	if not _sequence_report.is_empty():
		var after := b._pred._evaluate_report(_sequence_report, _sequence_report_inputs)
		result.merge(_compute_report_deltas(_sequence_report_before, after))

	_sequence_report = []
	_sequence_report_inputs = []
	_sequence_report_before = {}

	EngineDebugger.send_message("godot_mcp:input_sequence_result", [result])


# Pure before/after diff over the probe expressions: {report: {src: {before, after,
# changed}}, any_changed}. A missing `after` (expression started erroring) reads as
# null and so counts as changed — the world did move. Kept side-effect-free so the
# headless test can assert it directly.
func _compute_report_deltas(before: Dictionary, after: Dictionary) -> Dictionary:
	var deltas: Dictionary = {}
	var any_changed := false
	for src in before:
		var bv: Variant = before[src]
		var a: Variant = after.get(src, null)
		# Compare type first: `!=` across Variant types (a String reading that
		# turned into an {error} Dictionary) raises in GDScript 4 and would abort
		# the emit, leaving the caller to time out (#358).
		var changed: bool = typeof(a) != typeof(bv) or a != bv
		if changed:
			any_changed = true
		deltas[src] = {"before": bv, "after": a, "changed": changed}
	return {"report": deltas, "any_changed": any_changed}


# Capture one frame mid-sequence (#239) and stream it back on its own message.
# Deferred from _sequence_process to frame_post_draw so it reads the rendered
# frame nearest the requested offset; the actual elapsed offset is reported
# alongside so the agent knows exactly when each frame landed. Each capture rides
# its own message, and the count gates the result.
#
# Encoded as lossless PNG, deliberately not JPEG: vision-token cost is a function
# of resolution (≈ width*height/750), not of file size or codec, so JPEG would
# only add compression artifacts for zero token saving. The token lever is
# _sequence_capture_max_width (resolution); PNG just costs more transport bytes.
func _capture_sequence_frame(requested_offset_ms: int) -> void:
	await RenderingServer.frame_post_draw
	var actual_ms := Time.get_ticks_msec() - _sequence_start_time
	var viewport := b.get_viewport()
	if viewport == null:
		_send_sequence_capture(requested_offset_ms, actual_ms, false, "", 0, 0, "NO_VIEWPORT: could not get game viewport")
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_sequence_capture(requested_offset_ms, actual_ms, false, "", 0, 0, "CAPTURE_FAILED: could not read viewport image")
		return
	if _sequence_capture_max_width > 0 and image.get_width() > _sequence_capture_max_width:
		var scale_factor := float(_sequence_capture_max_width) / float(image.get_width())
		image.resize(_sequence_capture_max_width, int(image.get_height() * scale_factor), Image.INTERPOLATE_LANCZOS)
	var png_buffer := image.save_png_to_buffer()
	var base64 := Marshalls.raw_to_base64(png_buffer)
	_send_sequence_capture(requested_offset_ms, actual_ms, true, base64, image.get_width(), image.get_height(), "")


func _send_sequence_capture(requested_ms: int, actual_ms: int, ok: bool, base64: String, width: int, height: int, error: String) -> void:
	# Decrement first: the result is gated on this reaching zero, and a capture
	# that errors must still release its slot or the sequence would never finish.
	_sequence_captures_pending = maxi(0, _sequence_captures_pending - 1)
	EngineDebugger.send_message("godot_mcp:sequence_capture", [requested_ms, actual_ms, ok, base64, width, height, error])


func _handle_execute_input_sequence(data: Array) -> void:
	var inputs: Array = data[0] if data.size() > 0 else []
	var report: Array = data[1] if data.size() > 1 and data[1] is Array else []
	var screenshot_offsets: Array = data[2] if data.size() > 2 and data[2] is Array else []
	var cap_max_width: int = int(data[3]) if data.size() > 3 else 640

	# Reset the skew echo up front: the result's input_kinds must reflect THIS
	# call's compile, never a stale value from a prior sequence (its absence is
	# how a new server detects an old bridge — a stale dict would mask that).
	_sequence_input_kinds = b._input_timeline._new_input_kinds()

	if inputs.is_empty():
		EngineDebugger.send_message("godot_mcp:input_sequence_result", [{
			"error": "No inputs provided",
		}])
		return

	# Normalize the optional frame-capture schedule (#239): clamp each offset,
	# cap the count, and sort so _sequence_process can pop them in order.
	var capture_offsets: Array = []
	for o in screenshot_offsets:
		if capture_offsets.size() >= SEQUENCE_MAX_CAPTURES:
			break
		capture_offsets.append(clampi(int(o), 0, SEQUENCE_MAX_CAPTURE_OFFSET_MS))
	capture_offsets.sort()

	# Compile the optional effect probe up front, before touching any input state,
	# so a bad expression rejects the call cleanly (same contract as step_until's
	# report). Reuses the predicate context: autoloads by name, plus `tree`/`root`.
	var report_compiled: Array = []
	var report_inputs: Array = []
	if not report.is_empty():
		var ctx := b._pred._build_predicate_context()
		var rr := b._pred._compile_report(report, ctx["names"], ctx["inputs"])
		if rr.has("error"):
			EngineDebugger.send_message("godot_mcp:input_sequence_result", [{
				"error": rr["error"],
			}])
			return
		report_compiled = rr["report"]
		report_inputs = ctx["inputs"]

	# Release anything still held from a prior, interrupted sequence BEFORE
	# clearing the queue — otherwise that sequence's unfired releases are dropped
	# and its actions stay latched (stuck-held bug).
	b._input_timeline._release_held_actions()
	_sequence_events.clear()
	_actions_completed = 0
	_actions_total = inputs.size()
	_sequence_gameplay_ms = 0.0
	_sequence_draining = false
	_sequence_settle_remaining = 0
	# Clear probe and capture state up front so an early return below (unknown
	# action) cannot leave a stale report or capture schedule to be acted on
	# against an interrupted window. Both are re-armed once the timeline validates.
	_sequence_report = []
	_sequence_report_inputs = []
	_sequence_report_before = {}
	_sequence_capture_offsets = []
	_sequence_captures_pending = 0
	_sequence_capture_max_width = cap_max_width

	var compiled := b._input_timeline._compile_input_events(inputs)
	if compiled.has("error"):
		EngineDebugger.send_message("godot_mcp:input_sequence_result", [{
			"error": compiled["error"],
		}])
		return
	_sequence_events = compiled["events"]
	_sequence_input_kinds = compiled["kinds"]

	# Baseline the effect probe at the last possible moment before any input fires.
	_sequence_report = report_compiled
	_sequence_report_inputs = report_inputs
	_sequence_report_before = b._pred._evaluate_report(report_compiled, report_inputs) if not report_compiled.is_empty() else {}

	# Arm the capture schedule (validated and sorted above).
	_sequence_capture_offsets = capture_offsets

	_sequence_start_time = Time.get_ticks_msec()
	_sequence_running = true
	b._update_processing()


func _handle_type_text(data: Array) -> void:
	var text: String = data[0] if data.size() > 0 else ""
	var delay_ms: int = int(data[1]) if data.size() > 1 else 50
	var submit: bool = data[2] if data.size() > 2 else false

	if text.is_empty():
		EngineDebugger.send_message("godot_mcp:type_text_result", [{
			"error": "No text provided",
		}])
		return

	_type_text_async(text, delay_ms, submit)


func _type_text_async(text: String, delay_ms: int, submit: bool) -> void:
	for i in text.length():
		var char_code := text.unicode_at(i)

		var press := InputEventKey.new()
		press.keycode = char_code
		press.unicode = char_code
		press.pressed = true
		Input.parse_input_event(press)

		var release := InputEventKey.new()
		release.keycode = char_code
		release.unicode = char_code
		release.pressed = false
		Input.parse_input_event(release)

		if delay_ms > 0 and i < text.length() - 1:
			await b.get_tree().create_timer(delay_ms / 1000.0).timeout

	if submit:
		if delay_ms > 0:
			await b.get_tree().create_timer(delay_ms / 1000.0).timeout

		var enter_press := InputEventKey.new()
		enter_press.keycode = KEY_ENTER
		enter_press.physical_keycode = KEY_ENTER
		enter_press.pressed = true
		Input.parse_input_event(enter_press)

		var enter_release := InputEventKey.new()
		enter_release.keycode = KEY_ENTER
		enter_release.physical_keycode = KEY_ENTER
		enter_release.pressed = false
		Input.parse_input_event(enter_release)

	EngineDebugger.send_message("godot_mcp:type_text_result", [{
		"completed": true,
		"chars_typed": text.length(),
		"submitted": submit,
	}])


func _handle_get_input_map() -> void:
	var actions: Array = []
	for action_name in InputMap.get_actions():
		if action_name.begins_with("ui_") and not action_name in INJECTABLE_UI_ACTIONS:
			continue
		var events := InputMap.action_get_events(action_name)
		var event_strings: Array = []
		for event in events:
			event_strings.append(_event_to_string(event))
		actions.append({
			"name": action_name,
			"events": event_strings,
		})
	EngineDebugger.send_message("godot_mcp:input_map_result", [actions, ""])


func _event_to_string(event: InputEvent) -> String:
	if event is InputEventKey:
		return MCPKeyNames.event_string(event as InputEventKey)
	elif event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		match mouse_event.button_index:
			MOUSE_BUTTON_LEFT:
				return "Mouse Left"
			MOUSE_BUTTON_RIGHT:
				return "Mouse Right"
			MOUSE_BUTTON_MIDDLE:
				return "Mouse Middle"
			_:
				return "Mouse Button %d" % mouse_event.button_index
	elif event is InputEventJoypadButton:
		var joy_event := event as InputEventJoypadButton
		return "Joypad Button %d (%s)" % [joy_event.button_index, MCPJoyNames.button_name(joy_event.button_index)]
	elif event is InputEventJoypadMotion:
		# The signed axis_value is the direction bit an agent needs to lift the
		# binding straight into an injection (e.g. move_left = left_x, value -1.0).
		var joy_motion := event as InputEventJoypadMotion
		return "Joypad Axis %d (%s, value %+.1f)" % [joy_motion.axis, MCPJoyNames.axis_name(joy_motion.axis), joy_motion.axis_value]
	elif event is InputEventMouseMotion:
		var mouse_motion := event as InputEventMouseMotion
		return "Mouse Motion (rel %+.1f, %+.1f)" % [mouse_motion.relative.x, mouse_motion.relative.y]
	return event.as_text()
