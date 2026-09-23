extends SceneTree
## Headless ELO tests: 3rd-draw resolution, ELO-primary seeding.
## Run: godot --headless --path arena -s tests/test_elo.gd
## Uses fake players via brains_override (no vault/Python needed).
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_director():
	# Untyped on purpose: Variant receivers keep director calls dynamic
	# (a static Node annotation would fail compilation on every call).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_elo"
	DirAccess.make_dir_recursive_absolute("user://test_elo")
	return D


func _fake_elo(pid: String, elo: float) -> Dictionary:
	return {"id": pid, "name": "F-" + pid,
		"record": {"elo": elo, "matches_won": 0, "matches_lost": 0,
			"wins": 0, "losses": 0}}


func _fake_plain(pid: String) -> Dictionary:
	return {"id": pid, "name": "F-" + pid, "record": {}}


func _ids(brains: Array) -> Array:
	var out: Array = []
	for b in brains:
		out.append(str(b.get("id", "")))
	return out


func _draws(d, n: int) -> Dictionary:
	# Feeds n draws into the current match, returns the last result.
	var adv = {}
	for i in range(n):
		adv = d.on_battle_result("draw", {}, {}, {})
	return adv


func test_draw12_replay() -> void:
	var d = _new_director()
	var brains := [_fake_elo("f1", 1200.0), _fake_elo("f2", 1200.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1200.0)]
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, false)
	_check(bool(res.get("ok", false)), "draw bracket builds")
	var r1: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r1.get("action", "")) == "replay", "1st draw replays")
	var r2: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r2.get("action", "")) == "replay", "2nd draw replays")


func test_draw3_higher_elo_advances() -> void:
	var d = _new_director()
	# f1 top-rated: ELO seeding puts it at R0M0 alpha.
	var brains := [_fake_elo("f1", 1500.0), _fake_elo("f2", 1200.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1200.0)]
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, false)
	_check(bool(res.get("ok", false)), "elo bracket builds")
	var m0: Dictionary = d.current_match()
	_check(str(m0.get("a_id", "")) == "f1", "top ELO seeds first match alpha")
	_draws(d, 2)
	var r3: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r3.get("action", "")) == "match_over", "3rd draw resolves")
	_check(str(r3.get("match_winner", "")) == "alpha", "higher ELO advances")
	_check(bool(r3.get("resolved_by_draw", false)), "resolution flagged")
	var m: Dictionary = d.current_match()
	_check(str(m.get("winner_id", "")) == "f1", "winner banked on card")


func test_draw3_tie_goes_alpha() -> void:
	var d = _new_director()
	var brains := [_fake_elo("f1", 1300.0), _fake_elo("f2", 1300.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1200.0)]
	d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0, false, brains, false, false)
	_draws(d, 2)
	var r3: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r3.get("action", "")) == "match_over", "tied 3rd draw resolves")
	_check(str(r3.get("match_winner", "")) == "alpha", "tie goes alpha")


func test_draw3_missing_elo_defaults() -> void:
	var d = _new_director()
	var brains := [_fake_plain("f1"), _fake_plain("f2"),
		_fake_plain("f3"), _fake_plain("f4")]
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, false)
	_check(bool(res.get("ok", false)), "legacy bracket builds")
	_draws(d, 2)
	var r3: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r3.get("action", "")) == "match_over", "legacy 3rd draw resolves")
	_check(str(r3.get("match_winner", "")) == "alpha", "default tie goes alpha")


func test_strength_elo_primary() -> void:
	var d = _new_director()
	# Zero W/L everywhere: old metric ties outright, so R0M0 alpha
	# proves ELO is the primary sort key.
	var brains := [_fake_elo("f1", 900.0), _fake_elo("f2", 1750.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1400.0)]
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, false)
	_check(bool(res.get("ok", false)), "seeded bracket builds")
	var m0: Dictionary = d.current_match()
	_check(str(m0.get("a_id", "")) == "f2", "1750 seeds first over 900/1200/1400")
	_check(d._player_elo("f2") > d._player_elo("f1"), "elo lookup reads records")
	_check(d._player_elo("ghost") == 1200.0, "unknown id defaults 1200")


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute("user://test_elo"):
		for f in DirAccess.get_files_at("user://test_elo"):
			DirAccess.remove_absolute("user://test_elo".path_join(f))
		DirAccess.remove_absolute("user://test_elo")


func _initialize() -> void:
	var d0 = _new_director()
	_check(d0.has_method("_player_elo"), "director has _player_elo")
	if failures > 0:
		printerr("ELO TESTS: missing features, aborting")
		quit(failures)
		return
	test_draw12_replay()
	test_draw3_higher_elo_advances()
	test_draw3_tie_goes_alpha()
	test_draw3_missing_elo_defaults()
	test_strength_elo_primary()
	_cleanup()
	if failures == 0:
		print("ALL ELO TESTS PASSED")
	else:
		printerr("ELO TESTS: %d FAILURES" % failures)
	quit(failures)
