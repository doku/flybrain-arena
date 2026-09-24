class_name FlyPhysics
extends CharacterBody3D

signal wing_torn(wing_side: String)
signal knocked_out()
signal landed_strike(target_part: String)

@export var fly_id: String = "alpha" # "alpha" or "beta"
@export var is_disabled: bool = false
# Killing-blow ledger: every health subtraction routes through
# take_damage so the battle report can name the final blow.
var last_damage_source := ""
var last_damage_amount := 0.0
var last_damage_t := 0.0


func take_damage(amount: float, source: String) -> void:
	if is_disabled:
		return
	health -= amount
	last_damage_source = source
	last_damage_amount = amount
	last_damage_t = fly_time
@export var health: float = 100.0

# Flight aerodynamics constants (fruit-fly agile: hover-capable, snap turns).
# Tuned for watchable jousts: cruise ~5 m/s, full thrust 12 m/s.
# Thrust gain is calibrated so cruise equilibrium EQUALS target speed:
# per-tick add = target*gain*dt vs drag multiply drag_coeff^(60dt);
# v* = target*gain/(60*(1-drag_coeff)) = target*1.8/1.8 = target.
# (The old gain 5.0 converged to 2.78x target: full thrust flew 33 m/s
# and ram 46 m/s while max_speed claimed 12 - the G2-wild zoom bug.)
@export var base_speed: float = 3.0
@export var max_speed: float = 12.0
@export var turn_rate: float = 8.0
@export var pitch_rate: float = 2.5
@export var roll_rate: float = 3.0
@export var drag_coeff: float = 0.97
const THRUST_GAIN: float = 1.8
# Hard speed cap. Legit peak is a full-speed lunge (12 + 7 = 19), so
# 1.6x = 19.2 clears every legal transient (ram 18, lunge 19, clash
# bounce <= 18) and only true runaways ever touch it. Time pinned at
# the cap marks the fly ILLEGAL (speed_exploit) - the zoom signature.
const SPEED_CAP_MULT: float = 1.6
const EXPLOIT_MIN_TIME: float = 3.0
const EXPLOIT_FRAC: float = 0.3
var capped_time: float = 0.0
var fly_time: float = 0.0
var peak_speed: float = 0.0
var speed_exploit: bool = false
# Seizure watch (behavioral, motor-output level): a saturated yaw command
# that keeps spinning the body, sustained over SEIZURE_WINDOW, latches
# `seizing` and drains health in small increments until SEIZURE_RECOVER
# of clear flight. Punishment flows through the existing KO path
# (health -> 0 disables, rival credited). Thresholds mirror
# train_homing.update_seizure - keep the two in sync.
const SEIZURE_YAW_CMD := 0.85
const SEIZURE_YAW_RATE := 2.0
const SEIZURE_WINDOW := 1.5
const SEIZURE_RECOVER := 1.0
const SEIZURE_DRAIN := 3.0
var seizure_time := 0.0
var seizure_clear := 0.0
var seizing := false
var seizure_events := 0


func seizure_tick(yaw_cmd: float, yaw_rate: float, delta: float) -> bool:
	# State machine only (no scene reads): headless-testable. Returns
	# the latched seizing flag; onset counted by the caller.
	if absf(yaw_cmd) > SEIZURE_YAW_CMD and absf(yaw_rate) > SEIZURE_YAW_RATE:
		seizure_time += delta
		seizure_clear = 0.0
	else:
		seizure_clear += delta
		if seizure_clear >= SEIZURE_RECOVER:
			seizure_time = 0.0
	seizing = seizure_time >= SEIZURE_WINDOW and seizure_clear < SEIZURE_RECOVER
	return seizing

# Hard altitude limits: a tipped/crippled fly can otherwise convert its huge
# forward speed into an endless vertical climb the soft trim can't catch.
const CEILING_Y: float = 30.0
const FLOOR_Y: float = 0.5
# Soft play boundary: beyond this horizontal range the fly gets steered and
# pushed home so fights stay inside the forest instead of leaving the map.
const BOUNDARY_R: float = 55.0

# Dynamic flight states
var current_thrust: float = 0.2
var current_yaw_torque: float = 0.0
var current_pitch_torque: float = 0.0
var current_roll_torque: float = 0.0
var is_ram_burst: bool = false
var is_emergency_evade: bool = false
# Command-hold age: the brain answers every few hundred ms (dual-LIF
# step budget), so each torque command would otherwise hold at FULL
# value across many physics frames (~1 rad per yaw command) while flying
# on stale senses — overshoot, reverse, overshoot: the spin-then-spin-back
# wobble. Holding torques decay so each command steers a bounded arc and
# fresh commands always win. Thrust is sustained (speed continuity and
# the low-thrust brake depend on it). hold_tau tracks the measured reply
# cadence (shared across both flies for fairness — see ArenaManager);
# 0.15 s is the full-speed default.
var cmd_age: float = 0.0
var hold_tau: float = 0.15

var left_wing_intact: bool = true
var right_wing_intact: bool = true
var wing_flutter_time: float = 0.0

# End-of-round landing ceremony: 0 = fighting (normal), 1 = loser drops
# upside-down, 2 = winner lowers upright. Brain input ignored while
# landing; is_disabled is left untouched so the loser stays immune to
# further hits. reset_fly clears it.
var landing_mode: int = 0
const LAND_POS_Y: float = 0.62
const LOSER_SINK_RATE: float = 3.0
const WINNER_SINK_RATE: float = 1.4

# Spear lunge attack (mouth-motor driven): a short forward impulse plus
# a visible spear extension. Gated by cooldown so strikes stay discrete.
var spear_thrust_cmd: float = 0.0
var lunge_cooldown: float = 0.0
var lunge_t: float = 0.0
var lunge_count: int = 0
var spear_root: Node3D = null
const LUNGE_COOLDOWN: float = 1.2
const LUNGE_TIME: float = 0.35
const LUNGE_DIST: float = 0.35
const LUNGE_KICK: float = 7.0
const SPIKE_BASE_POS := Vector3(0.32, -0.12, -1.35)
# A torn wing forfeits the fight immediately (round ends, rival credited).
# There's no crawling state: any wing loss is a loss.

# Reference to rival fly in arena
var rival: FlyPhysics = null

# Scent and visual tracking
var prev_rival_dist: float = 50.0
# Scent dynamics (rival-detection channel): smoothed total for surge,
# lost-timer for search behavior, free-running cast phase. The gradient
# floor never dies (lost flies must re-acquire), so "lost" is defined
# floor-relative: total at/below LOST_THRESH with nothing visible.
const LOST_THRESH: float = 0.12
const LOST_CAST_RATE: float = 0.8
var scent_prev_smooth: float = -1.0
var scent_lost_time: float = 0.0
var scent_cast_phase: float = 0.0

# Antennal-gyro tracking: previous attitude for per-tick angular rates.
# Synced on reset; re-syncs automatically on the first sensory read.
var prev_basis: Basis = Basis()
var basis_init: bool = false

# Obstacle impact state (tree crashes)
var obstacle_hit_cooldown: float = 0.0
const OBSTACLE_RAY_LENGTH: float = 14.0
const TREE_RAY_LEFT_ANGLE: float = deg_to_rad(35.0)

# Spike/thorax clash state: a resolved joust needs a beat to re-arm so a
# pressed pair can't machine-gun damage (or self-cancel knockback) every
# frame while the trigger Areas stay overlapped.
var clash_cooldown: float = 0.0
const CLASH_COOLDOWN: float = 0.9

@onready var front_spike_area: Area3D = $FrontSpikeArea
@onready var thorax_hurtbox: Area3D = $ThoraxHurtbox
@onready var left_wing_hurtbox: Area3D = $LeftWingHurtbox
@onready var right_wing_hurtbox: Area3D = $RightWingHurtbox
@onready var left_wing_mesh: Node3D = $VisualModel/LeftWing
@onready var right_wing_mesh: Node3D = $VisualModel/RightWing

func _ready() -> void:
	_build_visual_model()
	front_spike_area.area_entered.connect(_on_spike_hit_area)

# Beauty-pass material refs: chitin (thorax + eyes) and wing membranes
# are per-fly ShaderMaterials; the manager pushes team colors + hit
# flashes here instead of poking StandardMaterial3D (see set_team_color
# / flash_hit). Shared scan meshes are untouched, so both rivals keep
# their own uniforms.
var body_mat: ShaderMaterial
var eye_mat: ShaderMaterial
var membrane_mat: ShaderMaterial
var spear_glow: MeshInstance3D
var spear_glow_mat: StandardMaterial3D
var flash_energy := 0.0

func set_team_color(color: Color) -> void:
	if body_mat == null:
		return
	body_mat.set_shader_parameter("team_tint",
		Vector3(color.r, color.g, color.b))
	if spear_glow_mat != null:
		spear_glow_mat.albedo_color = Color(color.r, color.g, color.b, 0.0)
	if membrane_mat != null:
		# Rivals shimmer out of sync; membranes keep a pearly white.
		var phase := 0.0 if fly_id != "beta" else PI
		membrane_mat.set_shader_parameter("phase", phase)

func flash_hit(strength: float = 1.0) -> void:
	flash_energy = maxf(flash_energy, strength)

func apply_brain_controls(ctrl: Dictionary) -> void:
	if is_disabled:
		return
	current_thrust = ctrl.get("thrust", 0.2)
	current_yaw_torque = ctrl.get("yaw_torque", 0.0)
	current_pitch_torque = ctrl.get("pitch_torque", 0.0)
	current_roll_torque = ctrl.get("roll_torque", 0.0)
	is_ram_burst = ctrl.get("ram_burst", false)
	is_emergency_evade = ctrl.get("emergency_evade", false)
	spear_thrust_cmd = clampf(float(ctrl.get("spear_thrust", 0.0)), 0.0, 1.0)
	cmd_age = 0.0

func get_sensory_data(frame_delta: float = 0.05) -> Dictionary:
	if not is_instance_valid(rival):
		return {
			"pheromone_conc_left": 0.0,
			"pheromone_conc_right": 0.0,
			"scent_lost": 0.0,
			"scent_cast": 0.0,
			"scent_surge": 0.0,
			"visual_target_azimuth": 0.0,
			"visual_target_elevation": 0.0,
			"visual_target_visible": false,
			"visual_looming_rate": 0.0,
		"angular_yaw_rate": 0.0,
		"angular_pitch_rate": 0.0,
		"angular_roll_rate": 0.0,
		"tail_chase": 0.0,
		"visual_flow_ventral": 0.0,
		"visual_flow_lateral": 0.0,
		"visual_flow_expansion": 0.0,
		"visual_flow_climb": 0.0,
			"visual_sec_presence": [],
			"visual_sec_size": [],
			"visual_sec_loom": [],
			"visual_sec_tree": []
		}

	# 0. Antennal-gyro rates: attitude delta since the last read, axis by
	# axis, normalized by each axis' own command rate (yaw/turn_rate,
	# pitch/pitch_rate, roll/roll_rate). The arena reads every physics
	# frame, so the caller passes its real frame delta (NOT a fixed tick:
	# reads happen at 60 Hz while brain ticks go out at 20 Hz).
	# Sign convention mirrors the commands: +yaw = turning right,
	# +pitch = nose up, +roll = bank right
	# (rotate_y(-yaw) / rotate_x(+pitch) / rotate_z(-roll)).
	var curr_basis: Basis = global_transform.basis.orthonormalized()
	var yaw_rate := 0.0
	var pitch_rate_now := 0.0
	var roll_rate_now := 0.0
	if basis_init:
		var dt := maxf(frame_delta, 0.001)
		var e: Vector3 = (prev_basis.inverse() * curr_basis).get_euler()
		yaw_rate = clampf(-e.y / dt / turn_rate, -1.0, 1.0)
		pitch_rate_now = clampf(e.x / dt / pitch_rate, -1.0, 1.0)
		roll_rate_now = clampf(-e.z / dt / roll_rate, -1.0, 1.0)
	prev_basis = curr_basis
	basis_init = true

	var rival_pos = rival.global_position
	var to_rival = rival_pos - global_position
	var dist = to_rival.length()

	# 1. Rival looming (rate of optical expansion toward the rival). Split from
	# wood: rivals drive LC4, trunks drive LPLC2, so the brain and dopamine
	# can train the two policies apart instead of sharing one channel.
	var delta_dist = prev_rival_dist - dist
	var rival_looming = clampf((delta_dist / maxf(dist, 1.0)) * 5.0, 0.0, 1.0)
	prev_rival_dist = dist

	# 1b. Tree cone: three nose rays (-35 / 0 / +35 deg) so the brain knows
	# WHICH side the bark looms on. Side-gating (LPLC2-L/R + contralateral
	# wiring) is what lets the fly steer away from wood instead of into it.
	var fwd = (-global_transform.basis.z).normalized()
	var tree_left = _ray_loom(Basis(Vector3.UP,  TREE_RAY_LEFT_ANGLE) * fwd)
	var tree_ahead = _ray_loom(fwd)
	var tree_right = _ray_loom(Basis(Vector3.UP, -TREE_RAY_LEFT_ANGLE) * fwd)
	var tree_looming = maxf(tree_left, maxf(tree_ahead, tree_right))

	# 2. Dual-Antenna Pheromone Sampling (Long-range gradient + Head-shadow contrast)
	var forward = -global_transform.basis.z
	var right_dir = global_transform.basis.x
	var to_rival_dir = to_rival.normalized()

	# Scent never dies with distance: linear falloff over 150m (effectively
	# infinite inside the play area) with a constant gradient slope, so a
	# separated fly always has a trail to follow and keeps pursuit.
	# Directional smelling: strength follows where the nose points
	# (nose-on-target = full scent, facing away = faint trace), so the
	# odor gradient leads the fly toward the rival instead of surrounding
	# it equally from all sides.
	var nose_dot = forward.dot(to_rival_dir)
	var face = 0.15 + 0.85 * clampf((nose_dot + 0.2) / 1.2, 0.0, 1.0)
	var c_base = clampf((1.0 - dist / 150.0) * face, 0.0, 1.0)

	# Directional antenna orientations (+/- 45 degrees forward-lateral)
	var ant_dir_left = (forward - right_dir * 0.7).normalized()
	var ant_dir_right = (forward + right_dir * 0.7).normalized()

	# Head-shadow directional attenuation: shielded antenna receives less odor
	var align_left = ant_dir_left.dot(to_rival_dir)
	var align_right = ant_dir_right.dot(to_rival_dir)

	var factor_left = 0.45 + 0.55 * clampf((align_left + 0.3) / 1.3, 0.0, 1.0)
	var factor_right = 0.45 + 0.55 * clampf((align_right + 0.3) / 1.3, 0.0, 1.0)

	var c_left = clampf(c_base * factor_left, 0.0, 1.0)
	var c_right = clampf(c_base * factor_right, 0.0, 1.0)

	# 3. Visual Hemisphere Targeting
	var local_rival_dir = global_transform.basis.inverse() * to_rival.normalized()
	# In Godot forward is -Z
	var forward_dot = -local_rival_dir.z
	var is_visible = forward_dot > 0.1 # Within front 160-degree field of view

	var azimuth_deg = rad_to_deg(atan2(local_rival_dir.x, -local_rival_dir.z))
	var elevation_deg = rad_to_deg(asin(clampf(local_rival_dir.y, -1.0, 1.0)))

	# 4. Tail-chase signal: am I behind the rival (its butt faces me) while
	# facing its tail? Same rear-hemisphere convention as the kill rule, plus
	# a gaze gate so blind trailing doesn't count.
	var to_self_from_rival = (global_position - rival_pos).normalized()
	var rival_local = rival.global_transform.basis.inverse() * to_self_from_rival
	var behind_rival = rival_local.z > 0.15
	var tail_chase = 1.0 if (behind_rival and is_visible and absf(azimuth_deg) < 35.0) else 0.0

	# 2b. Scent dynamics: surge (rising total = closing), lost timer and
	# cast bias for search. Smoothed total (0.5 s tau) so per-frame noise
	# never fires the surge; sentinel snaps on first read (no spawn kick).
	var scent_total = c_left + c_right
	var dt := maxf(frame_delta, 0.001)
	if scent_prev_smooth < 0.0:
		scent_prev_smooth = scent_total
	var scent_smooth = scent_prev_smooth + (scent_total - scent_prev_smooth) * minf(1.0, dt * 2.0)
	var scent_surge = clampf((scent_smooth - scent_prev_smooth) / dt * 3.0, 0.0, 1.0)
	scent_prev_smooth = scent_smooth
	if scent_total > LOST_THRESH or is_visible:
		scent_lost_time = 0.0
	else:
		scent_lost_time += dt
	scent_cast_phase += dt * LOST_CAST_RATE
	var scent_cast = sin(scent_cast_phase)

	# 5. Panoramic sector grid (retina scheme): 7 azimuth columns over the
	# full circle x 3 elevation bands = 21 cells. Rival occupies exactly
	# one cell (presence + angular size + loom); tree rays fan all 7
	# columns (elevation ignored for wood). Rear cells track only.
	var sec_presence: Array = []
	var sec_size: Array = []
	var sec_loom: Array = []
	var sec_tree: Array = []
	sec_presence.resize(21)
	sec_size.resize(21)
	sec_loom.resize(21)
	sec_tree.resize(21)
	sec_presence.fill(0.0)
	sec_size.fill(0.0)
	sec_loom.fill(0.0)
	sec_tree.fill(0.0)
	var az_cols: Array = [-150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0]
	var wrapped_az := wrapf(azimuth_deg, -180.0, 180.0)
	var best_col := 3
	var best_d := 999.0
	for ci in range(7):
		var dd := absf(wrapf(wrapped_az - az_cols[ci], -180.0, 180.0))
		if dd < best_d:
			best_d = dd
			best_col = ci
	var band := 1
	if elevation_deg > 20.0:
		band = 0
	elif elevation_deg < -20.0:
		band = 2
	var rcell := band * 7 + best_col
	sec_presence[rcell] = 1.0
	sec_size[rcell] = clampf(1.1 / maxf(dist, 0.5), 0.0, 1.0)
	sec_loom[rcell] = rival_looming
	for ci in range(7):
		var ray_dir: Vector3 = Basis(Vector3.UP, deg_to_rad(-az_cols[ci])) * fwd
		var wood := _ray_loom(ray_dir)
		# Nose rays carry no elevation: same occupancy in all 3 bands.
		sec_tree[ci] = wood
		sec_tree[7 + ci] = wood
		sec_tree[14 + ci] = wood

	return {
		"pheromone_conc_left": c_left,
		"pheromone_conc_right": c_right,
		"scent_lost": scent_lost_time,
		"scent_cast": scent_cast,
		"scent_surge": scent_surge,
		"visual_target_azimuth": azimuth_deg,
		"visual_target_elevation": elevation_deg,
		"visual_target_visible": is_visible,
		"visual_rival_looming": rival_looming,
		"visual_tree_left_looming": tree_left,
		"visual_tree_ahead_looming": tree_ahead,
		"visual_tree_right_looming": tree_right,
		"visual_tree_looming": tree_looming,
		"visual_looming_rate": maxf(rival_looming, tree_looming),
		"altitude": global_position.y,
		"angular_yaw_rate": yaw_rate,
		"angular_pitch_rate": pitch_rate_now,
		"angular_roll_rate": roll_rate_now,
		"tail_chase": tail_chase,
		"visual_flow_ventral": _flow_ventral(),
		"visual_flow_lateral": _flow_lateral(),
		"visual_flow_expansion": _flow_expansion(),
		"visual_flow_climb": _flow_climb(),
		"visual_sec_presence": sec_presence,
		"visual_sec_size": sec_size,
		"visual_sec_loom": sec_loom,
		"visual_sec_tree": sec_tree
	}

func _flow_ventral() -> float:
	# Translational optic flow: horizontal groundspeed over altitude,
	# scaled so cruise (~5 m/s at ~7 m) reads ~0.35 (FLOW_CRUISE).
	var hspeed := Vector2(velocity.x, velocity.z).length()
	return clampf(hspeed / maxf(global_position.y, 1.0) / 2.0, 0.0, 1.0)


func _flow_lateral() -> float:
	# Sideways body velocity (signed: + = drifting right).
	var side := velocity.dot(global_transform.basis.x)
	return clampf(side / 6.0, -1.0, 1.0)


func _flow_expansion() -> float:
	# Ground expansion on descent (~ time-to-contact inverted).
	return clampf(maxf(0.0, -velocity.y) / maxf(global_position.y, 1.0) / 2.0, 0.0, 1.0)


func _flow_climb() -> float:
	# Upward visual flow while climbing (mirror of expansion).
	return clampf(maxf(0.0, velocity.y) / maxf(global_position.y, 1.0) / 2.0, 0.0, 1.0)


func _ray_loom(ray_dir: Vector3) -> float:
	# Nose-ray trunk proximity, 0..1 over the 14m detection range. Rival is
	# excluded - rival approach is measured directly, not conflated with wood.
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		global_position, global_position + ray_dir * OBSTACLE_RAY_LENGTH)
	var excl: Array[RID] = [get_rid()]
	if is_instance_valid(rival):
		excl.append(rival.get_rid())
	query.exclude = excl
	var hit = space.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	var d = global_position.distance_to(hit["position"])
	return clampf((OBSTACLE_RAY_LENGTH - d) / OBSTACLE_RAY_LENGTH, 0.0, 1.0)

func begin_landing(upright: bool) -> void:
	# End-of-round ceremony: loser (upright=false) drops upside-down,
	# winner lowers onto its feet. Stops neuro motion; takes
	# precedence over the disabled death spiral (checked first below).
	landing_mode = 2 if upright else 1
	velocity = Vector3.ZERO


func landing_done() -> bool:
	return landing_mode > 0 and global_position.y <= LAND_POS_Y + 0.05


func _landing_step(delta: float) -> void:
	# Graceful descent: sink straight down while slerping to the
	# ceremony attitude (winner: wings-level nose-forward; loser:
	# same heading, belly-up). No bounce, no spiral. The winner keeps
	# beating its intact wings like it's still alive (faster victory
	# flutter); the loser's wings stay frozen.
	if landing_mode == 2:
		wing_flutter_time += delta * 90.0
		var flap := sin(wing_flutter_time) * 0.5
		if left_wing_intact and is_instance_valid(left_wing_mesh):
			left_wing_mesh.rotation.z = flap
		if right_wing_intact and is_instance_valid(right_wing_mesh):
			right_wing_mesh.rotation.z = -flap
	var rate := WINNER_SINK_RATE if landing_mode == 2 else LOSER_SINK_RATE
	global_position.y = maxf(global_position.y - rate * delta, LAND_POS_Y)
	var fwd := -global_transform.basis.z
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var up := Vector3.UP if landing_mode == 2 else Vector3.DOWN
	var z_axis := -fwd
	var x_axis := up.cross(z_axis)
	if x_axis.length() < 0.05:
		x_axis = Vector3.RIGHT
	else:
		x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	var target := Basis(x_axis, y_axis, z_axis).orthonormalized()
	var turn := 1.5 if landing_mode == 2 else 2.5
	global_transform.basis = global_transform.basis.orthonormalized().slerp(
		target, clampf(turn * delta, 0.0, 1.0))


func _physics_process(delta: float) -> void:
	clash_cooldown = maxf(0.0, clash_cooldown - delta)
	# Hit-flash decay (visual only, never touches sim state).
	if flash_energy > 0.0:
		flash_energy = maxf(0.0, flash_energy - delta * 2.5)
		if body_mat != null:
			body_mat.set_shader_parameter("flash_energy", flash_energy)
		if eye_mat != null:
			eye_mat.set_shader_parameter("flash_energy", flash_energy * 0.7)
	if landing_mode > 0:
		_landing_step(delta)
		return
	if is_disabled:
		# Death spiral: disabled knockout falling into grass
		velocity.y -= 18.0 * delta # Gravity
		velocity.x *= pow(0.95, delta * 60.0)
		velocity.z *= pow(0.95, delta * 60.0)
		rotate_z(15.0 * delta)
		rotate_y(8.0 * delta)
		move_and_slide()
		_enforce_altitude_limits()
		return

	# Wing flutter animation
	wing_flutter_time += delta * 60.0
	var flap = sin(wing_flutter_time) * 0.4
	if left_wing_intact and is_instance_valid(left_wing_mesh):
		left_wing_mesh.rotation.z = flap
	if right_wing_intact and is_instance_valid(right_wing_mesh):
		right_wing_mesh.rotation.z = -flap

	# Leaky command hold (see cmd_age): stale torque commands decay so a
	# slow brain steers bounded arcs instead of winding up spins.
	cmd_age += delta
	var hold := exp(-cmd_age / hold_tau)
	var yaw_cmd := current_yaw_torque * hold
	var pitch_cmd := current_pitch_torque * hold
	var roll_cmd := current_roll_torque * hold

	# Flight speed and thrust
	var speed_multiplier = 1.5 if is_ram_burst else 1.0
	var target_speed = base_speed + (max_speed - base_speed) * current_thrust * speed_multiplier
	var forward_vec = -global_transform.basis.z

	# Yaw rotation (snapshot basis first: the seizure watch measures the
	# actual turn that results, so a saturated command against a tree
	# reads as stuck, not seizing).
	var _pre_yaw_basis := global_transform.basis
	rotate_y(-yaw_cmd * turn_rate * delta)

	# Pitch rotation (nose up positive). Previously nothing ever commanded
	# pitch, so a tipped fly could never recover - it just flew wherever its
	# nose pointed until it hit the ceiling.
	rotate_x(pitch_cmd * pitch_rate * delta)

	# Roll rotation (bank right positive). The brain commands the bank and
	# a gentle auto-level mops up residual drift. During an emergency
	# evade the reflex owns the roll axis outright (full auto-level, no
	# brain command) so the two can never fight each other. With no roll
	# command (base scheme) the full legacy leveling rate applies, so
	# uncommanded flight is exactly as stable as before.
	if is_emergency_evade:
		_auto_level_roll(delta)
	else:
		rotate_z(-roll_cmd * roll_rate * delta)
		var lvl := 2.5 if absf(roll_cmd) < 0.01 else 1.0
		_auto_level_roll(delta, lvl)

	# Seizure watch: measured yaw rate over this tick vs the applied
	# (hold-decayed) command. Onset logs once; the drain ticks down in
	# small increments until clear flight or knockout.
	var yaw_rate_now := 0.0
	if delta > 0.0:
		var _yaw_e := (_pre_yaw_basis.inverse() * global_transform.basis).get_euler()
		yaw_rate_now = clampf(-_yaw_e.y / delta, -8.0, 8.0)
	var _was_seizing := seizing
	seizure_tick(yaw_cmd, yaw_rate_now, delta)
	if seizing and not _was_seizing:
		seizure_events += 1
		print(fly_id, " SEIZURE detected - draining health.")
	if seizing:
		take_damage(SEIZURE_DRAIN * delta, "seizure")
		if health <= 0.0 and not is_disabled:
			inflict_lethal_strike()
			print(fly_id, " seized out of the sky!")

	# Pitch & altitude auto-trim (stay within 2m to 12m fly combat ceiling)
	var alt = global_position.y
	if alt < 3.0:
		velocity.y += 15.0 * delta
	elif alt > 14.0:
		velocity.y -= 15.0 * delta
	else:
		velocity.y *= pow(0.9, delta * 60.0)

	# Emergency evade reflex (Giant Fiber)
	if is_emergency_evade:
		rotate_z(8.0 * delta)
		velocity.y -= 25.0 * delta

	# Spear lunge attack (mouth-motor driven): a forward impulse plus a
	# visible spear thrust, one discrete strike per cooldown.
	lunge_cooldown = maxf(0.0, lunge_cooldown - delta)
	if spear_thrust_cmd > 0.4 and lunge_cooldown <= 0.0:
		velocity += (-global_transform.basis.z).normalized() * LUNGE_KICK * spear_thrust_cmd
		lunge_cooldown = LUNGE_COOLDOWN
		lunge_t = LUNGE_TIME
		lunge_count += 1
	if lunge_t > 0.0:
		lunge_t = maxf(0.0, lunge_t - delta)
		var ext := LUNGE_DIST * sin(PI * (1.0 - lunge_t / LUNGE_TIME))
		if is_instance_valid(spear_root):
			spear_root.position.z = -ext
		front_spike_area.position = SPIKE_BASE_POS + Vector3(0, 0, -ext)
		# Streak sheath swells with extension (visual only).
		if is_instance_valid(spear_glow) and spear_glow_mat != null:
			spear_glow.visible = true
			var glow_a := 0.55 * clampf(ext / LUNGE_DIST, 0.0, 1.0)
			var gc := spear_glow_mat.albedo_color
			gc.a = glow_a
			spear_glow_mat.albedo_color = gc
	elif is_instance_valid(spear_root) and spear_root.position.z != 0.0:
		spear_root.position.z = 0.0
		front_spike_area.position = SPIKE_BASE_POS
		if is_instance_valid(spear_glow):
			spear_glow.visible = false

	# Forward motion with frame-rate-independent damping. The old per-frame
	# *= drag made the fly's glide depend on fps (heavy/oily below 60),
	# so it slid past turns into trees. Low thrust now brakes actively so
	# the fly can stop in place and spin around (snapshot pre-move speed
	# for impacts).
	var pre_move_speed = velocity.length()
	velocity += forward_vec * target_speed * delta * THRUST_GAIN
	velocity *= pow(drag_coeff, delta * 60.0)
	if current_thrust < 0.25:
		velocity *= pow(0.85, delta * 60.0)
	# Hard speed cap: lunge/clash/ram transients may spike, but nothing
	# sustains above max_speed*SPEED_CAP_MULT. Time spent pinned at the
	# cap marks the fly ILLEGAL (speed_exploit) - the zoom signature.
	var spd := velocity.length()
	peak_speed = maxf(peak_speed, spd)
	var cap := max_speed * SPEED_CAP_MULT
	if spd > cap:
		velocity *= cap / spd
		capped_time += delta
	fly_time += delta
	speed_exploit = capped_time > EXPLOIT_MIN_TIME and fly_time > 0.0 \
		and capped_time / fly_time > EXPLOIT_FRAC

	move_and_slide()
	_enforce_altitude_limits()
	_enforce_play_boundary(delta)
	_handle_obstacle_impacts(pre_move_speed, delta)
	_scan_pressed_clash()

func _enforce_altitude_limits() -> void:
	if global_position.y > CEILING_Y:
		global_position.y = CEILING_Y
		if velocity.y > 0.0:
			velocity.y = 0.0
	elif global_position.y < FLOOR_Y:
		global_position.y = FLOOR_Y
		if velocity.y < 0.0:
			velocity.y = 0.0

func _auto_level_roll(delta: float, level_rate: float = 2.5) -> void:
	# Roll is otherwise a random walk (evade rolls + collision tips, nothing
	# un-rolls). While inverted, yaw/pitch act about flipped body axes so the
	# brain's corrections steer backwards - the "confused" upside-down fly.
	# Slerp toward the same-forward wings-level attitude: corrects ONLY roll,
	# never fights yaw/pitch. Skipped in vertical flight (roll undefined).
	var fwd = -global_transform.basis.z
	if absf(fwd.dot(Vector3.UP)) > 0.95:
		return
	var level = Transform3D(Basis(), global_position).looking_at(global_position + fwd, Vector3.UP)
	global_transform.basis = global_transform.basis.orthonormalized().slerp(level.basis.orthonormalized(), clampf(level_rate * delta, 0.0, 1.0))

func _enforce_play_boundary(delta: float) -> void:
	var flat := Vector2(global_position.x, global_position.z)
	var d := flat.length()
	if d <= BOUNDARY_R:
		return
	var inward := -flat / d
	# Yaw with forward (-sin t, -cos t): steer nose toward center, <=3 rad/s.
	var desired_yaw = atan2(-inward.x, -inward.y)
	var yaw_diff = wrapf(desired_yaw - rotation.y, -PI, PI)
	rotate_y(clampf(yaw_diff, -3.0 * delta, 3.0 * delta))
	velocity.x += inward.x * 30.0 * delta
	velocity.z += inward.y * 30.0 * delta

func _handle_obstacle_impacts(impact_speed: float, delta: float) -> void:
	# Tree trunk collisions cost chitin: fast hits tear wings, hard hits cost
	# health, zero health augers the fly in (knockout, rival credited).
	# Cooldown stops a single slide from shredding the fly frame by frame.
	obstacle_hit_cooldown = maxf(0.0, obstacle_hit_cooldown - delta)
	if obstacle_hit_cooldown > 0.0:
		return
	for i in range(get_slide_collision_count()):
		var collider = get_slide_collision(i).get_collider()
		if collider == null or not (collider is StaticBody3D):
			continue
		if not (collider as Node).is_in_group("obstacle"):
			continue
		# Tiers sit above cruise (~5-8 m/s: safe) and at/below full
		# thrust (12 m/s: lethal), so cruising the forest is safe and
		# only hot flight into bark is punished.
		if impact_speed > 11.0:
			tear_wing("left" if randf() < 0.5 else "right")
			take_damage(50.0, "tree_slam")
			obstacle_hit_cooldown = 1.5
			print(fly_id, " SLAMMED a tree at ", snappedf(impact_speed, 0.1), " m/s! Wing torn.")
		elif impact_speed > 6.5:
			take_damage(15.0, "tree_clip")
			obstacle_hit_cooldown = 1.0
			print(fly_id, " clipped a tree at ", snappedf(impact_speed, 0.1), " m/s.")
		else:
			continue
		if health <= 0.0 and not is_disabled:
			inflict_lethal_strike()
			print(fly_id, " crashed out of the sky!")
		break

func _attacker_in_victim_front_arc(victim: FlyPhysics) -> bool:
	# True if this fly approaches from inside the victim's frontal visual
	# field (same >0.1 forward-dot convention as get_sensory_data).
	var to_attacker = global_position - victim.global_position
	if to_attacker.length() < 0.001:
		return true
	var local_dir = victim.global_transform.basis.inverse() * to_attacker.normalized()
	return -local_dir.z > 0.1

func _scan_pressed_clash() -> void:
	# area_entered only fires when Areas touch - it does NOT re-fire while a
	# pair stays rammed tip-to-tip with no relative velocity (the state the
	# old code froze in). Sweep overlapping areas once per cooldown so a
	# pressed contact still resolves into a clash (damage + give) instead of
	# sticking forever.
	if is_disabled or clash_cooldown > 0.0:
		return
	var overlaps := front_spike_area.get_overlapping_areas()
	for a in overlaps:
		var other = a.get_parent()
		if other is FlyPhysics and other != self:
			_on_spike_hit_area(a)
			return

func _facing_victim(victim: FlyPhysics) -> bool:
	# Head-on intent: the victim is roughly ahead of this fly's nose.
	var to_v = victim.global_position - global_position
	if to_v.length() < 0.001:
		return true
	var local = global_transform.basis.inverse() * to_v.normalized()
	return -local.z > 0.3

func _on_spike_hit_area(area: Area3D) -> void:
	if is_disabled:
		return
	
	var victim = area.get_parent()
	if victim == self or not (victim is FlyPhysics):
		return

	var rel_vel = (velocity - victim.velocity).length()

	if area.name == "LeftWingHurtbox" or area.name == "RightWingHurtbox":
		if rel_vel < 4.0:
			# Too slow to pierce chitin
			return
		victim.tear_wing("left" if area.name == "LeftWingHurtbox" else "right")
		_spike_wound(victim)
		landed_strike.emit("wing")
		print(fly_id, " impaled ", victim.fly_id, "'s ", area.name, "! (Rel Speed: ", rel_vel, ")")
	elif area.name == "ThoraxHurtbox":
		# Rear-aspect kill rule: thorax punctures only count when the attacker
		# comes from the victim's blind spot (victim cannot see them). A
		# head-on thorax hit means the victim saw it coming and parried:
		# resolve as a joust clash instead of a kill. Disabled (doomed)
		# victims can still be finished from any angle.
		if not victim.is_disabled and _attacker_in_victim_front_arc(victim):
			_resolve_joust(victim)
		else:
			victim.last_damage_source = "thorax_puncture"
			victim.last_damage_amount = 0.0
			victim.last_damage_t = victim.fly_time
			victim.inflict_lethal_strike()
			landed_strike.emit("thorax")
			print(fly_id, " landed rear-aspect THORAX PUNCTURE on ", victim.fly_id, "!")
	elif area.name == "FrontSpikeArea":
		# Spike-to-spike head-on joust: resolved once (deduped), both take a
		# body spike wound, and one side randomly gives so the pair breaks
		# apart instead of self-cancelling into a permanent ram.
		if not victim.is_disabled and (rel_vel >= 2.0 or _facing_victim(victim)):
			_resolve_spike_clash(victim)

func _resolve_spike_clash(victim: FlyPhysics) -> void:
	if clash_cooldown > 0.0 or victim.clash_cooldown > 0.0:
		return
	# Both flies' areas overlap in the same physics frame. If both negated
	# velocity for self AND opponent, the double negation cancels to a
	# 0.64x forward shove - the old "ram into each other not moving" bug.
	# Only the lower-instance-id fly resolves; the other does nothing.
	if get_instance_id() > victim.get_instance_id():
		return
	var gives_away := self if randf() < 0.5 else victim
	var braces := victim if gives_away == self else self
	# Both sinks a spike into the other's body on the way apart.
	for f in [self, victim]:
		if not f.is_disabled:
			f.take_damage(25.0, "spike_clash")
			if f.health <= 0.0:
				f.inflict_lethal_strike()
				print(f.fly_id, " bled out in a spike clash!")
	# Positional give along the contact axis so the capsules stop
	# interpenetrating; knock the giver back hard, deflect the other.
	var axis := (gives_away.global_position - braces.global_position)
	if axis.length() < 0.001:
		axis = Vector3(0, 0, 1)
	axis = axis.normalized()
	gives_away.global_position += axis * 0.6
	braces.global_position -= axis * 0.6
	# Elastic deflection (1.0x): separates the pair and reverses the
	# giver without CREATING energy. The old 1.6x multiplier injected
	# speed every clash - chained head-ons ran away to zoom velocities.
	gives_away.velocity = -gives_away.velocity * 1.0 + Vector3.UP * 2.5
	braces.velocity = braces.velocity * 0.4 + Vector3.UP * 1.5
	clash_cooldown = CLASH_COOLDOWN
	victim.clash_cooldown = CLASH_COOLDOWN
	landed_strike.emit("spike_clash")
	victim.landed_strike.emit("spike_clash")
	print("SPIKE-TO-SPIKE CLASH! ", gives_away.fly_id, " gives, both take body spikes.")

func _resolve_joust(victim: FlyPhysics) -> void:
	if clash_cooldown > 0.0 or victim.clash_cooldown > 0.0:
		return
	if get_instance_id() > victim.get_instance_id():
		return
	# Mirrored clash: same dedup as the spike clash - only one side runs so
	# the velocity reversal lands (the old both-sides negation cancelled out).
	clash_cooldown = CLASH_COOLDOWN
	victim.clash_cooldown = CLASH_COOLDOWN
	var axis := (self.global_position - victim.global_position)
	if axis.length() < 0.001:
		axis = Vector3(0, 0, 1)
	axis = axis.normalized()
	global_position -= axis * 0.4
	victim.global_position += axis * 0.4
	velocity = -velocity * 0.8 + Vector3.UP * 1.5
	victim.velocity = -victim.velocity * 0.8 + Vector3.UP * 1.5
	print(fly_id, " CLASHED head-on with ", victim.fly_id, "'s guard! (Parried - no puncture!)")

func _spike_wound(victim: FlyPhysics) -> void:
	# Spike hits draw blood: wing strikes cost 15 health on top of the tear,
	# so hits register even without a kill and bleed-outs can finish.
	if victim.is_disabled:
		return
	victim.take_damage(15.0, "spike_wound")
	if victim.health <= 0.0:
		victim.inflict_lethal_strike()
		print(victim.fly_id, " bled out from spike wounds!")

func tear_wing(side: String) -> void:
	if not left_wing_intact and not right_wing_intact:
		return
	if side == "left":
		left_wing_intact = false
		if is_instance_valid(left_wing_mesh):
			left_wing_mesh.visible = false
	else:
		right_wing_intact = false
		if is_instance_valid(right_wing_mesh):
			right_wing_mesh.visible = false
	wing_torn.emit(side)
	# A torn wing forfeits the fight: the fly can no longer maneuver, so the
	# round ends immediately and the rival is credited with the knockout.
	if not is_disabled:
		last_damage_source = "wing_tear"
		last_damage_amount = 0.0
		last_damage_t = fly_time
		is_disabled = true
		knocked_out.emit()

func inflict_lethal_strike() -> void:
	health = 0.0
	is_disabled = true
	knocked_out.emit()

func reset_fly(spawn_pos: Vector3, spawn_rot_y: float) -> void:
	global_position = spawn_pos
	rotation = Vector3(0, spawn_rot_y, 0)
	velocity = Vector3.ZERO
	health = 100.0
	is_disabled = false
	landing_mode = 0
	left_wing_intact = true
	right_wing_intact = true
	# Reset sensorimotor state so the new round starts head-on with no
	# stale looming/turn bias from the previous round.
	current_thrust = 0.2
	current_yaw_torque = 0.0
	current_pitch_torque = 0.0
	current_roll_torque = 0.0
	is_ram_burst = false
	is_emergency_evade = false
	spear_thrust_cmd = 0.0
	lunge_cooldown = 0.0
	lunge_t = 0.0
	lunge_count = 0
	cmd_age = 0.0
	if is_instance_valid(spear_root):
		spear_root.position.z = 0.0
	front_spike_area.position = SPIKE_BASE_POS
	obstacle_hit_cooldown = 0.0
	clash_cooldown = 0.0
	capped_time = 0.0
	fly_time = 0.0
	peak_speed = 0.0
	speed_exploit = false
	seizure_time = 0.0
	seizure_clear = 0.0
	seizing = false
	seizure_events = 0
	last_damage_source = ""
	last_damage_amount = 0.0
	last_damage_t = 0.0
	basis_init = false
	prev_rival_dist = spawn_pos.distance_to(rival.global_position) if is_instance_valid(rival) else 28.0
	scent_prev_smooth = -1.0
	scent_lost_time = 0.0
	scent_cast_phase = 0.0
	if is_instance_valid(left_wing_mesh):
		left_wing_mesh.visible = true
	if is_instance_valid(right_wing_mesh):
		right_wing_mesh.visible = true


# ── Procedural fruit-fly visual model ─────────────────────────────────
# Real dipteran anatomy from primitives (no external assets): head with
# compound eyes + antennae, bristled thorax, banded abdomen, six jointed
# legs, halteres, and veined membrane wings. Gameplay contract: the tscn
# provides empty VisualModel/LeftWing + RightWing pivots; this builder
# hangs BodyMesh (team-tinted thorax) and every detail under VisualModel.
# Collision Areas are untouched, so hitboxes match the old pill exactly.

func _vmat(color: Color, rough: float, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m


func _segment(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material) -> void:
	# Straight chitin rod from a to b (legs, antennae, haltere stalks).
	var d := b - a
	var len := maxf(d.length(), 0.001)
	var dir := d / len
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = len
	cm.radial_segments = 7
	cm.material = mat
	mi.mesh = cm
	parent.add_child(mi)
	mi.position = (a + b) * 0.5
	mi.basis = _yaw_along(dir)


func _yaw_along(d: Vector3) -> Basis:
	# Rotation mapping +Y onto d (for Y-axis primitives).
	var x := d.cross(Vector3.UP)
	if x.length() < 0.01:
		x = Vector3.RIGHT
	else:
		x = x.normalized()
	var z := x.cross(d).normalized()
	return Basis(x, d, z)


func _build_visual_model() -> void:
	var vm := $VisualModel as Node3D
	if vm == null:
		return
	var leg_mat := _vmat(Color(0.12, 0.09, 0.07), 0.60, 0.10)
	# Real micro-CT torso: cuticle shell, bristle fields, team-tinted
	# thorax, faceted compound eyes and halteres from TuragaLab/flybody
	# (Apache-2.0; see arena/models/ATTRIBUTION.md). Scan legs stand in a
	# walking pose, wrong for a flying fighter, so legs stay procedural.
	# The cuticle carries tergite banding as vertex colors (albedo comes
	# from the mesh, not the material).
	# Warm mid-brown cuticle: vertex banding survives, but the torso
	# can never wash white under the bright sun + sky ambient.
	var cuticle_mat := _vmat(Color(0.6, 0.55, 0.5), 0.62, 0.05)
	cuticle_mat.vertex_color_use_as_albedo = true
	_scan_part(vm, "TorsoCuticle", "cuticle", cuticle_mat)
	_scan_part(vm, "TorsoBristles", "dark", _vmat(Color(0.11, 0.08, 0.06), 0.60, 0.0))
	# Beetle-shell thorax + glossy crimson eyes (team tint arrives later
	# via set_team_color; default matches the old neutral tan).
	body_mat = ShaderMaterial.new()
	body_mat.shader = preload("res://scripts/chitin.gdshader")
	_scan_part(vm, "BodyMesh", "thorax", body_mat)
	eye_mat = ShaderMaterial.new()
	eye_mat.shader = preload("res://scripts/chitin.gdshader")
	eye_mat.set_shader_parameter("team_tint", Vector3(0.62, 0.12, 0.10))
	eye_mat.set_shader_parameter("rim_strength", 1.6)
	eye_mat.set_shader_parameter("roughness_lo", 0.25)
	eye_mat.set_shader_parameter("specular_amt", 0.6)
	eye_mat.set_shader_parameter("iridescence", 0.0)
	_scan_part(vm, "EyeMesh", "eyes", eye_mat)
	_scan_part(vm, "HaltereMesh", "halteres", _vmat(Color(0.70, 0.64, 0.48), 0.50, 0.10))
	# Six jointed legs in a tucked flight pose.
	var hip_z := [-0.28, -0.02, 0.24]
	for side in [-1.0, 1.0]:
		for k in range(3):
			var hz: float = hip_z[k]
			_segment(vm, Vector3(side * 0.20, -0.14, hz), Vector3(side * 0.40, -0.40, hz + 0.10), 0.022, leg_mat)
			_segment(vm, Vector3(side * 0.40, -0.40, hz + 0.10), Vector3(side * 0.32, -0.64, hz + 0.34), 0.015, leg_mat)
	# Jousting spear, couched on the fly's right like a lance: wooden
	# shaft, steel tip, small crossguard. Aligned with the FrontSpikeArea
	# sphere at (0.32, -0.12, -1.35) r=0.35 in FlyEntity.tscn, so what you
	# see is what hits (steel tip at z=-1.35, centered in the sphere).
	_spear(vm)


func _cone(parent: Node3D, base: Vector3, dir: Vector3, base_r: float, len: float, mat: Material) -> MeshInstance3D:
	# Spike with its tip at base + dir * len.
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.004
	cm.bottom_radius = base_r
	cm.height = len
	cm.radial_segments = 8
	cm.material = mat
	mi.mesh = cm
	parent.add_child(mi)
	var d := dir.normalized()
	mi.position = base + d * (len * 0.5)
	mi.basis = _yaw_along(d)
	return mi


func _spear(vm: Node3D) -> void:
	var wood := _vmat(Color(0.35, 0.24, 0.12), 0.70, 0.0)
	var steel := _vmat(Color(0.65, 0.68, 0.72), 0.30, 0.85)
	var brass := _vmat(Color(0.55, 0.45, 0.20), 0.45, 0.60)
	# All spear parts hang under one sliding root so the lunge animation
	# can thrust the whole weapon forward (see _physics_process).
	spear_root = Node3D.new()
	spear_root.name = "SpearRoot"
	vm.add_child(spear_root)
	var grip := Vector3(0.32, -0.12, 0.0)
	# Shaft: butt behind the grip to tip base, couched level forward.
	_segment(spear_root, grip + Vector3(0, 0, 0.55), grip + Vector3(0, 0, -1.05), 0.035, wood)
	# Steel tip cone to z=-1.35, centered in the spike hitbox sphere.
	_cone(spear_root, grip + Vector3(0, 0, -1.05), Vector3(0, 0, -1), 0.05, 0.30, steel)
	# Crossguard bar just behind the tip cone.
	_segment(spear_root, grip + Vector3(-0.12, 0, -1.00), grip + Vector3(0.12, 0, -1.00), 0.022, brass)
	# Lunge streak: additive energy sheath along the shaft, visible only
	# while the spear extends (driven in _physics_process). Team tint
	# arrives via set_team_color; alpha is animated per-frame.
	spear_glow_mat = StandardMaterial3D.new()
	spear_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spear_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spear_glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spear_glow_mat.albedo_color = Color(1.0, 0.9, 0.7, 0.0)
	spear_glow = MeshInstance3D.new()
	spear_glow.name = "SpearGlow"
	var gm := CylinderMesh.new()
	gm.top_radius = 0.07
	gm.bottom_radius = 0.07
	gm.height = 1.7
	gm.radial_segments = 8
	gm.material = spear_glow_mat
	spear_glow.mesh = gm
	spear_glow.rotation_degrees.x = 90.0
	spear_glow.position = grip + Vector3(0, 0, -0.35)
	spear_glow.visible = false
	spear_root.add_child(spear_glow)
	# Real wing membranes + veins hung under the gameplay pivots; pivots
	# move to the scan hinge positions from the manifest.
	membrane_mat = ShaderMaterial.new()
	membrane_mat.shader = preload("res://scripts/wing.gdshader")
	var vein_mat := _vmat(Color(0.25, 0.18, 0.12), 0.50, 0.10)
	_hang_scan_wing("Left", "wingL_membrane", "wingL_veins", membrane_mat, vein_mat)
	_hang_scan_wing("Right", "wingR_membrane", "wingR_veins", membrane_mat, vein_mat)


static var _flybody_data := {}
static var _flybody_meshes := {}


func _flybody_manifest() -> Dictionary:
	# Micro-CT part meshes, parsed once and shared by both flies.
	if not _flybody_data.is_empty():
		return _flybody_data
	var path := "res://models/flybody_manifest.json"
	if not FileAccess.file_exists(path):
		push_warning("[FlyPhysics] flybody manifest missing: %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		_flybody_data = data
		return data
	return {}


func _flybody_mesh(group: String) -> ArrayMesh:
	if _flybody_meshes.has(group):
		return _flybody_meshes[group]
	var manifest := _flybody_manifest()
	var part: Dictionary = (manifest.get("parts", {}) as Dictionary).get(group, {})
	if part.is_empty():
		return null
	var raw_v := Marshalls.base64_to_raw(str(part.get("verts", "")))
	var raw_n := Marshalls.base64_to_raw(str(part.get("normals", "")))
	var raw_i := Marshalls.base64_to_raw(str(part.get("indices", "")))
	var va := PackedVector3Array()
	var na := PackedVector3Array()
	var nv: int = raw_v.size() / 12
	for i in range(nv):
		va.append(Vector3(raw_v.decode_float(i * 12), raw_v.decode_float(i * 12 + 4), raw_v.decode_float(i * 12 + 8)))
		na.append(Vector3(raw_n.decode_float(i * 12), raw_n.decode_float(i * 12 + 4), raw_n.decode_float(i * 12 + 8)))
	var ia := PackedInt32Array()
	var ni: int = raw_i.size() / 4
	for i in range(ni):
		ia.append(raw_i.decode_s32(i * 4))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = va
	arrays[Mesh.ARRAY_NORMAL] = na
	arrays[Mesh.ARRAY_INDEX] = ia
	if group == "cuticle":
		# Tergite banding baked as vertex colors: pale tan head, dark
		# posterior bands per segment, darkening tip. Without this the
		# fused shell reads as one pale grub (bee-like); with it the
		# abdomen segments read like a real melanogaster.
		var ca := PackedColorArray()
		for i in range(nv):
			ca.append(_tergite_color(va[i].z))
		arrays[Mesh.ARRAY_COLOR] = ca
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_flybody_meshes[group] = mesh
	return mesh


func _tergite_color(z: float) -> Color:
	var tan := Color(0.55, 0.45, 0.30)
	var dark := Color(0.16, 0.11, 0.07)
	if z < 0.12:
		return tan
	var t := (z - 0.12) / 0.115
	var frac := t - floorf(t)
	var band := smoothstep(0.55, 0.95, frac)
	var tip := smoothstep(0.45, 0.87, z)
	return tan.lerp(dark, clampf(maxf(band, tip * 0.85), 0.0, 1.0))


func _scan_part(vm: Node3D, node_name: String, group: String, mat: Material) -> void:
	var mesh := _flybody_mesh(group)
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.name = node_name
	vm.add_child(mi)


func _hang_scan_wing(side: String, membrane_group: String, veins_group: String, membrane_mat: Material, vein_mat: Material) -> void:
	var manifest := _flybody_manifest()
	var pivots: Dictionary = manifest.get("wing_pivots", {})
	var key := "wingL" if side == "Left" else "wingR"
	var pivot := $VisualModel.get_node_or_null(side + "Wing") as Node3D
	if pivot == null:
		return
	if pivots.has(key):
		var pp: Array = pivots[key]
		pivot.position = Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
	var mem := _flybody_mesh(membrane_group)
	if mem != null:
		var wmi := MeshInstance3D.new()
		wmi.mesh = mem
		wmi.material_override = membrane_mat
		wmi.name = side + "WingMesh"
		pivot.add_child(wmi)
	var veins := _flybody_mesh(veins_group)
	if veins != null:
		var vmi := MeshInstance3D.new()
		vmi.mesh = veins
		vmi.material_override = vein_mat
		vmi.name = side + "WingVeins"
		pivot.add_child(vmi)
