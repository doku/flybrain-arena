extends SceneTree
## Crossover-gate regression tests: gen 4 killed a whole generation when
## the CHAMPION was a multi-mix legacy brain (partner was checked, champ
## never was) -> crossover queued -> breeder ValueError -> abort + wiped
## queue. The gate must require a crossable champion AND partner.
## Run: godot --headless --path arena -s tests/test_evo_crossover_gate.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var tick := 0
var director = null
var saved_tourney := {}


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _fake(pid: String, elo: float, genome: bool = false,
		mix = null) -> Dictionary:
	var gp := {}
	if genome:
		gp = {"genome": {"rules": []}}
	elif mix != null:
		gp = {"experiment": mix}
	return {"id": pid, "name": "F-" + pid,
		"generator_params": gp, "record": {"elo": elo}}


func _set_roster(players: Array) -> void:
	director.tourney = {"players": players}


func test_multimix_champ_asexual() -> void:
	# Exact gen-4 replay: multi-mix champion, genome rival waiting.
	_set_roster([
		_fake("slate", 3500.0, false, ["lplc2_contra_dn", "spear_lunge"]),
		_fake("rival", 1500.0, true),
		_fake("base", 1200.0),
	])
	_check(arena._evo_clone_parent2(4, "slate") == "",
		"gen 4 multi-mix champ breeds asexual (no doomed crossover)")
	_check(arena._evo_clone_parent2(3, "slate") == "",
		"non-4th gen breeds asexual")


func test_genome_pair_crosses() -> void:
	_set_roster([
		_fake("champ", 3000.0, true),
		_fake("rival", 1500.0, true),
		_fake("base", 1200.0),
	])
	_check(arena._evo_clone_parent2(4, "champ") == "rival",
		"gen 4 genome pair still crosses")
	_check(arena._evo_clone_parent2(8, "champ") == "rival",
		"gen 8 genome pair still crosses")


func test_partner_is_strongest_crossable() -> void:
	_set_roster([
		_fake("champ", 3000.0, true),
		_fake("weak", 1300.0, true),
		_fake("strong", 2500.0, true),
		_fake("base_king", 4000.0),
	])
	_check(arena._evo_clone_parent2(4, "champ") == "strong",
		"partner is strongest crossable rival, base king skipped")


func test_no_partner_asexual() -> void:
	_set_roster([
		_fake("champ", 3000.0, true),
		_fake("base", 1200.0),
	])
	_check(arena._evo_clone_parent2(4, "champ") == "",
		"genome champ alone breeds asexual")


func _initialize() -> void:
	var scene = load("res://scenes/ArenaGlade.tscn")
	arena = scene.instantiate()
	root.add_child(arena)


func _process(_delta: float) -> bool:
	tick += 1
	if tick < 3:
		return false
	director = root.get_node("TournamentDirector")
	saved_tourney = director.tourney
	test_multimix_champ_asexual()
	test_genome_pair_crosses()
	test_partner_is_strongest_crossable()
	test_no_partner_asexual()
	director.tourney = saved_tourney
	if failures == 0:
		print("ALL EVO-CROSSOVER-GATE TESTS PASSED")
	else:
		printerr("EVO-CROSSOVER-GATE TESTS: %d FAILURES" % failures)
	quit(failures)
	return true
