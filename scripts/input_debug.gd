extends CanvasLayer
## On-screen input debugger. Toggle with F3.
##
## Shows every connected controller (and whether Godot recognises its layout), the live
## value of every axis, a log of every button / axis / key / game action as it happens,
## and what the local character's feet are doing. Everything logged is also printed to
## the Output panel / console.

const LOG_LINES := 18
const AXIS_LOG_THRESHOLD := 0.5
const ACTIONS := [
	"lh_left", "lh_right", "lh_fwd", "lh_back",
	"rh_left", "rh_right", "rh_fwd", "rh_back",
	"left_grab", "right_grab", "left_foot", "right_foot",
	"cam_left", "cam_right", "respawn", "toggle_help",
]
const BUTTON_NAMES := [
	"A/Cross", "B/Circle", "X/Square", "Y/Triangle", "Back", "Guide", "Start",
	"L3", "R3", "L1", "R1", "DpadUp", "DpadDown", "DpadLeft", "DpadRight", "Misc",
	"Paddle1", "Paddle2", "Paddle3", "Paddle4", "Touchpad",
]
const AXIS_NAMES := ["LX", "LY", "RX", "RY", "L2", "R2"]

var main = null # set by main.gd; used to read the local player's state

var _panel: PanelContainer
var _label: Label
var _log: Array[String] = []
var _axis_active := {} # "device:axis" -> bool
var _action_state := {} # action -> bool


func _ready() -> void:
	layer = 50
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.offset_right = -12
	_panel.offset_top = 12
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_label = Label.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Consolas", "Menlo", "DejaVu Sans Mono", "Courier New", "monospace"])
	_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
	_panel.add_child(_label)

	for a in ACTIONS:
		_action_state[a] = false
	_add_log("Input debug on (F3 to hide)")
	for dev in Input.get_connected_joypads():
		_log_pad_info(dev, "found")
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		_log_pad_info(device, "CONNECTED")
	else:
		_add_log("pad%d DISCONNECTED" % device)


func _log_pad_info(dev: int, what: String) -> void:
	_add_log("pad%d %s: \"%s\" %s" % [dev, what, Input.get_joy_name(dev),
		"(known layout)" if Input.is_joy_known(dev) else "(UNKNOWN layout - axes may be mixed up!)"])


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_panel.visible = not _panel.visible
		return

	if event is InputEventJoypadButton:
		var b: int = event.button_index
		var bname: String = BUTTON_NAMES[b] if b >= 0 and b < BUTTON_NAMES.size() else "?"
		_add_log("pad%d button %d %-10s %s" % [event.device, b, bname, "DOWN" if event.pressed else "up"])
	elif event is InputEventJoypadMotion:
		var key := "%d:%d" % [event.device, event.axis]
		var active := absf(event.axis_value) > AXIS_LOG_THRESHOLD
		if active != bool(_axis_active.get(key, false)):
			_axis_active[key] = active
			_add_log("pad%d axis %d %-3s %s %+.2f" % [event.device, event.axis, _axis_name(event.axis),
				"PUSHED " if active else "centred", event.axis_value])
	elif event is InputEventKey and not event.echo:
		_add_log("key %s %s" % [OS.get_keycode_string(event.physical_keycode), "DOWN" if event.pressed else "up"])


func _process(_delta: float) -> void:
	# Log game actions turning on/off - this is what the game actually reacts to.
	for a in ACTIONS:
		var on := Input.is_action_pressed(a)
		if on != bool(_action_state[a]):
			_action_state[a] = on
			_add_log(">> action %-11s %s" % [a, "ON" if on else "off"])

	if not _panel.visible:
		return
	var lines: Array[String] = []
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		lines.append("NO CONTROLLER CONNECTED")
	for dev in pads:
		lines.append("pad%d \"%s\" %s" % [dev, Input.get_joy_name(dev), "known" if Input.is_joy_known(dev) else "UNKNOWN LAYOUT"])
		var axes := ""
		for ax in 6:
			axes += "%s%+.2f " % [_axis_name(ax), Input.get_joy_axis(dev, ax)]
		lines.append("  " + axes)
		var extra := ""
		for ax in range(6, 10):
			var v := Input.get_joy_axis(dev, ax)
			if absf(v) > 0.05:
				extra += "ax%d%+.2f " % [ax, v]
		if extra != "":
			lines.append("  extra axes: " + extra)
		var held: Array[String] = []
		for b in BUTTON_NAMES.size():
			if Input.is_joy_button_pressed(dev, b):
				held.append(BUTTON_NAMES[b])
		lines.append("  held: " + (", ".join(held) if not held.is_empty() else "-"))

	var l := Input.get_vector("lh_left", "lh_right", "lh_back", "lh_fwd")
	var r := Input.get_vector("rh_left", "rh_right", "rh_back", "rh_fwd")
	lines.append("GAME  Lstick(%+.2f,%+.2f) Rstick(%+.2f,%+.2f)" % [l.x, l.y, r.x, r.y])
	lines.append("      L1:%s R1:%s L2:%s(%.2f) R2:%s(%.2f)" % [
		_on(Input.is_action_pressed("left_grab")), _on(Input.is_action_pressed("right_grab")),
		_on(Input.is_action_pressed("left_foot")), Input.get_action_strength("left_foot"),
		_on(Input.is_action_pressed("right_foot")), Input.get_action_strength("right_foot")])

	var me = null
	if main != null and main.world != null:
		me = main.players.get(multiplayer.get_unique_id())
	if me != null and multiplayer.is_server():
		var af := "none"
		if me.active_foot == 0:
			af = "LEFT"
		elif me.active_foot == 1:
			af = "RIGHT"
		lines.append("BODY  moving foot:%s  planted L:%s R:%s  grab L:%s R:%s" % [
			af, _on(me.planted[0]), _on(me.planted[1]), _on(me.grabbing[0]), _on(me.grabbing[1])])
	elif me != null:
		lines.append("BODY  (foot state lives on the host)")

	lines.append("---- events (newest last) ----")
	lines.append_array(_log)
	_label.text = "\n".join(lines)


func _add_log(line: String) -> void:
	var stamped := "%7.2f %s" % [Time.get_ticks_msec() / 1000.0, line]
	print(stamped)
	_log.append(stamped)
	while _log.size() > LOG_LINES:
		_log.remove_at(0)


func _axis_name(ax: int) -> String:
	return AXIS_NAMES[ax] if ax >= 0 and ax < AXIS_NAMES.size() else "ax%d" % ax


func _on(b: bool) -> String:
	return "ON " if b else "-  "
