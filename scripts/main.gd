extends Node3D
## Game root: main menu, networking, camera and HUD.
##
## Networking model (host-authoritative):
##   * The host runs ALL the physics - every player and every prop.
##   * Clients send their controller state to the host ~60 times a second.
##   * The host sends back the position of every body ~30 times a second, and clients
##     smoothly blend toward it.
## This keeps everyone's wobbly physics in agreement, which matters a lot when two
## people are carrying the same crate.

const WorldScript := preload("res://scripts/world.gd")
const PlayerScript := preload("res://scripts/player.gd")
const InputDebugScript := preload("res://scripts/input_debug.gd")
const PadInputScript := preload("res://scripts/pad_input.gd")

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const SNAPSHOT_INTERVAL := 1.0 / 30.0
const INPUT_SIZE := 10

var world: WorldScript = null
var players: Dictionary = {} # peer id -> player node
var remote_inputs: Dictionary = {} # peer id -> PackedFloat32Array (host only)
var ready_peers: Dictionary = {} # peer ids that have loaded the world (host only)
var mode := "" # "", "solo", "host", "client"

var camera: Camera3D
var cam_yaw := 0.0
var cam_yaw_target := 0.0
var cam_focus := Vector3(0, 1, 2)
var _snapshot_timer := 0.0
var _send_input_this_tick := false

# UI
var _menu: Control
var _hud: Control
var _status: Label
var _ip_edit: LineEdit
var _port_edit: LineEdit
var _hud_label: Label
var _help_panel: PanelContainer
var _solo_button: Button

## The one controller the local player uses (see pad_input.gd).
var pad: PadInputScript

# Automated self-test (run with: godot --headless -- --autotest)
var _autotest := false
var _autotest_time := 0.0
var _autotest_input := PackedFloat32Array()
var _autotest_next_print := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	camera = Camera3D.new()
	camera.fov = 62.0
	add_child(camera)
	camera.position = Vector3(0, 5, 8)
	camera.look_at(Vector3.ZERO)
	camera.current = true

	pad = PadInputScript.new()
	pad.name = "PadInput"
	add_child(pad)

	_build_ui()

	# On-screen input debugger (F3 to toggle).
	var dbg := InputDebugScript.new()
	dbg.main = self
	add_child(dbg)

	var args := OS.get_cmdline_user_args()
	if args.has("--autotest"):
		_autotest = true
		_autotest_input.resize(INPUT_SIZE)
		_start_solo()
	elif args.has("--solo"):
		_start_solo()
	elif args.has("--host"):
		_on_host_pressed()
	else:
		for a in args:
			if a.begins_with("--join="):
				_ip_edit.text = a.substr(7)
				_on_join_pressed()


# =======================================================================================
# Menu actions
# =======================================================================================

func _port() -> int:
	var p := _port_edit.text.strip_edges().to_int()
	return p if p > 0 and p < 65536 else DEFAULT_PORT


func _start_solo() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_start_world("solo")
	_spawn_player(1, 0)


func _on_host_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(_port(), MAX_PLAYERS - 1)
	if err != OK:
		_set_status("Couldn't host on port %d (error %d). Is something else using it?" % [_port(), err])
		return
	multiplayer.multiplayer_peer = peer
	_start_world("host")
	_spawn_player(1, 0)


func _on_join_pressed() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, _port())
	if err != OK:
		_set_status("Couldn't start connecting (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Connecting to %s:%d ..." % [ip, _port()])


func _start_world(new_mode: String) -> void:
	mode = new_mode
	world = WorldScript.new()
	world.name = "World"
	add_child(world)
	_menu.visible = false
	_hud.visible = true
	_update_hud()


func _return_to_menu(message: String) -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if world != null:
		world.queue_free()
		world = null
	players.clear()
	remote_inputs.clear()
	ready_peers.clear()
	mode = ""
	_menu.visible = true
	_hud.visible = false
	_set_status(message)
	_solo_button.grab_focus()


func _set_status(text: String) -> void:
	_status.text = text


# =======================================================================================
# Connection events
# =======================================================================================

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server() or world == null:
		return
	var colour := _free_colour()
	_spawn_player(id, colour)
	for pid in ready_peers:
		_rpc_spawn_player.rpc_id(pid, id, colour)
	_update_hud()


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_remove_player(id)
	remote_inputs.erase(id)
	ready_peers.erase(id)
	for pid in ready_peers:
		_rpc_remove_player.rpc_id(pid, id)
	_update_hud()


func _on_connected_to_server() -> void:
	_start_world("client")
	_rpc_request_state.rpc_id(1)


func _on_connection_failed() -> void:
	_return_to_menu.call_deferred("Couldn't connect. Check the IP address, port and firewall.")


func _on_server_disconnected() -> void:
	_return_to_menu.call_deferred("Lost connection to the host.")


func _free_colour() -> int:
	var used := {}
	for id in players:
		used[players[id].color_index] = true
	for c in MAX_PLAYERS:
		if not used.has(c):
			return c
	return players.size() % MAX_PLAYERS


func _spawn_player(id: int, colour: int) -> void:
	if players.has(id) or world == null:
		return
	var p := PlayerScript.new()
	p.name = "Player%d" % id
	p.setup(id, colour, world.get_spawn_point(colour), multiplayer.is_server())
	world.add_child(p)
	players[id] = p
	_update_hud()


func _remove_player(id: int) -> void:
	if players.has(id):
		players[id].queue_free()
		players.erase(id)
	_update_hud()


# =======================================================================================
# RPCs (all live on this node, which exists at /root/Main on every peer)
# =======================================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	ready_peers[sender] = true
	var ids := PackedInt32Array()
	var colours := PackedInt32Array()
	for id in players:
		ids.append(id)
		colours.append(players[id].color_index)
	_rpc_full_state.rpc_id(sender, ids, colours)


@rpc("authority", "call_remote", "reliable")
func _rpc_full_state(ids: PackedInt32Array, colours: PackedInt32Array) -> void:
	for i in ids.size():
		_spawn_player(ids[i], colours[i])


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_player(id: int, colour: int) -> void:
	_spawn_player(id, colour)


@rpc("authority", "call_remote", "reliable")
func _rpc_remove_player(id: int) -> void:
	_remove_player(id)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_input(data: PackedFloat32Array) -> void:
	if multiplayer.is_server() and data.size() == INPUT_SIZE:
		remote_inputs[multiplayer.get_remote_sender_id()] = data


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(ids: PackedInt32Array, data: PackedFloat32Array) -> void:
	if world == null:
		return
	var o := 0
	for id in ids:
		if o + PlayerScript.SNAP_SIZE > data.size():
			return
		if players.has(id):
			players[id].apply_snapshot(data, o)
		o += PlayerScript.SNAP_SIZE
	world.apply_prop_snapshot(data, o)


func _send_snapshot() -> void:
	var ids := PackedInt32Array()
	var data := PackedFloat32Array()
	for id in players:
		ids.append(id)
		data.append_array(players[id].get_snapshot())
	data.append_array(world.get_prop_snapshot())
	_rpc_snapshot.rpc(ids, data)


# =======================================================================================
# Input + simulation
# =======================================================================================

func _read_local_input() -> PackedFloat32Array:
	if _autotest:
		_autotest_input[8] = cam_yaw
		return _autotest_input
	var out := PackedFloat32Array()
	out.resize(INPUT_SIZE)
	if _menu.visible:
		return out
	var l := pad.left_stick()
	var r := pad.right_stick()
	out[0] = l.x
	out[1] = l.y
	out[2] = r.x
	out[3] = r.y
	out[4] = 1.0 if pad.left_bumper() else 0.0
	out[5] = 1.0 if pad.right_bumper() else 0.0
	out[6] = 1.0 if pad.left_trigger() else 0.0
	out[7] = 1.0 if pad.right_trigger() else 0.0
	out[8] = cam_yaw
	out[9] = 1.0 if pad.button(JOY_BUTTON_BACK) or Input.is_physical_key_pressed(KEY_R) else 0.0
	return out


func _physics_process(delta: float) -> void:
	if world == null:
		return
	if _autotest:
		_run_autotest(delta)
	var local := _read_local_input()
	var my_id := multiplayer.get_unique_id()
	if multiplayer.is_server():
		for id in players:
			var inp: PackedFloat32Array = local if id == my_id else remote_inputs.get(id, _zero_input())
			players[id].physics_step(inp, delta)
		if mode == "host" and not ready_peers.is_empty():
			_snapshot_timer += delta
			if _snapshot_timer >= SNAPSHOT_INTERVAL:
				_snapshot_timer = fmod(_snapshot_timer, SNAPSHOT_INTERVAL)
				_send_snapshot()
	elif mode == "client":
		_send_input_this_tick = not _send_input_this_tick
		if _send_input_this_tick:
			_rpc_input.rpc_id(1, local)


func _zero_input() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(INPUT_SIZE)
	return z


func _process(delta: float) -> void:
	if world == null:
		return
	if pad.just_pressed(JOY_BUTTON_DPAD_LEFT, KEY_Z):
		cam_yaw_target -= PI / 4.0
	if pad.just_pressed(JOY_BUTTON_DPAD_RIGHT, KEY_X):
		cam_yaw_target += PI / 4.0
	if pad.just_pressed(JOY_BUTTON_START, KEY_H):
		_help_panel.visible = not _help_panel.visible
	cam_yaw = lerp_angle(cam_yaw, cam_yaw_target, 1.0 - exp(-8.0 * delta))

	var me = players.get(multiplayer.get_unique_id())
	if me != null and me.torso != null:
		cam_focus = cam_focus.lerp(me.torso.global_position, 1.0 - exp(-4.0 * delta))
	var offset := Basis(Vector3.UP, cam_yaw) * Vector3(0, 3.4, 5.0)
	camera.global_position = cam_focus + offset
	camera.look_at(cam_focus + Vector3(0, 0.2, 0))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE and world != null:
		_return_to_menu("Left the game.")


# =======================================================================================
# UI
# =======================================================================================

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	# ---- Main menu ----
	_menu = Control.new()
	_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_menu)
	var bg := ColorRect.new()
	bg.color = Color(1.0, 0.82, 0.5)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu.add_child(bg)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu.add_child(centre)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	centre.add_child(vb)

	var title := Label.new()
	title.text = "FLIP-FLOP"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 110)
	title.add_theme_color_override("font_color", Color(1.0, 0.36, 0.3))
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.12, 0.1))
	title.add_theme_constant_override("outline_size", 22)
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "a wobbly co-op adventure  -  test room"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 26)
	sub.add_theme_color_override("font_color", Color(0.3, 0.18, 0.12))
	vb.add_child(sub)
	vb.add_child(_spacer(16))

	_solo_button = _menu_button("Play Solo", _start_solo)
	vb.add_child(_solo_button)
	vb.add_child(_menu_button("Host Online Game", _on_host_pressed))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "Host IP (e.g. 192.168.1.20)"
	_ip_edit.text = "127.0.0.1"
	_ip_edit.custom_minimum_size = Vector2(270, 56)
	_ip_edit.add_theme_font_size_override("font_size", 24)
	row.add_child(_ip_edit)
	_port_edit = LineEdit.new()
	_port_edit.text = str(DEFAULT_PORT)
	_port_edit.custom_minimum_size = Vector2(100, 56)
	_port_edit.add_theme_font_size_override("font_size", 24)
	row.add_child(_port_edit)
	var join := _menu_button("Join", _on_join_pressed)
	join.custom_minimum_size = Vector2(120, 56)
	row.add_child(join)
	vb.add_child(row)
	vb.add_child(_menu_button("Quit", func() -> void: get_tree().quit()))

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 22)
	_status.add_theme_color_override("font_color", Color(0.55, 0.1, 0.1))
	vb.add_child(_status)
	var hint := Label.new()
	hint.text = "Plug in a controller!   (D-pad / left stick + A to use this menu)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.35, 0.22, 0.15))
	vb.add_child(hint)

	# ---- In-game HUD ----
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.visible = false
	layer.add_child(_hud)

	_hud_label = Label.new()
	_hud_label.position = Vector2(18, 14)
	_hud_label.add_theme_font_size_override("font_size", 22)
	_hud_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_hud_label.add_theme_constant_override("outline_size", 6)
	_hud.add_child(_hud_label)

	_help_panel = PanelContainer.new()
	_help_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_help_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help_panel.offset_left = 16
	_help_panel.offset_bottom = -16
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.55)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	_help_panel.add_theme_stylebox_override("panel", style)
	var help := Label.new()
	help.add_theme_font_size_override("font_size", 19)
	help.text = "\n".join([
		"LEFT STICK      move left hand",
		"RIGHT STICK     move right hand",
		"  (push forward to reach out, pull back to reach down)",
		"L1 / R1         hold to grab with that hand",
		"L2 + left stick   lift & move left foot",
		"R2 + right stick  lift & move right foot",
		"  (one foot at a time - stretch it all the way",
		"   out to drag your body, let go, swap feet)",
		"D-PAD L/R       rotate camera",
		"BACK/SELECT     respawn",
		"START           hide this help",
	])
	_help_panel.add_child(help)
	_hud.add_child(_help_panel)

	_solo_button.call_deferred("grab_focus")


func _menu_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(500, 60)
	b.add_theme_font_size_override("font_size", 28)
	b.pressed.connect(cb)
	return b


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _update_hud() -> void:
	if _hud_label == null:
		return
	var lines: Array[String] = []
	match mode:
		"solo":
			lines.append("Solo")
		"host":
			var addrs: Array[String] = []
			for a in IP.get_local_addresses():
				if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
					addrs.append(a)
			lines.append("Hosting on port %d   -   your IP: %s" % [_port(), ", ".join(addrs) if not addrs.is_empty() else "?"])
		"client":
			lines.append("Connected")
	lines.append("Players: %d / %d" % [players.size(), MAX_PLAYERS])
	lines.append("ESC: leave")
	_hud_label.text = "\n".join(lines)


# =======================================================================================
# Self-test: scripted inputs, prints how the body behaves. Not used in normal play.
# =======================================================================================

func _set_test_input(lx := 0.0, ly := 0.0, rx := 0.0, ry := 0.0, lg := false, rg := false, lf := false, rf := false) -> void:
	_autotest_input[0] = lx
	_autotest_input[1] = ly
	_autotest_input[2] = rx
	_autotest_input[3] = ry
	_autotest_input[4] = 1.0 if lg else 0.0
	_autotest_input[5] = 1.0 if rg else 0.0
	_autotest_input[6] = 1.0 if lf else 0.0
	_autotest_input[7] = 1.0 if rf else 0.0
	_autotest_input[9] = 0.0


func _run_autotest(delta: float) -> void:
	_autotest_time += delta
	var t := _autotest_time
	var p = players.get(1)
	if t < 3.0:
		_set_test_input() # stand still
	elif t < 13.0:
		# walk forward: alternate feet every 0.5 s
		var phase := fmod(t - 3.0, 1.0)
		if phase < 0.35:
			_set_test_input(0, 1, 0, 0, false, false, true, false)
		elif phase < 0.5:
			_set_test_input()
		elif phase < 0.85:
			_set_test_input(0, 0, 0, 1, false, false, false, true)
		else:
			_set_test_input()
	elif t < 15.0:
		_set_test_input(0, -1, 0, -1) # reach down
	elif t < 16.0:
		_set_test_input(0, -1, 0, -1, true, true) # grab whatever is there
	elif t < 19.0:
		_set_test_input(0, 1, 0, 1, true, true) # lift it up
	else:
		_set_test_input()
	if t >= _autotest_next_print and p != null:
		_autotest_next_print += 0.5
		var tor: RigidBody3D = p.torso
		var tilt := rad_to_deg(tor.global_basis.y.angle_to(Vector3.UP))
		print("t=%5.2f torso=(%5.2f,%5.2f,%5.2f) tilt=%5.1f planted=%s grab=%s lh=%s rh=%s" % [
			t, tor.global_position.x, tor.global_position.y, tor.global_position.z, tilt,
			str(p.planted), str(p.grabbing), str(p.hands[0].global_position.snapped(Vector3.ONE * 0.01)),
			str(p.hands[1].global_position.snapped(Vector3.ONE * 0.01))])
	if t > 21.0:
		get_tree().quit()
