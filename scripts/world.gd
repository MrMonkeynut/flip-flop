extends Node3D
## The test room: a fenced playpen with a ramp, stairs, a table, a monkey bar and a pile
## of things to pick up. Built in code so host and clients create the exact same props in
## the exact same order (the network snapshot refers to props by index).

const LAYER_WORLD := 1
const LAYER_PLAYERS := 2
const LAYER_PROPS := 4
const ALL_LAYERS := 7

const ROOM_HALF := 11.0
const WALL_HEIGHT := 1.0

var props: Array[RigidBody3D] = []
var _prop_targets: Array[Transform3D] = []
var _has_targets := false
var _authority := true

var _basket_box := AABB(Vector3(3.9, 0.0, 3.9), Vector3(2.2, 1.2, 2.2))
var _basket_label: Label3D
var _basket_count := -1


func _ready() -> void:
	_authority = multiplayer.is_server()
	_build_environment()
	_build_room()
	_build_props()


func get_spawn_point(index: int) -> Vector3:
	return Vector3(-1.8 + 1.2 * float(index % 4), 0.0, 2.5)


# =======================================================================================
# Environment
# =======================================================================================

func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.58, 0.95)
	sky_mat.sky_horizon_color = Color(0.78, 0.86, 0.96)
	sky_mat.ground_horizon_color = Color(0.78, 0.86, 0.96)
	sky_mat.ground_bottom_color = Color(0.45, 0.5, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_intensity = 1.2
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	add_child(sun)


func _mat(c: Color, rough := 0.75) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _checker_mat(a: Color, b: Color, tiles_per_metre: float) -> StandardMaterial3D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, a if ((x / 32) + (y / 32)) % 2 == 0 else b)
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * tiles_per_metre * 0.5
	m.roughness = 0.9
	return m


# =======================================================================================
# Static level geometry
# =======================================================================================

func _static_box(size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = ALL_LAYERS
	body.position = pos
	body.rotation_degrees = rot_deg
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	body.physics_material_override = pm
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	return body


func _label(text: String, pos: Vector3, size := 96, colour := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = size
	l.pixel_size = 0.006
	l.outline_size = 20
	l.modulate = colour
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(l)
	return l


func _build_room() -> void:
	var floor_mat := _checker_mat(Color(0.93, 0.9, 0.82), Color(0.84, 0.8, 0.72), 1.0)
	var grass_mat := _mat(Color(0.5, 0.75, 0.4))
	var wall_mat := _mat(Color(0.98, 0.62, 0.55))
	var wood := _mat(Color(0.72, 0.52, 0.34))
	var blue := _mat(Color(0.45, 0.65, 0.95))
	var mint := _mat(Color(0.55, 0.85, 0.72))
	var yellow := _mat(Color(1.0, 0.85, 0.4))

	# Lawn around the playpen (so you can tumble over the fence without falling forever)
	_static_box(Vector3(40, 1, 40), Vector3(0, -0.52, 0), grass_mat)
	# Floor inside the fence
	_static_box(Vector3(ROOM_HALF * 2, 0.1, ROOM_HALF * 2), Vector3(0, -0.05, 0), floor_mat)

	# Low fence around the edge
	var t := 0.4
	_static_box(Vector3(ROOM_HALF * 2 + t, WALL_HEIGHT, t), Vector3(0, WALL_HEIGHT / 2, -ROOM_HALF), wall_mat)
	_static_box(Vector3(ROOM_HALF * 2 + t, WALL_HEIGHT, t), Vector3(0, WALL_HEIGHT / 2, ROOM_HALF), wall_mat)
	_static_box(Vector3(t, WALL_HEIGHT, ROOM_HALF * 2), Vector3(-ROOM_HALF, WALL_HEIGHT / 2, 0), wall_mat)
	_static_box(Vector3(t, WALL_HEIGHT, ROOM_HALF * 2), Vector3(ROOM_HALF, WALL_HEIGHT / 2, 0), wall_mat)

	# Ramp up to a platform (back right)
	_static_box(Vector3(5, 1.2, 5), Vector3(7.5, 0.6, -7.5), blue)
	var ramp_angle := rad_to_deg(atan2(1.2, 5.0))
	_static_box(Vector3(3, 0.2, 5.2), Vector3(7.5, 0.5, -2.55), mint, Vector3(ramp_angle, 0, 0))
	_label("RAMP", Vector3(7.5, 2.2, -5.5), 80)

	# Stairs (back left)
	for i in 5:
		var h := 0.16 * float(i + 1)
		_static_box(Vector3(3, h, 0.6), Vector3(-7.5, h / 2, -3.5 - 0.6 * float(i)), yellow)
	_static_box(Vector3(3, 0.8, 4.8), Vector3(-7.5, 0.4, -8.6), yellow)
	_label("STAIRS", Vector3(-7.5, 2.0, -8.0), 80)

	# Table (front left) - things to knock off
	_static_box(Vector3(2.2, 0.08, 1.1), Vector3(-5, 0.76, 3), wood)
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			_static_box(Vector3(0.08, 0.72, 0.08), Vector3(-5 + 0.98 * x, 0.36, 3 + 0.46 * z), wood)

	# Monkey bar to hang off (grab it with both hands!)
	var post_mat := _mat(Color(0.4, 0.4, 0.45))
	_static_box(Vector3(0.15, 1.6, 0.15), Vector3(-1.5, 0.8, -7.5), post_mat)
	_static_box(Vector3(0.15, 1.6, 0.15), Vector3(1.5, 0.8, -7.5), post_mat)
	_static_box(Vector3(3.15, 0.08, 0.08), Vector3(0, 1.56, -7.5), _mat(Color(0.95, 0.95, 0.95), 0.3))
	_label("HANG ON!\n(grab with both hands, lift both feet)", Vector3(0, 2.3, -7.5), 64)

	# Drop-off basket (front right) - a first little "task"
	var pad := _mat(Color(1.0, 0.95, 0.6))
	_static_box(Vector3(2.4, 0.04, 2.4), Vector3(5, 0.02, 5), pad)
	var bw := 0.12
	var bh := 0.45
	_static_box(Vector3(2.4, bh, bw), Vector3(5, bh / 2, 3.86), wall_mat)
	_static_box(Vector3(2.4, bh, bw), Vector3(5, bh / 2, 6.14), wall_mat)
	_static_box(Vector3(bw, bh, 2.4), Vector3(3.86, bh / 2, 5), wall_mat)
	_static_box(Vector3(bw, bh, 2.4), Vector3(6.14, bh / 2, 5), wall_mat)
	_basket_label = _label("", Vector3(5, 1.7, 5), 72, Color(1, 0.95, 0.6))

	_label("FLIP-FLOP TEST ROOM", Vector3(0, 2.5, -10.6), 120, Color(1.0, 0.85, 0.5))


# =======================================================================================
# Props
# =======================================================================================

func _prop(shape: Shape3D, mesh: Mesh, mat: Material, pos: Vector3, mass: float, bounce := 0.1, rot_deg := Vector3.ZERO) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.name = "Prop%03d" % props.size()
	b.mass = mass
	b.collision_layer = LAYER_PROPS
	b.collision_mask = ALL_LAYERS
	b.position = pos
	b.rotation_degrees = rot_deg
	var pm := PhysicsMaterial.new()
	pm.friction = 0.8
	pm.bounce = bounce
	b.physics_material_override = pm
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	if mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		b.add_child(mi)
	if not _authority:
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		b.freeze = true
	add_child(b)
	props.append(b)
	_prop_targets.append(b.transform)
	return b


func _box_prop(size: Vector3, pos: Vector3, colour: Color, mass: float, rot_deg := Vector3.ZERO) -> RigidBody3D:
	var shape := BoxShape3D.new()
	shape.size = size
	var mesh := BoxMesh.new()
	mesh.size = size
	return _prop(shape, mesh, _mat(colour), pos, mass, 0.1, rot_deg)


func _ball_prop(radius: float, pos: Vector3, colour: Color, mass: float, bounce := 0.5) -> RigidBody3D:
	var shape := SphereShape3D.new()
	shape.radius = radius
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	return _prop(shape, mesh, _mat(colour, 0.4), pos, mass, bounce)


func _duck_prop(pos: Vector3, yaw: float) -> RigidBody3D:
	var duck_yellow := _mat(Color(1.0, 0.85, 0.15), 0.35)
	var body_shape := SphereShape3D.new()
	body_shape.radius = 0.13
	var body_mesh := SphereMesh.new()
	body_mesh.radius = 0.13
	body_mesh.height = 0.22
	var d := _prop(body_shape, body_mesh, duck_yellow, pos, 0.4, 0.3, Vector3(0, yaw, 0))
	var head_shape := SphereShape3D.new()
	head_shape.radius = 0.08
	var head_cs := CollisionShape3D.new()
	head_cs.shape = head_shape
	head_cs.position = Vector3(0, 0.14, -0.07)
	d.add_child(head_cs)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.08
	head_mesh.height = 0.16
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.material_override = duck_yellow
	head.position = head_cs.position
	d.add_child(head)
	var beak_mesh := BoxMesh.new()
	beak_mesh.size = Vector3(0.07, 0.025, 0.07)
	var beak := MeshInstance3D.new()
	beak.mesh = beak_mesh
	beak.material_override = _mat(Color(1.0, 0.5, 0.1))
	beak.position = Vector3(0, 0.13, -0.16)
	d.add_child(beak)
	return d


func _cone_prop(pos: Vector3) -> RigidBody3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.03
	mesh.bottom_radius = 0.17
	mesh.height = 0.5
	mesh.radial_segments = 12
	var shape := mesh.create_convex_shape()
	return _prop(shape, mesh, _mat(Color(1.0, 0.45, 0.1)), pos, 0.6)


func _build_props() -> void:
	# A loose pile of small crates
	var crate_colours := [Color(0.85, 0.62, 0.38), Color(0.78, 0.55, 0.32), Color(0.9, 0.7, 0.45)]
	for i in 8:
		var x := 2.0 + float(i % 3) * 0.6
		var z := -1.0 + float(i / 3) * 0.6
		_box_prop(Vector3(0.45, 0.45, 0.45), Vector3(x, 0.24, z), crate_colours[i % 3], 2.5, Vector3(0, i * 13.0, 0))

	# A little block tower to knock over
	var tower_colours := [Color(0.95, 0.35, 0.4), Color(0.35, 0.6, 0.95), Color(0.4, 0.85, 0.5), Color(0.98, 0.8, 0.3)]
	var s := 0.34
	for row in 4:
		for col in 4 - row:
			var x := -3.0 + (float(col) - float(3 - row) * 0.5) * (s + 0.01)
			_box_prop(Vector3(s, s, s), Vector3(x, s * 0.5 + float(row) * s, -3.0), tower_colours[(row + col) % 4], 0.8)

	# Things on the table
	_ball_prop(0.16, Vector3(-5.6, 1.0, 3.0), Color(0.95, 0.3, 0.35), 0.8)
	_ball_prop(0.16, Vector3(-5.2, 1.0, 3.1), Color(0.3, 0.55, 0.95), 0.8)
	_duck_prop(Vector3(-4.7, 0.95, 2.9), 20.0)
	_duck_prop(Vector3(-4.3, 0.95, 3.15), -35.0)
	_duck_prop(Vector3(-5.9, 0.95, 3.25), 160.0)

	# Big bouncy beach ball
	_ball_prop(0.5, Vector3(0.5, 0.6, 5.5), Color(0.98, 0.95, 0.95), 0.35, 0.75)

	# Plank - good for see-saws and whacking friends
	_box_prop(Vector3(0.35, 0.08, 2.4), Vector3(-2.5, 0.05, 6.0), Color(0.8, 0.6, 0.4), 3.0)

	# Traffic cones
	_cone_prop(Vector3(1.5, 0.3, -4.5))
	_cone_prop(Vector3(2.3, 0.3, -5.0))
	_cone_prop(Vector3(3.1, 0.3, -4.5))

	# Heavy crate - needs a friend
	var heavy := _box_prop(Vector3(1.1, 1.1, 1.1), Vector3(4.5, 0.56, -6.5), Color(0.55, 0.38, 0.25), 55.0)
	var tag := Label3D.new()
	tag.text = "TEAM LIFT\n(heavy!)"
	tag.font_size = 64
	tag.pixel_size = 0.005
	tag.outline_size = 16
	tag.position = Vector3(0, 0, 0.56)
	heavy.add_child(tag)

	# Stuff waiting on top of the ramp platform
	_box_prop(Vector3(0.45, 0.45, 0.45), Vector3(7.0, 1.45, -8.0), Color(0.6, 0.85, 0.95), 2.0)
	_ball_prop(0.22, Vector3(8.3, 1.45, -7.0), Color(0.7, 0.4, 0.95), 1.0)


# =======================================================================================
# Networking + per-frame
# =======================================================================================

func get_prop_snapshot() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(props.size() * 7)
	var o := 0
	for p in props:
		var xf := p.global_transform
		var q := xf.basis.get_rotation_quaternion()
		out[o] = xf.origin.x
		out[o + 1] = xf.origin.y
		out[o + 2] = xf.origin.z
		out[o + 3] = q.x
		out[o + 4] = q.y
		out[o + 5] = q.z
		out[o + 6] = q.w
		o += 7
	return out


func apply_prop_snapshot(data: PackedFloat32Array, offset: int) -> void:
	var o := offset
	for i in props.size():
		if o + 7 > data.size():
			return
		var q := Quaternion(data[o + 3], data[o + 4], data[o + 5], data[o + 6]).normalized()
		_prop_targets[i] = Transform3D(Basis(q), Vector3(data[o], data[o + 1], data[o + 2]))
		o += 7
	_has_targets = true


func _process(delta: float) -> void:
	if not _authority and _has_targets:
		var w := 1.0 - exp(-18.0 * delta)
		for i in props.size():
			props[i].global_transform = props[i].global_transform.interpolate_with(_prop_targets[i], w)

	if _authority:
		for p in props:
			if p.global_position.y < -10.0:
				p.global_position = Vector3(0, 2.0, 0)
				p.linear_velocity = Vector3.ZERO

	var count := 0
	for p in props:
		if _basket_box.has_point(p.global_position):
			count += 1
	if count != _basket_count:
		_basket_count = count
		_basket_label.text = "DROP STUFF IN HERE\n%d in the basket" % count
