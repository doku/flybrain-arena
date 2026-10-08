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


func _pair_for_tip(a, b) -> void:
	# Place b so a's tip point lands exactly in b's RIGHT wing box
	# center: b facing -Z (identity yaw), offset by the wing pivot.
	_tip_at_attacker_extent(a)
	var tip: Vector3 = a.front_spike_area.global_position
	b.global_position = tip - Vector3(0.9, 0.1, -0.1)
	b.rotation = Vector3.ZERO
	b.velocity = Vector3.ZERO


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
	# Same-frame dedup (mirrors the clash/joust rule): the higher
	# instance id's report drops, the lower id resolves. (A mutual
	# wing-wing pass is geometrically impossible - forward tips vs
	# lateral wings - so the guard is exercised in both orders.)
	var a = _fly("MA")
	var b = _fly("MB")
	var high = a if a.get_instance_id() > b.get_instance_id() else b
	var low = b if high == a else a
	# High id reports first: tip inside the box, but the guard drops.
	_pair_for_tip(high, low)
	high.velocity = Vector3(0, 0, -10)
	low.velocity = Vector3.ZERO
	high._on_spike_hit_area(low.get_node("RightWingHurtbox"))
	_check(low.right_wing_intact, "higher id drops (dedup)")
	# Lower id reports the same contact class: tear lands.
	_pair_for_tip(low, high)
	low.velocity = Vector3(0, 0, -10)
	high.velocity = Vector3.ZERO
	low._on_spike_hit_area(high.get_node("RightWingHurtbox"))
	_check(not high.right_wing_intact, "lower id resolves (tear lands)")
	high.queue_free()
	low.queue_free()


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
		if failures == 0:
			print("ALL COLLISION TESTS PASSED")
		else:
			printerr("COLLISION TESTS: %d FAILURES" % failures)
		quit(failures)
	return true
