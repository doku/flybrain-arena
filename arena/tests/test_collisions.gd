extends SceneTree
## Headless collision-rule tests: spear-POINT wing tears (tip inside the
## wing box, not the generous sphere), same-frame dedup, tree damage
## without tears, and the manager's one-strike-per-frame guard.
## Real FlyEntity instances (areas + transforms), positioned by hand -
## the tip test is pure math, no physics-server overlap needed.
## Run: godot --headless --path arena -s tests/test_collisions.gd
## Exit code = failure count (0 = all green).

var failures := 0
var _stage := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _fly(id: String):
	var scene = load("res://scenes/FlyEntity.tscn")
	var fly = scene.instantiate()
	fly.name = id
	fly.fly_id = id
	fly.set_combat_enabled(true)
	root.add_child(fly)
	return fly


func _tip_at_attacker_extent(attacker) -> void:
	# The lunge at full extension (pierce held): the spike area rides
	# its base + LUNGE_DIST forward.
	attacker.spear_pierce = true
	attacker.front_spike_area.position = attacker.SPIKE_BASE_POS \
		+ Vector3(0, 0, -attacker.LUNGE_DIST)


func _pair_for_tip(a, b, side := 1.0) -> void:
	# Place b so a's tip point lands exactly in b's wing box center
	# (side +1 right, -1 left): b facing -Z (identity yaw), offset by
	# the wing pivot.
	_tip_at_attacker_extent(a)
	var tip: Vector3 = a.front_spike_area.global_position
	b.global_position = tip - Vector3(0.9 * side, 0.1, -0.1)
	b.rotation = Vector3.ZERO
	b.velocity = Vector3.ZERO


func test_stale_commands_read_dead() -> void:
	# A 1 s-silenced brain is a dead link (CONTROL LINK SLOW holding
	# under throttle) or a finished round (steps stop with it): fresh
	# commands are live, stale ones are not.
	var f = _fly("TS")
	f.apply_brain_controls({"thrust": 1.0, "yaw_torque": 1.0})
	_check(f.commands_live(), "fresh commands are live")
	f.cmd_age = f.CMD_STALE_SECS + 1.0
	_check(not f.commands_live(), "unrefreshed commands go stale")
	f.queue_free()


func test_neutralize_freezes() -> void:
	# Freeze NOW: every command plus the velocity zeroes, and the age
	# parks past stale so the hover gate holds until a fresh reply.
	var f = _fly("TN")
	f.apply_brain_controls({"thrust": 1.0, "yaw_torque": 0.5,
		"pitch_torque": 0.5, "roll_torque": 0.5, "ram_drive": 1.0,
		"emergency_evade": true, "spear_thrust": 1.0})
	f.velocity = Vector3(5, 1, 5)
	f.neutralize()
	_check(f.current_thrust == 0.0, "neutralize kills thrust")
	_check(f.current_yaw_torque == 0.0, "neutralize kills yaw")
	_check(f.ram_drive == 0.0, "neutralize kills ram")
	_check(not f.is_emergency_evade, "neutralize kills evade")
	_check(f.velocity == Vector3.ZERO, "neutralize kills velocity")
	_check(not f.commands_live(), "neutralize parks past stale")
	# A fresh reply still revives (never wedges).
	f.apply_brain_controls({"thrust": 0.5})
	_check(f.commands_live(), "fresh reply revives after neutralize")
	_check(absf(f.current_thrust - 0.5) < 0.001, "revive replants thrust")
	f.queue_free()


func test_landing_ignores_brain() -> void:
	# Ceremony owns the body: late replies during landing must not
	# replant commands (or reset the stale clock) behind it.
	var f = _fly("TL")
	f.neutralize()
	f.begin_landing(true)
	f.apply_brain_controls({"thrust": 1.0, "yaw_torque": 1.0})
	_check(f.current_thrust == 0.0, "landing ignores late thrust")
	_check(not f.commands_live(), "landing keeps the clock stale")
	f.queue_free()


func test_tip_in_box_tears() -> void:
	var a = _fly("TA")
	var b = _fly("TB")
	_pair_for_tip(a, b)
	a.velocity = Vector3(0, 0, -10)
	var area: Area3D = b.get_node("RightWingHurtbox")
	a._on_spike_hit_area(area)
	_check(not b.right_wing_intact, "tip inside the wing box tears")
	# Tear = forfeit (0 hp): the wound is skipped once disabled, the
	# ledger names the tear.
	_check(b.health == 100.0, "tear forfeits without a wound")
	_check(str(b.last_damage_source) == "wing_tear", "ledger names the tear")
	a.queue_free()
	b.queue_free()


func test_sideswipe_grazes() -> void:
	# Sphere overlap (area_entered would fire) but the tip POINT is a
	# body-width outside the box: graze, never tear.
	var a = _fly("SA")
	var b = _fly("SB")
	_pair_for_tip(a, b)
	b.global_position += Vector3(0.9, 0, 0)
	a.velocity = Vector3(0, 0, -10)
	var area: Area3D = b.get_node("RightWingHurtbox")
	a._on_spike_hit_area(area)
	_check(b.right_wing_intact, "sideswipe never tears")
	_check(b.health == 100.0, "sideswipe deals nothing")
	a.queue_free()
	b.queue_free()


func test_slow_contact_never_tears() -> void:
	var a = _fly("WA")
	var b = _fly("WB")
	_pair_for_tip(a, b)
	a.velocity = Vector3(0, 0, -2)
	var area: Area3D = b.get_node("RightWingHurtbox")
	a._on_spike_hit_area(area)
	_check(b.right_wing_intact, "too slow to pierce chitin")
	a.queue_free()
	b.queue_free()


func test_mutual_pass_resolves_once() -> void:
	# Order-independent single resolution per exchange (pair-frame
	# stamp on BOTH participants): the first reporter resolves
	# regardless of instance id (a sole high-id reporter tears - the
	# old id rule dropped these), and a second same-frame report on
	# the pair drops even with valid geometry (no double tear).
	var a = _fly("MA")
	var b = _fly("MB")
	var high = a if a.get_instance_id() > b.get_instance_id() else b
	var low = b if high == a else a
	# High reports first, valid geometry: resolves.
	_pair_for_tip(high, low, 1.0)
	high.velocity = Vector3(0, 0, -10)
	low.velocity = Vector3.ZERO
	high._on_spike_hit_area(low.get_node("RightWingHurtbox"))
	_check(not low.right_wing_intact, "sole high-id reporter tears")
	# Same pair, other wing, still this frame: dropped.
	_pair_for_tip(high, low, -1.0)
	high.velocity = Vector3(0, 0, -10)
	high._on_spike_hit_area(low.get_node("LeftWingHurtbox"))
	_check(low.left_wing_intact, "second same-frame report drops")
	high.queue_free()
	low.queue_free()
	# Reverse order, fresh pair: low resolves first, high drops after.
	var c = _fly("MC")
	var d = _fly("MD")
	var hi = c if c.get_instance_id() > d.get_instance_id() else d
	var lo = d if hi == c else c
	_pair_for_tip(lo, hi, 1.0)
	lo.velocity = Vector3(0, 0, -10)
	hi.velocity = Vector3.ZERO
	lo._on_spike_hit_area(hi.get_node("RightWingHurtbox"))
	_check(not hi.right_wing_intact, "low-first resolves")
	_pair_for_tip(hi, lo, 1.0)
	hi.velocity = Vector3(0, 0, -10)
	lo.velocity = Vector3.ZERO
	hi._on_spike_hit_area(lo.get_node("RightWingHurtbox"))
	_check(lo.right_wing_intact, "second reporter drops either order")
	hi.queue_free()
	lo.queue_free()


func test_manager_drops_same_frame() -> void:
	# One strike per physics frame: the second report drops (no double
	# damage, no double KO credit).
	var scr = load("res://scripts/ArenaManager.gd")
	var arena = scr.new()
	arena.stats_alpha = {"kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0}
	arena.stats_beta = {"kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0}
	arena._last_strike_frame = -1
	arena._last_strike_attacker = ""
	arena._on_strike_landed("alpha", "wing")
	arena._on_strike_landed("beta", "thorax")
	_check(absf(arena.stats_alpha["damage_dealt"] - 60.0) < 0.01,
		"first strike credits once")
	_check(absf(arena.stats_beta["damage_dealt"] - 0.0) < 0.01,
		"same-frame strike dropped")
	# A later frame applies again.
	arena._last_strike_frame = Engine.get_physics_frames() - 10
	arena._on_strike_landed("beta", "thorax")
	_check(absf(arena.stats_beta["damage_dealt"] - 80.0) < 0.01,
		"later-frame strike applies")
	arena.queue_free()


func test_tree_never_tears() -> void:
	# Regression: the tree-slam branch must not tear wings. The tiers
	# are dynamic (slide collisions need a physics world), so the tear
	# deletion is locked at the source: the SLAMMED print line carries
	# no "Wing torn" text (the exact marker the old branch printed).
	var src: String = load("res://scripts/FlyPhysics.gd").source_code
	var slammed := ""
	for l in src.split("\n"):
		if "SLAMMED a tree" in l:
			slammed = l
	_check(slammed != "", "tree branch present")
	_check(not ("Wing torn" in slammed or "tear_wing" in slammed),
		"tree slam never tears")
	# And the direct damage still routes through the ledger.
	var fly = _fly("TR")
	fly.take_damage(50.0, "tree_slam")
	_check(absf(fly.health - 50.0) < 0.01 and not fly.is_disabled,
		"tree slam damages without a tear")
	fly.queue_free()


func _initialize() -> void:
	# Test bodies instantiate in _process (frames exist: the tree is
	# only active after the first frame - @onready area refs and
	# _ready wiring resolve there, never at _initialize time).
	load("res://scripts/BrainClient.gd").test_mute = true


func _process(_delta: float) -> bool:
	if _stage == 0:
		_stage = 1
		test_tip_in_box_tears()
		test_sideswipe_grazes()
		test_slow_contact_never_tears()
		test_mutual_pass_resolves_once()
		test_manager_drops_same_frame()
		test_tree_never_tears()
		test_stale_commands_read_dead()
		test_neutralize_freezes()
		test_landing_ignores_brain()
		if failures == 0:
			print("ALL COLLISION TESTS PASSED")
		else:
			printerr("COLLISION TESTS: %d FAILURES" % failures)
		quit(failures)
	return true
