extends RefCounted
class_name MCPBridgeInputTimeline

## Línea de tiempo de entrada tipada compartida por secuencias y pasos
## de tiempo de juego (#233/#290). Sin acceso al motor salvo vía `b`.
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

var b: MCPGameBridge

# Cap on the sub-events one mouse-look sweep entry expands into. Without it a
# max-span sweep (duration_ms 40000) would emit ceil(40000/16) ~= 2500 events for
# a single entry; 256 keeps ~16ms (60Hz) granularity up to ~4s and coarsens beyond
# that. The last chunk absorbs the remainder regardless of n, so the summed delta
# is unchanged — only temporal smoothness past the cap degrades.
const LOOK_MAX_SUBEVENTS := 256

# Actions whose press has been injected but whose paired release has not yet
# fired. Used to guarantee a release even if the queue is cleared mid-flight
# (new sequence) or the node leaves the tree — otherwise the dropped release
# latches the action "pressed" in the Input singleton (the stuck-held bug).
var _held_actions: Dictionary = {}
# Same guarantee for joypad state (#233): buttons whose press has fired
# (key "device:button") and axes whose last-set value is nonzero
# (key "device:axis") — a dropped end event would otherwise latch the polled
# Input singletons (is_joy_button_pressed / get_joy_axis) until game restart.
var _held_joy_buttons: Dictionary = {}
var _active_axes: Dictionary = {}
# Same guarantee for raw keys (#290), keyed by "physical:code". Refcounted: a
# combo presses each modifier as its own key, and overlapping entries can hold
# the same key more than once, so the entry tracks a press COUNT and the engine
# release only fires when it returns to zero. Stores primitives only ({count,
# physical, code, mask}) so the cleanup loop never touches a freed instance.
var _held_keys: Dictionary = {}


# Release any action/button/key still held and re-zero any active axis from an
# interrupted sequence. A release here is a guaranteed cleanup, never a queued
# step that a clear could drop. Safe to call when nothing is held.
func _release_held_actions() -> void:
	if _held_actions.is_empty() and _held_joy_buttons.is_empty() and _active_axes.is_empty() and _held_keys.is_empty():
		return
	for action in _held_actions.keys():
		var release := InputEventAction.new()
		release.action = action
		release.pressed = false
		release.strength = 0.0
		Input.parse_input_event(release)
	for bkey in _held_joy_buttons.keys():
		var binfo = _held_joy_buttons[bkey]
		var brel := InputEventJoypadButton.new()
		brel.device = int(binfo["device"])
		brel.button_index = int(binfo["button"]) as JoyButton
		brel.pressed = false
		Input.parse_input_event(brel)
	for akey in _active_axes.keys():
		var ainfo = _active_axes[akey]
		var azero := InputEventJoypadMotion.new()
		azero.device = int(ainfo["device"])
		azero.axis = int(ainfo["axis"]) as JoyAxis
		azero.axis_value = 0.0
		Input.parse_input_event(azero)
	for kkey in _held_keys.keys():
		var kinfo = _held_keys[kkey]
		Input.parse_input_event(_make_key_event(bool(kinfo["physical"]), int(kinfo["code"]), int(kinfo["mask"]), false))
	# Flush so the release takes effect immediately — _exit_tree may not get
	# another frame, and a cleanup should be deterministic, not deferred.
	Input.flush_buffered_events()
	_held_actions.clear()
	_held_joy_buttons.clear()
	_active_axes.clear()
	_held_keys.clear()


func _held_count() -> int:
	return _held_actions.size() + _held_joy_buttons.size() + _active_axes.size() + _held_keys.size()


func _new_input_kinds() -> Dictionary:
	# One source of truth for the input_kinds shape so every reset/result site
	# carries the same keys (#290 added "key", #294 added "look"). A missing key
	# here would make the server's skew check misfire against our own bridge.
	return {"action": 0, "joy_button": 0, "axis": 0, "key": 0, "look": 0}


func _compile_input_events(inputs: Array) -> Dictionary:
	# Builds the typed input timeline shared by input sequences and game-time
	# steps (#233/#290). Each entry is discriminated by which key it carries:
	# `axis` (analog joypad axis), `joy_button`, `key` (raw keyboard / modifier
	# combo), or `action_name` (with optional fractional `strength`). Returns
	# {"events": [...], "kinds": {...}} or {"error": ...} on an unknown
	# action/button/axis/key. Every event carries:
	#   time     - ms offset from sequence/window start
	#   phase    - 0 = release/zero-set, 1 = press/set (the equal-time tie-break)
	#   complete - completion credit, counted when the event fires (1 on ends)
	var events: Array = []
	var kinds := _new_input_kinds()
	for input in inputs:
		var start_ms: int = int(input.get("start_ms", 0))
		var dur: int = int(input.get("duration_ms", 0))
		# An instant tap (duration 0 — the schema default) must still emit its end
		# event STRICTLY AFTER its start, or the equal-time (time, phase) sort below
		# orders the release/zero-set before the press/set and the input latches
		# (press never paired with a release). One ms is enough: the time sort then
		# fires start-before-end even when both land in the same process frame.
		var end_ms: int = start_ms + maxi(dur, 1)
		if input.has("axis"):
			var axis := MCPJoyNames.axis_index(input["axis"])
			if axis < 0:
				return {"error": "Unknown joypad axis: %s (valid: %s)" % [str(input["axis"]), ", ".join(MCPJoyNames.AXES.keys())]}
			var device: int = int(input.get("device", 0))
			var value: float = clampf(float(input.get("value", 0.0)), -1.0, 1.0)
			kinds["axis"] += 1
			events.append({"time": start_ms, "phase": 1, "complete": 0,
				"kind": "axis", "axis": axis, "device": device, "value": value})
			events.append({"time": end_ms, "phase": 0, "complete": 1,
				"kind": "axis", "axis": axis, "device": device, "value": 0.0})
		elif input.has("joy_button"):
			var button := MCPJoyNames.button_index(input["joy_button"])
			if button < 0:
				return {"error": "Unknown joypad button: %s (valid: %s, or a raw index)" % [str(input["joy_button"]), ", ".join(MCPJoyNames.BUTTONS.keys())]}
			var bdevice: int = int(input.get("device", 0))
			kinds["joy_button"] += 1
			events.append({"time": start_ms, "phase": 1, "complete": 0,
				"kind": "joy_button", "button": button, "device": bdevice, "is_press": true})
			events.append({"time": end_ms, "phase": 0, "complete": 1,
				"kind": "joy_button", "button": button, "device": bdevice, "is_press": false})
		elif input.has("key"):
			var parsed := MCPKeyNames.parse(input["key"])
			var code: int = int(parsed["code"])
			if code == KEY_NONE:
				return {"error": "Unknown key: %s (e.g. \"a\", \"escape\", \"ctrl+s\", \"shift+f1\")" % str(input["key"])}
			var mask: int = int(parsed["mask"])
			var physical: bool = bool(input.get("physical", false))
			kinds["key"] += 1
			# Each modifier is pressed/released as its own real key so polled
			# is_key_pressed(KEY_CTRL) reads true (the modifier FLAG on another
			# event does not update that singleton). The base event also carries
			# the modifier flags so InputMap chords and _input handlers match.
			# Modifier keys are position-stable -> set both keycode+physical (mask
			# 0, an exact match for a bare-modifier binding); the base honors
			# `physical`. Completion credit (1) rides only the base release.
			var mod_keys := MCPKeyNames.modifier_key_indices(mask)
			for mk in mod_keys:
				events.append({"time": start_ms, "phase": 1, "complete": 0,
					"kind": "key", "code": int(mk), "physical": false, "mask": 0, "is_press": true})
			events.append({"time": start_ms, "phase": 1, "complete": 0,
				"kind": "key", "code": code, "physical": physical, "mask": mask, "is_press": true})
			events.append({"time": end_ms, "phase": 0, "complete": 1,
				"kind": "key", "code": code, "physical": physical, "mask": mask, "is_press": false})
			for mk in mod_keys:
				events.append({"time": end_ms, "phase": 0, "complete": 0,
					"kind": "key", "code": int(mk), "physical": false, "mask": 0, "is_press": false})
		elif input.has("look"):
			var look_val: Variant = input["look"]
			if not (look_val is Array) or (look_val as Array).size() != 2:
				return {"error": "look expects [dx, dy] (two numbers), got %s" % str(look_val)}
			# Validate element types before casting, matching every other kind's clean
			# error-dict contract: float() of a nested array throws an uncaught script
			# error, and float() of a bool/string would silently coerce to a wrong value.
			var lx: Variant = (look_val as Array)[0]
			var ly: Variant = (look_val as Array)[1]
			if not (lx is float or lx is int) or not (ly is float or ly is int):
				return {"error": "look expects [dx, dy] (two numbers), got %s" % str(look_val)}
			var dx: float = float(lx)
			var dy: float = float(ly)
			kinds["look"] += 1
			# Relative mouse-look is STATELESS (no hold/release/refcount): a snap-turn
			# (dur < 16) is ONE motion event carrying the whole delta; a longer sweep is
			# N = ceil(dur/16) motion events (~16ms/chunk = 60Hz, capped at
			# LOOK_MAX_SUBEVENTS) spaced across the window, each carrying delta/N. The
			# last chunk absorbs the float remainder so the chunks sum to the delta
			# (exact in float64; the delivered Vector2 is float32, so a very large sweep
			# drifts sub-pixel — imperceptible). Motion is additive, so if several
			# sub-events coalesce into one frame on a slow frame or a big step dt, the
			# summed delta is unchanged — only the temporal smoothness degrades.
			var n: int = clampi(int(ceil(float(dur) / 16.0)), 1, LOOK_MAX_SUBEVENTS)
			var chunk_x: float = dx / float(n)
			var chunk_y: float = dy / float(n)
			for i in n:
				var ex: float = chunk_x
				var ey: float = chunk_y
				if i == n - 1:
					ex = dx - chunk_x * float(n - 1)
					ey = dy - chunk_y * float(n - 1)
				events.append({"time": start_ms + (i * dur) / n, "phase": 1,
					"complete": (1 if i == n - 1 else 0), "kind": "look", "dx": ex, "dy": ey})
		else:
			var action_name: String = input.get("action_name", "")
			if action_name.is_empty():
				continue
			if not InputMap.has_action(action_name):
				return {"error": "Unknown action: %s" % action_name}
			var strength: float = clampf(float(input.get("strength", 1.0)), 0.0, 1.0)
			kinds["action"] += 1
			events.append({"time": start_ms, "phase": 1, "complete": 0,
				"kind": "action", "action": action_name, "strength": strength, "is_press": true})
			events.append({"time": end_ms, "phase": 0, "complete": 1,
				"kind": "action", "action": action_name, "strength": strength, "is_press": false})
	# Releases/zero-sets fire before presses/sets at equal time, so a same-time
	# axis zero can never clobber a follow-on set of the same axis.
	events.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool:
		if a.time != b2.time:
			return a.time < b2.time
		return a.phase < b2.phase
	)
	_cancel_redundant_axis_zeroes(events)
	return {"events": events, "kinds": kinds}


func _cancel_redundant_axis_zeroes(events: Array) -> void:
	# Abutting same-axis entries (sweep ramps) must not bounce through zero:
	# both the zero-set and the next set pop in the same frame's while-loop, so
	# sort order alone cannot hide the transient zero from InputMap edge
	# detection (is_action_just_released would fire mid-sweep). Drop a zero-set
	# that lands at the same time as a follow-on set of the same (device, axis),
	# moving its completion credit to the survivor so counts stay exact.
	# Actions and buttons are deliberately NOT cancelled: release+press at the
	# same ms is a legitimate double-tap edge.
	var i := 0
	while i < events.size():
		var ev: Dictionary = events[i]
		if ev.kind == "axis" and ev.phase == 0:
			var j := i + 1
			while j < events.size() and events[j].time == ev.time:
				var nx: Dictionary = events[j]
				if nx.kind == "axis" and nx.phase == 1 and nx.axis == ev.axis and nx.device == ev.device:
					nx.complete = int(nx.complete) + int(ev.complete)
					events.remove_at(i)
					i -= 1
					break
				j += 1
		i += 1


func _inject_timeline_event(ev: Dictionary) -> int:
	# Build and parse the engine event for one timeline entry, maintaining the
	# held-state registries that _release_held_actions uses for guaranteed
	# cleanup. Returns the event's completion credit. Joypad and key events drive
	# the polled Input singletons too (get_joy_axis / is_joy_button_pressed /
	# is_key_pressed): unlike the mouse cursor, parse_input_event updates that
	# state for any device id with no physical pad/keyboard required.
	match str(ev.kind):
		"action":
			var ae := InputEventAction.new()
			ae.action = ev.action
			ae.pressed = ev.is_press
			ae.strength = float(ev.strength) if ev.is_press else 0.0
			Input.parse_input_event(ae)
			if ev.is_press:
				_held_actions[ev.action] = true
			else:
				_held_actions.erase(ev.action)
		"joy_button":
			var be := InputEventJoypadButton.new()
			be.device = ev.device
			be.button_index = ev.button as JoyButton
			be.pressed = ev.is_press
			Input.parse_input_event(be)
			var bkey := "%d:%d" % [ev.device, ev.button]
			if ev.is_press:
				_held_joy_buttons[bkey] = {"device": ev.device, "button": ev.button}
			else:
				_held_joy_buttons.erase(bkey)
		"axis":
			var me := InputEventJoypadMotion.new()
			me.device = ev.device
			me.axis = ev.axis as JoyAxis
			me.axis_value = ev.value
			Input.parse_input_event(me)
			var akey := "%d:%d" % [ev.device, ev.axis]
			if absf(float(ev.value)) > 0.0001:
				_active_axes[akey] = {"device": ev.device, "axis": ev.axis}
			else:
				_active_axes.erase(akey)
		"key":
			var code: int = int(ev.code)
			var physical: bool = bool(ev.physical)
			var kkey := "%d:%d" % [int(physical), code]
			# Refcount: a combo presses each modifier as its own key, and
			# overlapping entries can hold the same key more than once. Drive the
			# engine only on the 0<->1 edge so an inner release never turns a
			# still-held key off (the early-release bug), and the registry mirrors
			# the real pressed state for guaranteed cleanup.
			# Keyed by (physical, code) only, NOT mask: two overlapping combos that
			# share a base key but differ in modifiers (e.g. ctrl+s and shift+s)
			# collapse to one entry, so the shared base event reflects the FIRST
			# combo's modifier flags. The polled key state stays correct (one key,
			# refcounted, no early release); only the base event's flags differ for
			# that exotic overlap. Keying by mask instead would split them and
			# reintroduce an early release of the shared base key — the worse bug.
			if ev.is_press:
				if _held_keys.has(kkey):
					_held_keys[kkey]["count"] = int(_held_keys[kkey]["count"]) + 1
				else:
					_held_keys[kkey] = {"count": 1, "physical": physical, "code": code, "mask": int(ev.mask)}
					Input.parse_input_event(_make_key_event(physical, code, int(ev.mask), true))
			elif _held_keys.has(kkey):
				var n := int(_held_keys[kkey]["count"]) - 1
				if n <= 0:
					_held_keys.erase(kkey)
					Input.parse_input_event(_make_key_event(physical, code, int(ev.mask), false))
				else:
					_held_keys[kkey]["count"] = n
		"look":
			# Relative mouse-look is stateless: each event delivers its delta to
			# _input/_unhandled_input and leaves NO held state to clean up (no
			# registry, no guaranteed release). Set both relative and screen_relative
			# to the delta — emulating a real mouse moving [dx,dy] SCREEN pixels: the
			# engine scales the DELIVERED event.relative by the viewport's input
			# transform on dispatch (identity for default/3D projects, so an FPS
			# camera integrates exactly [dx,dy]; a 2D content-scale stretch scales it,
			# as it would a physical mouse), while event.screen_relative stays the raw
			# delta. position is the current cursor spot for a well-formed event
			# (irrelevant under capture). The game owns mouse mode, not the bridge.
			var mm := InputEventMouseMotion.new()
			var delta := Vector2(float(ev.dx), float(ev.dy))
			mm.relative = delta
			mm.screen_relative = delta
			var vp := b.get_viewport()
			var pos := vp.get_mouse_position() if vp != null else Vector2.ZERO
			mm.position = pos
			mm.global_position = pos
			Input.parse_input_event(mm)
	return int(ev.get("complete", 0))


# Build an InputEventKey. A logical key sets both keycode and physical_keycode
# (a realistic US-layout event that drives is_key_pressed AND is_physical_key_pressed
# plus either binding kind); physical:true sends a physical-only event (keycode
# unset) for layout-independent / physical-keycode-binding testing.
func _make_key_event(physical: bool, code: int, mask: int, pressed: bool) -> InputEventKey:
	var ke := InputEventKey.new()
	if physical:
		ke.physical_keycode = code as Key
	else:
		ke.keycode = code as Key
		ke.physical_keycode = code as Key
	_apply_key_modifiers(ke, mask)
	ke.pressed = pressed
	return ke


func _apply_key_modifiers(ke: InputEventKey, mask: int) -> void:
	ke.ctrl_pressed = (mask & int(KEY_MASK_CTRL)) != 0
	ke.shift_pressed = (mask & int(KEY_MASK_SHIFT)) != 0
	ke.alt_pressed = (mask & int(KEY_MASK_ALT)) != 0
	ke.meta_pressed = (mask & int(KEY_MASK_META)) != 0
