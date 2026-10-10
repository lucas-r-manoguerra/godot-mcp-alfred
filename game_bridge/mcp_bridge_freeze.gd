extends RefCounted
class_name MCPBridgeFreeze

## Congelado del tiempo de juego (freeze / thaw / status) y monitor
## por cuadro. Extraído de mcp_game_bridge.gd sin cambios de protocolo.
##
## (Documentación del modelo de capas game_paused/frozen: ver el bloque
## de comentario original sobre _game_time_process en el bridge.)

var b: MCPGameBridge

const LAUNCH_FROZEN_ENV := "GODOT_MCP_LAUNCH_FROZEN"
# Timeout cascade (#276): the server derives the whole stagger from the call's
# in-game budget and pushes wall_budget_ms down here. The bridge returns by that
# wall budget, the editor relay waits a margin longer, the server socket a
# margin longer still — each answers before the one above gives up.
#   STEP_MAX_MS         non-binding sanity backstop (the server already clamps the request)
#   STEP_DEFAULT_MS     budget used when a call omits max_ms (older server that sends no default)
#   STEP_WALL_BUDGET_MS wall-budget fallback when the server pushes no wall_budget_ms
const STEP_MAX_MS := 300000
const STEP_DEFAULT_MS := 20000
const STEP_MAX_FRAMES := 1200
const STEP_WALL_BUDGET_MS := 25000
const STEP_MAX_TRANSITIONS := 50
const FREEZE_CONTESTED_THRESHOLD := 10

var _frozen := false
var _game_paused := false  # the game layer's own pause intent, inferred by observation
var _launched_frozen := false
var _freeze_started_ticks := 0
var _freeze_transition_count := 0


func _send_game_time_response(msg_type: String, result: Dictionary) -> void:
	EngineDebugger.send_message("godot_mcp:game_response", [msg_type, result])


func _engage_freeze() -> void:
	if _frozen:
		return
	var tree := b.get_tree()
	_game_paused = tree.paused
	_frozen = true
	_freeze_started_ticks = Time.get_ticks_msec()
	_freeze_transition_count = 0
	tree.paused = true
	b._update_processing()


# Per-frame monitor: dispatches to the step runner during a window, otherwise
# holds the freeze against game-code writes.
func _game_time_process(delta: float) -> void:
	if b._step._step_active:
		b._step._step_process(delta)
		return
	if not _frozen:
		return
	var tree := b.get_tree()
	if not tree.paused:
		# Game code unpaused under the freeze (a WHEN_PAUSED resume button, an
		# auto-unpausing cutscene). Record the game layer's new intent and
		# re-assert — the freeze answers to the agent; the game's wish is
		# restored on step/thaw. Only unpause flips are observable here: while
		# frozen, tree.paused is already true.
		_game_paused = false
		_freeze_transition_count += 1
		tree.paused = true


func _handle_game_time_freeze(_data: Array) -> void:
	if b._step._step_active:
		_send_game_time_response("game_time_freeze", {"error": "Step in progress"})
		return
	var was_frozen := _frozen
	_engage_freeze()
	_send_game_time_response("game_time_freeze", {
		"frozen": true,
		"was_frozen": was_frozen,
		"game_paused": _game_paused,
	})


func _handle_game_time_thaw(_data: Array) -> void:
	if b._step._step_active:
		_send_game_time_response("game_time_thaw", {"error": "Step in progress"})
		return
	var was_frozen := _frozen
	var result: Dictionary = {"frozen": false, "was_frozen": was_frozen}
	if was_frozen:
		# Real wall-clock the freeze was held; game time did not advance while frozen.
		result["frozen_wall_ms"] = Time.get_ticks_msec() - _freeze_started_ticks
		_frozen = false
		b.get_tree().paused = _game_paused
		b._update_processing()
	result["game_paused"] = _game_paused if was_frozen else b.get_tree().paused
	_send_game_time_response("game_time_thaw", result)


func _handle_game_time_status(_data: Array) -> void:
	var tree := b.get_tree()
	var tree_paused: bool = tree.paused if tree else false
	var result: Dictionary = {
		"frozen": _frozen,
		"game_paused": _game_paused if _frozen else tree_paused,
		"tree_paused": tree_paused,
		"engine_time_scale": Engine.time_scale,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
	}
	# `frozen` is the authoritative current state. `launched_frozen` is a historical
	# fact (this run booted frozen via GODOT_MCP_LAUNCH_FROZEN) and stays true after
	# thaw, so it must not be read as the present freeze state.
	if _launched_frozen:
		result["launched_frozen"] = true
	if _frozen:
		# Real wall-clock since freeze engaged, not game time (which is stopped).
		result["frozen_wall_ms"] = Time.get_ticks_msec() - _freeze_started_ticks
		result["freeze_transitions"] = _freeze_transition_count
		if _freeze_transition_count >= FREEZE_CONTESTED_THRESHOLD:
			# Something (an ALWAYS-mode node?) is repeatedly unpausing under
			# the freeze. Each re-assert can leak up to one frame; report the
			# contest rather than pretend the freeze is airtight.
			result["freeze_contested"] = true
	if b._step._step_active:
		result["step_active"] = true
	_send_game_time_response("game_time_status", result)
