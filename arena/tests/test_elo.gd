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


func test_overtime_scale() -> void:
	# Overtime ladder: base time, then 1.5x after the first DNF,
	# 2x after the second (and beyond — the 3rd DNF ends the pairing).
	var d = _new_director()
	_check(d.overtime_scale(0) == 1.0, "no draws means base time")
	_check(d.overtime_scale(1) == 1.5, "first DNF means 1.5x")
	_check(d.overtime_scale(2) == 2.0, "second DNF means 2x")
	_check(d.overtime_scale(9) == 2.0, "scale caps at 2x")
	d.free()


func test_draw_banks_drift() -> void:
	# DNF drift rides into the match record for the overtime dock;
	# unreported calls leave the previous pair untouched.
	var d = _new_director()
	var brains := [_fake_elo("f1", 1200.0), _fake_elo("f2", 1200.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1200.0)]
	d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0, false, brains,
		false, false)
	var r1: Dictionary = d.on_battle_result("draw", {}, {}, {}, -1, -1,
		5.2, 0.4)
	_check(str(r1.get("action", "")) == "replay", "drifted draw replays")
	var m: Dictionary = d.current_match()
	_check(absf(float(m.get("drift_a", -1.0)) - 5.2) < 0.001
		and absf(float(m.get("drift_b", -1.0)) - 0.4) < 0.001,
		"drift pair banked on draw")
	var r2: Dictionary = d.on_battle_result("draw", {}, {}, {})
	_check(str(r2.get("action", "")) == "replay", "plain draw replays")
	var m2: Dictionary = d.current_match()
	_check(absf(float(m2.get("drift_a", -1.0)) - 5.2) < 0.001,
		"unreported drift keeps previous pair")
	d.free()


func test_replay_scale_onetime() -> void:
	# Overtime fires exactly once per tie: the immediate replay.
	# A decisive battle ends it even mid-match (best-of-3 proves no
	# carry-over into later battles); new matches start clean.
	var d = _new_director()
	_check(d.replay_scale({}) == 1.0, "empty match base time")
	_check(d.replay_scale({"draws": 2}) == 1.0, "no flights means no replay")
	var brains := [_fake_elo("f1", 1200.0), _fake_elo("f2", 1200.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1200.0)]
	d.build_bracket(_ids(brains), 4, 3, 0.5, 40.0, false, brains,
		false, false)
	_check(d.replay_scale(d.current_match()) == 1.0, "first battle base time")
	var r1: Dictionary = d.on_battle_result("draw", {"samples": 0},
		{"samples": 0}, {}, -1, -1, 5.2, 0.4)
	_check(str(r1.get("action", "")) == "replay", "tie replays")
	_check(d.replay_scale(d.current_match()) == 1.5, "replay runs overtime")
	var r2: Dictionary = d.on_battle_result("alpha", {"samples": 0},
		{"samples": 0}, {})
	_check(str(r2.get("action", "")) == "next_battle", "1-0 continues match")
	_check(d.replay_scale(d.current_match()) == 1.0, "no carry into next battle")
	var r3: Dictionary = d.on_battle_result("draw", {"samples": 0},
		{"samples": 0}, {}, -1, -1, 1.0, 8.0)
	_check(str(r3.get("action", "")) == "replay", "second tie replays")
	_check(d.replay_scale(d.current_match()) == 2.0, "second replay at 2x")
	var r4: Dictionary = d.on_battle_result("beta", {"samples": 0},
		{"samples": 0}, {})
	_check(str(r4.get("action", "")) == "next_battle", "1-1 continues match")
	_check(d.replay_scale(d.current_match()) == 1.0, "decisive ends overtime again")
	d.free()


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


func test_seeding_pairs_strong_vs_weak() -> void:
	var d = _new_director()
	# Distinct ELOs, deliberately unordered input: non-random builds
	# must pair 1v8, 4v5, 2v7, 3v6 by ELO rank (seed order for size 8
	# is [1,8,4,5,2,7,3,6]).
	var brains := [_fake_elo("f1", 1100.0), _fake_elo("f2", 1500.0),
		_fake_elo("f3", 1200.0), _fake_elo("f4", 1750.0),
		_fake_elo("f5", 900.0), _fake_elo("f6", 1300.0),
		_fake_elo("f7", 1600.0), _fake_elo("f8", 1400.0)]
	# By ELO: f4 1750, f7 1600, f2 1500, f8 1400, f6 1300, f3 1200,
	# f1 1100, f5 900.
	var res: Dictionary = d.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, false, false)
	_check(bool(res.get("ok", false)), "size-8 seeded bracket builds")
	_check(str(d.tourney.get("seeding", "")) == "strength", "non-random build marked strength")
	var r0: Array = (d.tourney["rounds"] as Array)[0]
	var pairs: Array = []
	for m in r0:
		pairs.append([str((m as Dictionary).get("a_id", "")),
			str((m as Dictionary).get("b_id", ""))])
	_check(pairs[0] == ["f4", "f5"], "M1 pairs strongest vs weakest")
	_check(pairs[1] == ["f8", "f6"], "M2 pairs 4th vs 5th")
	_check(pairs[2] == ["f7", "f1"], "M3 pairs 2nd vs 7th")
	_check(pairs[3] == ["f2", "f3"], "M4 pairs 3rd vs 6th")
	# Random draw keeps the flag honest (order shuffled, marked random).
	var d2 = _new_director()
	var res2: Dictionary = d2.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, true, false)
	_check(bool(res2.get("ok", false)), "random bracket builds")
	_check(str(d2.tourney.get("seeding", "")) == "random", "random build marked random")


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
	test_overtime_scale()
	test_draw_banks_drift()
	test_replay_scale_onetime()
	test_draw3_higher_elo_advances()
	test_draw3_tie_goes_alpha()
	test_draw3_missing_elo_defaults()
	test_strength_elo_primary()
	test_seeding_pairs_strong_vs_weak()
	_cleanup()
	if failures == 0:
		print("ALL ELO TESTS PASSED")
	else:
		printerr("ELO TESTS: %d FAILURES" % failures)
	quit(failures)
