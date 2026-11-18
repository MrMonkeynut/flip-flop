extends Node
## Reads ONE controller for the local player.
##
## Controller layout:
##   Left stick            -> left hand          (or left foot while L2 is held)
##   Right stick           -> right hand         (or right foot while R2 is held)
##   L1 / R1               -> grab with left / right hand (hold)
##   L2 / R2               -> switch that stick to the matching foot (lifts it)
##   D-pad left / right    -> rotate camera
##   Back / Share          -> respawn
##   Start / Options       -> toggle controls help
## Keyboard fallback (debugging only): WASD / IJKL hands, Q / U grab, E / O feet,
## Z / X camera, R respawn, H help.
##
## Godot's input actions listen to every connected controller at once. That goes wrong
## when Steam Input or DS4Windows is running, because a PS4 pad then shows up twice (the
## real pad plus a virtual Xbox pad) and the two disagree. So the game only listens to the
## controller you last pressed a button on.
##
## It also patches the button layout of PlayStation pads that Godot doesn't recognise
## (common over Bluetooth and with third-party pads). Without that, the raw axes are in
## a different order: the right stick reads as R2 and R2 reads as L2, so feet lift on their own.

const STICK_DEADZONE := 0.18
const TRIGGER_THRESHOLD := 0.35

# SDL-format layouts for a DualShock 4 when Godot doesn't know the pad.
const DS4_LAYOUT_WINDOWS_MAC := "a:b1,b:b2,x:b0,y:b3,back:b8,start:b9,guide:b12,leftshoulder:b4,rightshoulder:b5,leftstick:b10,rightstick:b11,leftx:a0,lefty:a1,rightx:a2,righty:a5,lefttrigger:a3,righttrigger:a4,dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8"
const DS4_LAYOUT_LINUX := "a:b0,b:b1,x:b3,y:b2,back:b8,start:b9,guide:b10,leftshoulder:b4,rightshoulder:b5,leftstick:b11,rightstick:b12,leftx:a0,lefty:a1,rightx:a3,righty:a4,lefttrigger:a2,righttrigger:a5,dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8"

## The controller we listen to (-1 = none, keyboard only).
var device := -1
## Human-readable notes about layout fixes, shown by the input debugger.
var notes: Array[String] = []

var _prev_buttons := {} # JoyButton -> bool, for just_pressed()


func _ready() -> void:
	for dev in Input.get_connected_joypads():
		_patch_layout(dev)
	_pick_fallback_device()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


func _on_joy_connection_changed(dev: int, connected: bool) -> void:
	if connected:
		_patch_layout(dev)
		if device == -1:
			device = dev
	elif dev == device:
		device = -1
		_pick_fallback_device()


func _pick_fallback_device() -> void:
	if device != -1:
		return
	var pads := Input.get_connected_joypads()
	# Prefer a pad whose layout Godot knows.
	for dev in pads:
		if Input.is_joy_known(dev):
			device = dev
			return
	if not pads.is_empty():
		device = pads[0]


func _input(event: InputEvent) -> void:
	# Pressing a button on a controller makes it "the" controller.
	if event is InputEventJoypadButton and event.pressed and event.device != device:
		device = event.device


func _patch_layout(dev: int) -> void:
	if Input.is_joy_known(dev):
		return
	var pad_name := Input.get_joy_name(dev)
	var lower := pad_name.to_lower()
	var looks_like_ps := lower.contains("wireless controller") or lower.contains("ps4") \
		or lower.contains("dualshock") or lower.contains("playstation") or lower.contains("sony")
	if not looks_like_ps:
		notes.append("pad%d \"%s\" has an unknown layout, no fix available" % [dev, pad_name])
		return
	var layout := DS4_LAYOUT_LINUX if OS.get_name() == "Linux" else DS4_LAYOUT_WINDOWS_MAC
	Input.add_joy_mapping("%s,%s,%s" % [Input.get_joy_guid(dev), pad_name, layout], true)
	notes.append("pad%d \"%s\": applied PS4 layout fix (now %s)" % [
		dev, pad_name, "known" if Input.is_joy_known(dev) else "still unknown"])


# =======================================================================================
# Reading
# =======================================================================================

func left_stick() -> Vector2:
	return (_stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y) + _keys(KEY_A, KEY_D, KEY_S, KEY_W)).limit_length(1.0)


func right_stick() -> Vector2:
	return (_stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y) + _keys(KEY_J, KEY_L, KEY_K, KEY_I)).limit_length(1.0)


func left_trigger() -> bool:
	return _trigger(JOY_AXIS_TRIGGER_LEFT) or Input.is_physical_key_pressed(KEY_E)


func right_trigger() -> bool:
	return _trigger(JOY_AXIS_TRIGGER_RIGHT) or Input.is_physical_key_pressed(KEY_O)


func left_bumper() -> bool:
	return button(JOY_BUTTON_LEFT_SHOULDER) or Input.is_physical_key_pressed(KEY_Q)


func right_bumper() -> bool:
	return button(JOY_BUTTON_RIGHT_SHOULDER) or Input.is_physical_key_pressed(KEY_U)


func button(b: JoyButton) -> bool:
	return device != -1 and Input.is_joy_button_pressed(device, b)


## True only on the frame the button goes down. Call once per frame per button.
func just_pressed(b: JoyButton, key: Key) -> bool:
	var down := button(b) or Input.is_physical_key_pressed(key)
	var was: bool = _prev_buttons.get(b, false)
	_prev_buttons[b] = down
	return down and not was


func trigger_value(axis: JoyAxis) -> float:
	return Input.get_joy_axis(device, axis) if device != -1 else 0.0


func _stick(ax_x: JoyAxis, ax_y: JoyAxis) -> Vector2:
	if device == -1:
		return Vector2.ZERO
	# Stick up is negative on the raw axis; the game wants up = forward = positive.
	var v := Vector2(Input.get_joy_axis(device, ax_x), -Input.get_joy_axis(device, ax_y))
	var length := v.length()
	if length < STICK_DEADZONE:
		return Vector2.ZERO
	return v / length * minf((length - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 1.0)


func _trigger(axis: JoyAxis) -> bool:
	return device != -1 and Input.get_joy_axis(device, axis) > TRIGGER_THRESHOLD


func _keys(left: Key, right: Key, down: Key, up: Key) -> Vector2:
	var v := Vector2(
		float(Input.is_physical_key_pressed(right)) - float(Input.is_physical_key_pressed(left)),
		float(Input.is_physical_key_pressed(up)) - float(Input.is_physical_key_pressed(down)))
	return v.limit_length(1.0)
