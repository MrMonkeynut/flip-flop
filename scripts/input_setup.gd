extends RefCounted
## Builds the input map in code so the controller layout lives in one readable place.
##
## Controller layout:
##   Left stick            -> left hand          (or left foot while L2 is held)
##   Right stick           -> right hand         (or right foot while R2 is held)
##   L1 / R1               -> grab with left / right hand (hold)
##   L2 / R2               -> switch that stick to the matching foot (lifts it)
##   D-pad left / right    -> rotate camera
##   Back / Select         -> respawn
##   Start                 -> toggle controls help
##
## Keyboard fallback exists only for debugging; the game is meant for a controller.

const STICK_DEADZONE := 0.18
const TRIGGER_DEADZONE := 0.35


static func setup() -> void:
	_axis("lh_left", JOY_AXIS_LEFT_X, -1.0, [KEY_A])
	_axis("lh_right", JOY_AXIS_LEFT_X, 1.0, [KEY_D])
	_axis("lh_fwd", JOY_AXIS_LEFT_Y, -1.0, [KEY_W])
	_axis("lh_back", JOY_AXIS_LEFT_Y, 1.0, [KEY_S])

	_axis("rh_left", JOY_AXIS_RIGHT_X, -1.0, [KEY_J])
	_axis("rh_right", JOY_AXIS_RIGHT_X, 1.0, [KEY_L])
	_axis("rh_fwd", JOY_AXIS_RIGHT_Y, -1.0, [KEY_I])
	_axis("rh_back", JOY_AXIS_RIGHT_Y, 1.0, [KEY_K])

	_axis("left_foot", JOY_AXIS_TRIGGER_LEFT, 1.0, [KEY_E], TRIGGER_DEADZONE)
	_axis("right_foot", JOY_AXIS_TRIGGER_RIGHT, 1.0, [KEY_O], TRIGGER_DEADZONE)

	_button("left_grab", JOY_BUTTON_LEFT_SHOULDER, [KEY_Q])
	_button("right_grab", JOY_BUTTON_RIGHT_SHOULDER, [KEY_U])

	_button("cam_left", JOY_BUTTON_DPAD_LEFT, [KEY_Z])
	_button("cam_right", JOY_BUTTON_DPAD_RIGHT, [KEY_X])
	_button("respawn", JOY_BUTTON_BACK, [KEY_R])
	_button("toggle_help", JOY_BUTTON_START, [KEY_H])


static func _ensure(action: String, deadzone: float) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, deadzone)


static func _axis(action: String, axis: JoyAxis, value: float, keys: Array, deadzone := STICK_DEADZONE) -> void:
	_ensure(action, deadzone)
	var ev := InputEventJoypadMotion.new()
	ev.device = -1
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)
	_add_keys(action, keys)


static func _button(action: String, button: JoyButton, keys: Array) -> void:
	_ensure(action, 0.5)
	var ev := InputEventJoypadButton.new()
	ev.device = -1
	ev.button_index = button
	InputMap.action_add_event(action, ev)
	_add_keys(action, keys)


static func _add_keys(action: String, keys: Array) -> void:
	for k in keys:
		var kev := InputEventKey.new()
		kev.physical_keycode = k
		InputMap.action_add_event(action, kev)
