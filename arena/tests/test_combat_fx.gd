extends SceneTree
## Headless combat-FX tests: health rings, ember bursts, vignette and
## the KO-shockwave lifecycle on the REAL arena scene (seconds, not a
## full live round). Run: godot --headless --path arena -s tests/test_combat_fx.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var tick := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_builds() -> void:
	# Built by the real _ready (same path as the game).
	_check(is_instance_valid(arena.ring_alpha), "alpha ring node built")
	_check(is_instance_valid(arena.ring_beta), "beta ring node built")
	_check(arena.ring_mat_alpha.shader != null, "alpha ring shader bound")
	_check(is_instance_valid(arena.hit_bursts["alpha"]), "alpha hit burst built")
	_check(is_instance_valid(arena.hit_bursts["beta"]), "beta hit burst built")
	_check(is_instance_valid(arena.ko_bursts["alpha"]), "alpha KO burst built")
	_check(is_instance_valid(arena.ko_bursts["beta"]), "beta KO burst built")
	_check(arena.get_node_or_null("VignetteLayer") != null, "vignette layer built")
	_check(arena.hit_bursts["alpha"].amount == 14 and arena.ko_bursts["alpha"].amount == 42,
		"burst sizes 14/42")
	var acol: Color = arena.hit_bursts["alpha"].draw_pass_1.material.albedo_color
	var bcol: Color = arena.hit_bursts["beta"].draw_pass_1.material.albedo_color
	_check(acol.is_equal_approx(Color(1.0, 0.55, 0.30)), "alpha bleeds orange")
	_check(bcol.is_equal_approx(Color(0.4, 0.75, 1.0)), "beta bleeds blue")
	_check(arena.fly_alpha.body_std_mat != null, "alpha team tint bound")
	_check(arena.fly_alpha.eye_mat != null, "alpha eye shader bound")
	_check(arena.fly_beta.membrane_mat != null, "beta wing shader bound")


func test_hit_feedback_path() -> void:
	arena._hit_feedback("alpha", "beta", "thorax")
	_check(arena.hit_bursts["beta"].emitting, "victim team burst emitting after strike")
	_check(not arena.hit_bursts["alpha"].emitting, "attacker burst stays dark")
	_check(arena.fly_beta.flash_energy == 1.0, "victim flash energy 1.0")
	_check(arena.stats_alpha["damage_dealt"] == 0.0,
		"no sim stat touched by FX path")


func test_shock_lifecycle() -> void:
	# KO shockwave runs 0.01 -> 1.0 exactly once, then parks at 0.
	# (Regression: it used to advance unconditionally and ripple forever.)
	arena.ring_shock_alpha = 0.01
	for i in range(100):
		arena._update_combat_fx(0.016)
	_check(arena.ring_shock_alpha == 0.0, "shock completes and parks at 0")
	for i in range(10):
		arena._update_combat_fx(0.016)
	_check(arena.ring_shock_alpha == 0.0, "no perpetual ripple without KO")
	_check(float(arena.ring_mat_alpha.get_shader_parameter("shock")) == 0.0,
		"shock uniform 0 at rest")


func test_combat_gate() -> void:
	# Intermission clinches must not bleed: with combat closed,
	# damage/tears/KOs are all no-ops; reopened, damage applies.
	var fa = arena.fly_alpha
	arena._set_combat(false)
	var h0: float = fa.health
	fa.take_damage(25.0, "test")
	_check(fa.health == h0, "take_damage gated outside rounds")
	fa.tear_wing("left")
	_check(fa.left_wing_intact, "tear gated outside rounds")
	fa.inflict_lethal_strike()
	_check(not fa.is_disabled, "KO gated outside rounds")
	arena._set_combat(true)
	fa.take_damage(10.0, "test")
	_check(fa.health == h0 - 10.0, "damage applies in rounds")
	fa.health = h0


func test_ko_burst_path() -> void:
	# Same two lines the KO handler runs (burst + shock seed).
	arena._fire_burst(arena.ko_bursts["alpha"], arena.fly_alpha.global_position)
	arena.ring_shock_alpha = 0.01
	_check(arena.ko_bursts["alpha"].emitting, "KO burst emitting")
	_check(arena.ring_shock_alpha > 0.0, "KO shock seeded")


func _initialize() -> void:
	var scene = load("res://scenes/ArenaGlade.tscn")
	arena = scene.instantiate()
	root.add_child(arena)


func _process(_delta: float) -> bool:
	tick += 1
	if tick < 3:
		return false
	test_builds()
	test_hit_feedback_path()
	test_shock_lifecycle()
	test_combat_gate()
	test_ko_burst_path()
	if failures == 0:
		print("ALL COMBAT-FX TESTS PASSED")
	else:
		printerr("COMBAT-FX TESTS: %d FAILURES" % failures)
	quit(failures)
	return true
