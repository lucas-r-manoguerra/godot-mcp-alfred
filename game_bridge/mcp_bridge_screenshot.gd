extends RefCounted
class_name MCPBridgeScreenshot

## Captura de pantalla del viewport como PNG sin pérdida.
## Extraído de mcp_game_bridge.gd sin cambios de protocolo.

var b: MCPGameBridge

const DEFAULT_MAX_WIDTH := 1024


func _take_screenshot_deferred(data: Array) -> void:
	var max_width: int = data[0] if data.size() > 0 else DEFAULT_MAX_WIDTH
	await RenderingServer.frame_post_draw
	_capture_and_send_screenshot(max_width)


# Lossless PNG, not JPEG: image vision-token cost scales with resolution, not
# codec, so JPEG only traded fidelity (compression artifacts) for nothing. Width
# is downscaled to max_width to bound that resolution-driven cost.
func _capture_and_send_screenshot(max_width: int) -> void:
	var viewport := b.get_viewport()
	if viewport == null:
		_send_screenshot_error("NO_VIEWPORT", "Could not get game viewport")
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_screenshot_error("CAPTURE_FAILED", "Failed to capture image from viewport")
		return
	if max_width > 0 and image.get_width() > max_width:
		var scale_factor := float(max_width) / float(image.get_width())
		var new_height := int(image.get_height() * scale_factor)
		image.resize(max_width, new_height, Image.INTERPOLATE_LANCZOS)
	var png_buffer := image.save_png_to_buffer()
	var base64 := Marshalls.raw_to_base64(png_buffer)
	# Element 6 piggybacks the scene's cached mesh-integrity warnings: the
	# moment the agent LOOKS at a wrong-looking render is when they're
	# actionable, and riding the same message costs no extra round-trip and
	# cannot time out on version skew (older receivers ignore the element).
	EngineDebugger.send_message("godot_mcp:screenshot_result", [
		true,
		base64,
		image.get_width(),
		image.get_height(),
		"",
		b._mesh_warnings.duplicate()
	])


func _send_screenshot_error(code: String, message: String) -> void:
	EngineDebugger.send_message("godot_mcp:screenshot_result", [
		false,
		"",
		0,
		0,
		"%s: %s" % [code, message]
	])
