extends Node3D
## A wobbly physics character.
##
## The body is five rigid bodies: a torso (with the head attached), two hands and two feet.
## Nothing is held together by rigid joints. Instead, springs push the parts toward where
## the controller wants them, and soft "bone" constraints stop arms and legs from stretching
## too far. That gives the loose, floppy feel.
##
## Standing up works like this: feet that are on the ground get "planted". The torso is
## pushed up to standing height above the planted feet and pulled sideways to sit over them.
## Lift a foot (L2/R2) and move it with the stick, put it down, and the torso drifts over to
## the new middle point between the feet. That is walking.
##
## Only the host runs physics. Clients receive transforms and just draw them.

const PALETTE: Array[Color] = [
	Color(1.0, 0.42, 0.36),
	Color(0.32, 0.62, 1.0),
	Color(0.42, 0.82, 0.38),
	Color(1.0, 0.78, 0.25),
]
const SKIN := Color(1.0, 0.85, 0.7)

const LAYER_WORLD := 1
const LAYER_PLAYERS := 2
const LAYER_PROPS := 4
const ALL_LAYERS := 7
const G := 9.8

# --- Body shape -----------------------------------------------------------------------
const TORSO_RADIUS := 0.28
const TORSO_HEIGHT := 0.95
const HEAD_OFFSET := 0.68
const HEAD_RADIUS := 0.25
const HAND_RADIUS := 0.1
const FOOT_RADIUS := 0.1
const SHOULDER := Vector3(0.36, 0.25, 0.0)
const HIP := Vector3(0.15, -0.36, 0.0)
const ARM_LEN := 0.85
const LEG_LEN := 0.85
const STAND_HEIGHT := 0.95 # torso centre above the centre of the planted feet
const STRIDE := 1.15 # how far the moving foot can get from the planted one
const STANCE_WIDTH := 0.3 # sideways gap between the feet with the stick centred
const STEP_LIFT := 0.25 # how high a lifted foot hovers (enough to clear a stair)
const DRAG_START := 0.35 # foot further than this from the planted one starts dragging the body

const TORSO_MASS := 10.0
const HAND_MASS := 0.8
const FOOT_MASS := 1.5

# --- Tuning: lower stiffness / damping = wobblier --------------------------------------
const SUPPORT_K := 900.0 # legs pushing the torso up
const SUPPORT_C := 85.0
const BALANCE_K := 200.0 # torso drifting over the feet
const BALANCE_C := 40.0
const UPRIGHT_K := 230.0 # staying upright
const UPRIGHT_C := 20.0
const YAW_K := 55.0 # turning to face where you reach / step
const YAW_C := 9.0
const HAND_K := 350.0
const HAND_C := 20.0
const HAND_MAX_FORCE := 260.0
const HAND_REACTION := 0.3 # how much reaching yanks the torso around
const ARM_K := 2500.0
const ARM_C := 80.0
const FOOT_K := 320.0
const FOOT_C := 26.0
const FOOT_MAX_FORCE := 260.0
const PLANT_K := 650.0
const PLANT_C := 40.0
const LEG_K := 2500.0
const LEG_C := 80.0
const WOBBLE := 0.08

const BODY_COUNT := 5
const SNAP_SIZE := 1 + BODY_COUNT * 7

var peer_id := 1
var color_index := 0
var authority := true
var spawn_point := Vector3.ZERO

var torso: RigidBody3D
var hands: Array[RigidBody3D] = [null, null]
var feet: Array[RigidBody3D] = [null, null]
var _bodies: Array[RigidBody3D] = []
var _own_rids: Array[RID] = []

var facing := Vector3.FORWARD
var active_foot := -1 # which foot is being moved (-1 = none). Only one at a time.
var lifted: Array[bool] = [false, false]
var planted: Array[bool] = [false, false]
var plant_points: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var grab_joints: Array[Joint3D] = [null, null]
var grab_targets: Array[Node3D] = [null, null]
var grabbing: Array[bool] = [false, false] # replicated for visuals

var _t := 0.0
var _seed := 0.0
var _last_respawn := false
var _grab_shape := SphereShape3D.new()

# Client-side interpolation targets
var _targets: Array[Transform3D] = []
var _has_targets := false

# Visuals
var _color: Color
var _body_mat: StandardMaterial3D
var _skin_mat: StandardMaterial3D
var _grip_mat: StandardMaterial3D
var _limbs: Array[MeshInstance3D] = [] # 8 segments: (upper, lower) x (L arm, R arm, L leg, R leg)
var _joints_vis: Array[MeshInstance3D] = [] # elbows and knees
var _hand_meshes: Array[MeshInstance3D] = []
var _foot_vis: Array[Node3D] = []
var _label: Label3D
var _pupils: Array[MeshInstance3D] = []
var _eye_centres: Array[Vector3] = []
var _pupil_off: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _pupil_vel: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _last_torso_pos := Vector3.ZERO
var _last_torso_vel := Vector3.ZERO


func setup(id: int, colour_idx: int, spawn: Vector3, is_authority: bool) -> void:
	peer_id = id
	color_index = colour_idx
	spawn_point = spawn
	authority = is_authority
	_seed = float(colour_idx) * 17.3 + 3.1


func _ready() -> void:
	_color = PALETTE[color_index % PALETTE.size()]
	_body_mat = _make_mat(_color)
	_skin_mat = _make_mat(SKIN)
	_grip_mat = _make_mat(_color.darkened(0.25))
	_grab_shape.radius = 0.2
	_build_bodies()
	_build_visuals()
	_place_bodies(spawn_point)
	_last_torso_pos = torso.global_position


# =======================================================================================
# Construction
# =======================================================================================

func _make_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.65
	return m


func _make_body(body_name: String, shape: Shape3D, mass: float, friction: float) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.name = body_name
	b.mass = mass
	b.collision_layer = LAYER_PLAYERS
	b.collision_mask = ALL_LAYERS
	b.can_sleep = false
	b.continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.friction = friction
	pm.bounce = 0.05
	b.physics_material_override = pm
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	if not authority:
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		b.freeze = true
	add_child(b)
	return b


func _build_bodies() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = TORSO_RADIUS
	capsule.height = TORSO_HEIGHT
	torso = _make_body("Torso", capsule, TORSO_MASS, 0.6)
	var head_shape := SphereShape3D.new()
	head_shape.radius = HEAD_RADIUS
	var head_cs := CollisionShape3D.new()
	head_cs.shape = head_shape
	head_cs.position = Vector3(0, HEAD_OFFSET, 0)
	torso.add_child(head_cs)
	torso.angular_damp = 0.5

	for i in 2:
		var hs := SphereShape3D.new()
		hs.radius = HAND_RADIUS
		hands[i] = _make_body("Hand%s" % ["L", "R"][i], hs, HAND_MASS, 1.0)
		hands[i].angular_damp = 5.0
		var fs := SphereShape3D.new()
		fs.radius = FOOT_RADIUS
		feet[i] = _make_body("Foot%s" % ["L", "R"][i], fs, FOOT_MASS, 1.2)
		feet[i].angular_damp = 8.0

	_bodies = [torso, hands[0], hands[1], feet[0], feet[1]]
	for b in _bodies:
		_own_rids.append(b.get_rid())
		_targets.append(Transform3D())
	for a in _bodies:
		for b in _bodies:
			if a != b:
				a.add_collision_exception_with(b)


func _build_visuals() -> void:
	# Torso (shirt) + head + party hat + googly eyes, all attached to the torso body.
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = TORSO_RADIUS
	torso_mesh.height = TORSO_HEIGHT
	_add_mesh(torso, torso_mesh, _body_mat, Vector3.ZERO)

	var head_mesh := SphereMesh.new()
	head_mesh.radius = HEAD_RADIUS
	head_mesh.height = HEAD_RADIUS * 2.0
	_add_mesh(torso, head_mesh, _skin_mat, Vector3(0, HEAD_OFFSET, 0))

	var hat := CylinderMesh.new()
	hat.top_radius = 0.0
	hat.bottom_radius = 0.13
	hat.height = 0.28
	var hat_mi := _add_mesh(torso, hat, _body_mat, Vector3(0.04, HEAD_OFFSET + 0.3, 0.02))
	hat_mi.rotation_degrees = Vector3(8, 0, -12)

	var white := _make_mat(Color(1, 1, 1))
	var black := _make_mat(Color(0.05, 0.05, 0.05))
	black.roughness = 0.2
	for s in [-1.0, 1.0]:
		var eye := SphereMesh.new()
		eye.radius = 0.085
		eye.height = 0.17
		var centre := Vector3(0.1 * s, HEAD_OFFSET + 0.05, -0.2)
		_add_mesh(torso, eye, white, centre)
		var pupil := SphereMesh.new()
		pupil.radius = 0.042
		pupil.height = 0.084
		_pupils.append(_add_mesh(torso, pupil, black, centre + Vector3(0, 0, -0.055)))
		_eye_centres.append(centre)

	# Mittens
	for i in 2:
		var hm := SphereMesh.new()
		hm.radius = HAND_RADIUS * 1.05
		hm.height = HAND_RADIUS * 2.1
		_hand_meshes.append(_add_mesh(hands[i], hm, _skin_mat, Vector3.ZERO))

	# Noodle limbs: two segments each plus a ball at the elbow/knee.
	for limb in 4:
		var mat := _skin_mat
		for seg in 2:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.055 if limb < 2 else 0.065
			cyl.bottom_radius = cyl.top_radius
			cyl.height = 1.0
			cyl.radial_segments = 10
			cyl.rings = 1
			var mi := MeshInstance3D.new()
			mi.mesh = cyl
			mi.material_override = mat
			mi.top_level = true
			add_child(mi)
			_limbs.append(mi)
		var ball := SphereMesh.new()
		ball.radius = 0.065 if limb < 2 else 0.075
		ball.height = ball.radius * 2.0
		var bmi := MeshInstance3D.new()
		bmi.mesh = ball
		bmi.material_override = mat
		bmi.top_level = true
		add_child(bmi)
		_joints_vis.append(bmi)

	# Flip-flops!
	var strap_mat := _make_mat(Color(0.15, 0.15, 0.18))
	for i in 2:
		var root := Node3D.new()
		root.top_level = true
		add_child(root)
		var sole := BoxMesh.new()
		sole.size = Vector3(0.17, 0.035, 0.32)
		_add_mesh(root, sole, _body_mat, Vector3(0, 0.0175, -0.03))
		var foot := CapsuleMesh.new()
		foot.radius = 0.06
		foot.height = 0.27
		var foot_mi := _add_mesh(root, foot, _skin_mat, Vector3(0, 0.07, -0.03))
		foot_mi.rotation_degrees = Vector3(90, 0, 0)
		var strap := BoxMesh.new()
		strap.size = Vector3(0.14, 0.03, 0.035)
		_add_mesh(root, strap, strap_mat, Vector3(0, 0.12, -0.08))
		_foot_vis.append(root)

	_label = Label3D.new()
	_label.text = "P%d" % (color_index + 1)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 72
	_label.pixel_size = 0.004
	_label.outline_size = 18
	_label.modulate = _color.lightened(0.2)
	_label.no_depth_test = true
	_label.top_level = true
	add_child(_label)


func _add_mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _place_bodies(p: Vector3) -> void:
	var tpos := p + Vector3(0, FOOT_RADIUS + STAND_HEIGHT, 0)
	torso.global_transform = Transform3D(Basis(), tpos)
	for i in 2:
		var s := -1.0 if i == 0 else 1.0
		hands[i].global_transform = Transform3D(Basis(), tpos + Vector3(SHOULDER.x * s + 0.08 * s, SHOULDER.y - 0.55, -0.1))
		feet[i].global_transform = Transform3D(Basis(), p + Vector3(HIP.x * s, FOOT_RADIUS, 0))
	for b in _bodies:
		b.linear_velocity = Vector3.ZERO
		b.angular_velocity = Vector3.ZERO
	facing = Vector3.FORWARD
	planted = [false, false]
	active_foot = -1


func respawn() -> void:
	for i in 2:
		_release(i)
	_place_bodies(spawn_point)


# =======================================================================================
# Simulation (host only)
# =======================================================================================

## input layout: [lx, ly, rx, ry, l_grab, r_grab, l_foot, r_foot, cam_yaw, respawn]
func physics_step(inp: PackedFloat32Array, delta: float) -> void:
	if not authority:
		return
	_t += delta
	var sticks: Array[Vector2] = [Vector2(inp[0], inp[1]), Vector2(inp[2], inp[3])]
	var grab_held: Array[bool] = [inp[4] > 0.5, inp[5] > 0.5]
	# Only one foot can move at a time. The first trigger pressed wins, and a foot can
	# only lift if the other one is planted on something to stand on.
	var foot_held: Array[bool] = [inp[6] > 0.5, inp[7] > 0.5]
	if active_foot != -1 and not foot_held[active_foot]:
		active_foot = -1
	if active_foot == -1:
		for i in 2:
			if foot_held[i] and planted[1 - i]:
				active_foot = i
				break
	lifted = [active_foot == 0, active_foot == 1]
	var cam_basis := Basis(Vector3.UP, inp[8])
	var fwd := cam_basis * Vector3.FORWARD
	var right := cam_basis * Vector3.RIGHT

	var want_respawn := inp[9] > 0.5
	if (want_respawn and not _last_respawn) or torso.global_position.y < -10.0:
		_last_respawn = want_respawn
		respawn()
		return
	_last_respawn = want_respawn

	var space := get_world_3d().direct_space_state

	# --- Feet: work out which ones are planted on something -------------------------
	var support := Vector3.ZERO
	var n_planted := 0
	for i in 2:
		var hip := _hip(i)
		var fp := feet[i].global_position
		if lifted[i]:
			planted[i] = false
		elif planted[i]:
			if fp.distance_to(hip) > LEG_LEN * 1.3:
				planted[i] = false # yanked off our feet - stumble!
		elif _foot_on_ground(space, fp) and feet[i].linear_velocity.length() < 3.0:
			planted[i] = true
			plant_points[i] = fp
		if planted[i]:
			support += fp
			n_planted += 1

	# --- Which way do we want to face? ----------------------------------------------
	var want_dir := Vector3.ZERO
	for i in 2:
		var s := sticks[i]
		if s.length() < 0.4:
			continue
		var d := (right * s.x + fwd * s.y).normalized()
		if lifted[i]:
			if d.dot(facing) > -0.2: # stepping backwards shouldn't spin us around
				want_dir += d
		elif s.y > -0.3:
			want_dir += d
	if want_dir.length() > 0.3:
		var ang := facing.signed_angle_to(want_dir.normalized(), Vector3.UP)
		facing = facing.rotated(Vector3.UP, ang * clampf(delta * 3.0, 0.0, 1.0)).normalized()

	# Reaching down makes us squat and bend over.
	var crouch := 0.0
	for i in 2:
		if not lifted[i] and sticks[i].y < 0.0:
			crouch = maxf(crouch, minf(-sticks[i].y, 1.0) * clampf(sticks[i].length() * 1.5, 0.0, 1.0))

	# --- Torso: legs hold it up, balance pulls it over the feet ---------------------
	var tp := torso.global_position
	var tv := torso.linear_velocity
	var up_now := torso.global_basis.y
	if n_planted > 0:
		support /= float(n_planted)
		# Where the hips want to be. Both feet down: halfway between them. One foot down:
		# over that foot, until the other foot is stretched out far enough to drag the
		# body toward it. At full stretch the body is pulled halfway, so putting the foot
		# down doesn't jolt anything.
		var anchor := support
		var base_y := support.y
		var stretch := 0.0
		if n_planted == 1:
			var pivot_i := 0 if planted[0] else 1
			var pivot := feet[pivot_i].global_position
			var other := feet[1 - pivot_i].global_position
			var spread := Vector2(other.x - pivot.x, other.z - pivot.z).length()
			stretch = clampf((spread - DRAG_START) / (STRIDE - DRAG_START), 0.0, 1.0)
			anchor = pivot.lerp(other, 0.5 * stretch)
			base_y = pivot.y
		var target_h := base_y + STAND_HEIGHT - crouch * 0.42 - stretch * 0.08 + sin(_t * 2.3 + _seed) * 0.02
		var dy := target_h - tp.y
		var flat := Vector3(anchor.x - tp.x, 0, anchor.z - tp.z)
		if dy > -0.4 and flat.length() < LEG_LEN + 0.35:
			var fy := TORSO_MASS * G + SUPPORT_K * dy - SUPPORT_C * tv.y
			fy = clampf(fy, 0.0, TORSO_MASS * G * 4.0)
			var lean := facing * crouch * 0.12
			var fh := (flat + lean) * BALANCE_K - Vector3(tv.x, 0, tv.z) * BALANCE_C
			torso.apply_central_force(fh + Vector3.UP * fy)
			for i in 2:
				if planted[i]:
					feet[i].apply_central_force(Vector3.DOWN * fy / float(n_planted))

	var wob := Vector3(
		sin(_t * 1.7 + _seed) * 0.7 + sin(_t * 4.3 + _seed * 2.0) * 0.3,
		0,
		cos(_t * 1.3 + _seed) * 0.7 + sin(_t * 3.7 + _seed) * 0.3) * WOBBLE
	var target_up := (Vector3.UP + wob + facing * crouch * 0.9).normalized()
	var upright_scale := 1.0 if n_planted > 0 else 0.3
	var torque := Vector3.ZERO
	var axis := up_now.cross(target_up)
	var sin_a := axis.length()
	if sin_a > 0.0001:
		var ang := atan2(sin_a, up_now.dot(target_up))
		torque += axis / sin_a * ang * UPRIGHT_K * upright_scale
	var av := torso.angular_velocity
	torque -= Vector3(av.x, 0, av.z) * UPRIGHT_C * upright_scale
	var fwd_now := -torso.global_basis.z
	fwd_now.y = 0
	if fwd_now.length() > 0.15:
		var yaw_err := fwd_now.normalized().signed_angle_to(facing, Vector3.UP)
		torque.y += yaw_err * YAW_K * upright_scale - av.y * YAW_C
	torso.apply_torque(torque)

	# --- Hands ---------------------------------------------------------------------
	var t_right := facing.cross(Vector3.UP).normalized()
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hand := hands[i]
		var shoulder := _shoulder(i)
		var rest := shoulder + Vector3.DOWN * 0.55 + t_right * side * 0.08 + facing * 0.12
		var target := rest
		var s: Vector2 = Vector2.ZERO if lifted[i] else sticks[i]
		var mag := minf(s.length(), 1.0)
		if mag > 0.05:
			var active := shoulder + right * s.x * 0.65
			if s.y >= 0.0:
				active += fwd * s.y * 0.75 + Vector3.UP * (s.y * 0.35 - 0.15 * (1.0 - s.y))
			else:
				active += fwd * (-s.y * 0.4) + Vector3.UP * (s.y * 1.35)
			target = rest.lerp(active, clampf(mag * 1.6, 0.0, 1.0))
		var k := HAND_K * (0.35 if lifted[i] else 1.0)
		var f := (target - hand.global_position) * k - (hand.linear_velocity - tv) * HAND_C
		f = f.limit_length(HAND_MAX_FORCE)
		hand.apply_central_force(f + Vector3.UP * HAND_MASS * G)
		torso.apply_force(-f * HAND_REACTION, shoulder - tp)
		_bone(hand, shoulder, ARM_LEN, ARM_K, ARM_C, 1.0)

		# Grabbing: hold the button and whatever the hand touches gets stuck to it.
		if grab_held[i]:
			if grab_joints[i] == null:
				_try_grab(i, space)
			elif not is_instance_valid(grab_targets[i]):
				_release(i)
		elif grab_joints[i] != null:
			_release(i)
		grabbing[i] = grab_joints[i] != null

	# --- Feet ----------------------------------------------------------------------
	for i in 2:
		var foot := feet[i]
		var hip := _hip(i)
		var fp := foot.global_position
		var f := Vector3.ZERO
		if lifted[i]:
			# The moving foot is placed relative to the planted one: stick centred = beside
			# it, stick pushed all the way = a full stride away (which drags the body).
			var s := sticks[i]
			var mag := minf(s.length(), 1.0)
			var pivot := feet[1 - i].global_position
			var side := -1.0 if i == 0 else 1.0
			var offset := t_right * side * STANCE_WIDTH + (right * s.x + fwd * s.y) * STRIDE
			offset.y = 0.0
			offset = offset.limit_length(STRIDE)
			var target := pivot + offset + Vector3.UP * (STEP_LIFT + 0.08 * sin(PI * mag))
			f = (target - fp) * FOOT_K - (foot.linear_velocity - tv * 0.5) * FOOT_C
			f = f.limit_length(FOOT_MAX_FORCE) + Vector3.UP * FOOT_MASS * G
			torso.apply_central_force(-f * 0.1)
		elif planted[i]:
			var e := plant_points[i] - fp
			e.y = minf(e.y, 0.0)
			f = e * PLANT_K - foot.linear_velocity * PLANT_C
		else:
			# Just let go of the trigger (or knocked loose): stamp down where it is.
			f = Vector3.DOWN * 25.0 - Vector3(foot.linear_velocity.x, 0, foot.linear_velocity.z) * 3.0
		foot.apply_central_force(f)
		# A planted leg holds the body back rather than getting dragged itself.
		_bone(foot, hip, LEG_LEN, LEG_K, LEG_C, 1.0, 0.25 if planted[i] else 1.0)


func _shoulder(i: int) -> Vector3:
	var s := -1.0 if i == 0 else 1.0
	return torso.to_global(Vector3(SHOULDER.x * s, SHOULDER.y, SHOULDER.z))


func _hip(i: int) -> Vector3:
	var s := -1.0 if i == 0 else 1.0
	return torso.to_global(Vector3(HIP.x * s, HIP.y, HIP.z))


## Soft max-length constraint between a limb end and its anchor on the torso.
func _bone(limb: RigidBody3D, anchor: Vector3, length: float, k: float, c: float, torso_share: float, limb_share := 1.0) -> void:
	var d := limb.global_position - anchor
	var dl := d.length()
	if dl <= length:
		return
	var dir := d / dl
	var rel_v := (limb.linear_velocity - torso.linear_velocity).dot(dir)
	var cf := dir * ((dl - length) * k + maxf(rel_v, 0.0) * c)
	limb.apply_central_force(-cf * limb_share)
	torso.apply_force(cf * torso_share, anchor - torso.global_position)


func _foot_on_ground(space: PhysicsDirectSpaceState3D, fp: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(fp, fp + Vector3.DOWN * (FOOT_RADIUS + 0.08), ALL_LAYERS, _own_rids)
	return not space.intersect_ray(q).is_empty()


func _try_grab(i: int, space: PhysicsDirectSpaceState3D) -> void:
	var hand := hands[i]
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _grab_shape
	params.transform = Transform3D(Basis(), hand.global_position)
	params.collision_mask = ALL_LAYERS
	params.exclude = _own_rids
	var hits := space.intersect_shape(params, 8)
	var best: PhysicsBody3D = null
	for h in hits:
		var c: Object = h["collider"]
		if c is RigidBody3D:
			best = c as PhysicsBody3D
			break # prefer things we can actually pick up
		if c is StaticBody3D and best == null:
			best = c as PhysicsBody3D # ...but grabbing walls, bars and the floor is fun too
	if best == null:
		return
	var j := PinJoint3D.new()
	add_child(j)
	j.global_position = hand.global_position
	j.node_a = j.get_path_to(hand)
	j.node_b = j.get_path_to(best)
	grab_joints[i] = j
	grab_targets[i] = best


func _release(i: int) -> void:
	if grab_joints[i] != null and is_instance_valid(grab_joints[i]):
		grab_joints[i].queue_free()
	grab_joints[i] = null
	grab_targets[i] = null
	grabbing[i] = false


# =======================================================================================
# Networking
# =======================================================================================

func get_snapshot() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var flags := 0
	if grabbing[0]: flags |= 1
	if grabbing[1]: flags |= 2
	out.append(float(flags))
	for b in _bodies:
		var xf := b.global_transform
		var q := xf.basis.get_rotation_quaternion()
		out.append_array(PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z, q.x, q.y, q.z, q.w]))
	return out


func apply_snapshot(data: PackedFloat32Array, offset: int) -> void:
	var flags := int(data[offset])
	grabbing[0] = (flags & 1) != 0
	grabbing[1] = (flags & 2) != 0
	var o := offset + 1
	for i in BODY_COUNT:
		var q := Quaternion(data[o + 3], data[o + 4], data[o + 5], data[o + 6]).normalized()
		_targets[i] = Transform3D(Basis(q), Vector3(data[o], data[o + 1], data[o + 2]))
		o += 7
	if not _has_targets:
		for i in BODY_COUNT:
			_bodies[i].global_transform = _targets[i]
	_has_targets = true


# =======================================================================================
# Visuals (every peer)
# =======================================================================================

func _process(delta: float) -> void:
	if not authority and _has_targets:
		var w := 1.0 - exp(-18.0 * delta)
		for i in BODY_COUNT:
			_bodies[i].global_transform = _bodies[i].global_transform.interpolate_with(_targets[i], w)
	_update_visuals(delta)


func _update_visuals(delta: float) -> void:
	var tp := torso.global_position
	var vis_fwd := -torso.global_basis.z
	vis_fwd.y = 0
	vis_fwd = vis_fwd.normalized() if vis_fwd.length() > 0.1 else Vector3.FORWARD

	for i in 2:
		# arms sag down at the elbow, legs bend forward at the knee
		_two_bone(i * 2, i, _shoulder(i), hands[i].global_position, 0.82, Vector3.DOWN + vis_fwd * -0.3)
		_two_bone(4 + i * 2, 2 + i, _hip(i), feet[i].global_position, 0.72, vis_fwd + Vector3.UP * 0.2)

		_hand_meshes[i].material_override = _grip_mat if grabbing[i] else _skin_mat
		_hand_meshes[i].scale = Vector3(1.15, 0.8, 1.15) if grabbing[i] else Vector3.ONE

		var fp := feet[i].global_position + Vector3(0, -FOOT_RADIUS + 0.005, 0)
		_foot_vis[i].global_transform = Transform3D(Basis.looking_at(vis_fwd, Vector3.UP), fp)

	_label.global_position = tp + Vector3(0, 1.25, 0)
	_update_eyes(delta)


func _two_bone(seg: int, joint_idx: int, a: Vector3, b: Vector3, length: float, pole: Vector3) -> void:
	var d := b - a
	var dist := d.length()
	var dir := d / dist if dist > 0.0001 else Vector3.DOWN
	var half := length * 0.5
	var sag := sqrt(maxf(half * half - dist * dist * 0.25, 0.0))
	var p := pole - dir * pole.dot(dir)
	p = p.normalized() if p.length() > 0.001 else Vector3.FORWARD
	var mid := (a + b) * 0.5 + p * sag
	_place_segment(_limbs[seg], a, mid)
	_place_segment(_limbs[seg + 1], mid, b)
	_joints_vis[joint_idx].global_position = mid


func _place_segment(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var l := d.length()
	if l < 0.001:
		mi.visible = false
		return
	mi.visible = true
	var y := d / l
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := y.cross(ref).normalized()
	var z := x.cross(y)
	mi.global_transform = Transform3D(Basis(x, y * l, z), (a + b) * 0.5)


## Googly eyes: pupils slosh around when the body accelerates.
func _update_eyes(delta: float) -> void:
	if delta <= 0.0:
		return
	var tp := torso.global_position
	var vel := (tp - _last_torso_pos) / delta
	var acc := (vel - _last_torso_vel) / delta
	_last_torso_pos = tp
	_last_torso_vel = vel
	acc = acc.limit_length(60.0)
	var inv := torso.global_basis.inverse()
	var a_local := inv * acc
	var g_local := inv * Vector3.DOWN
	for i in 2:
		var push := Vector2(-a_local.x, -a_local.y) * 0.06 + Vector2(g_local.x, g_local.y) * 0.3
		_pupil_vel[i] += (push - _pupil_off[i] * 14.0) * delta
		_pupil_vel[i] *= exp(-2.0 * delta)
		_pupil_off[i] += _pupil_vel[i] * delta
		if _pupil_off[i].length() > 0.038:
			_pupil_off[i] = _pupil_off[i].normalized() * 0.038
			_pupil_vel[i] *= -0.5
		var off := _pupil_off[i]
		_pupils[i].position = _eye_centres[i] + Vector3(off.x, off.y, -0.06)
