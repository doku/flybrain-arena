extends SceneTree
## Evolution bracket-fill tests: a full 16-roster must start consolation
## (8 round-0 losers); a 15-roster yields 7 + a bye, so consolation can
## never start and the shortness self-perpetuates. Uses fake players via
## brains_override (no vault/Python needed).
## Run: godot --headless --path arena -s tests/test_evo_bracket_fill.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _fake(pid: String) -> Dictionary:
	return {"id": pid, "name": "F-" + pid, "record": {}}


func _new_director():
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_evo_fill"
	DirAccess.make_dir_recursive_absolute("user://test_evo_fill")
	return D


func _fakes(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append(_fake("f%d" % (i + 1)))
	return out


func _ids(brains: Array) -> Array:
	var out: Array = []
	for b in brains:
		out.append(str(b.get("id", "")))
	return out


func _run_to_end(d) -> Array:
	# Alpha always wins every playable match until tournament_end.
	var log: Array = []
	var guard := 0
	while guard < 300:
		guard += 1
		var m: Dictionary = d.current_match()
		if m.is_empty():
			break
		if str(m.get("winner_id", "")) == "" \
				and not bool(m.get("bye", false)) \
				and not bool(m.get("vacant", false)):
			var res: Dictionary = d.on_battle_result("alpha")
			_check(str(res.get("action", "")) == "match_over",
				"match over after 1 battle")
		var adv = d.advance_after_match()
		if adv == null or not (adv is Dictionary) or (adv as Dictionary).is_empty():
			_check(false, "advance_after_match returned null/empty")
			break
		log.append(adv)
		if str((adv as Dictionary).get("action", "")) == "tournament_end":
			break
	return log


func _r0_real_matches(d) -> int:
	var n := 0
	for m in (d.tourney["rounds"][0] as Array):
		var md := m as Dictionary
		if bool(md.get("bye", false)) or bool(md.get("vacant", false)):
			continue
		if str(md.get("a_id", "")) != "" and str(md.get("b_id", "")) != "":
			n += 1
	return n


func _r0_real_losers(d) -> Array:
	var out: Array = []
	for m in (d.tourney["rounds"][0] as Array):
		var md := m as Dictionary
		if bool(md.get("bye", false)) or bool(md.get("vacant", false)):
			continue
		var w := str(md.get("winner_id", ""))
		if str(md.get("a_id", "")) == "" or str(md.get("b_id", "")) == "" or w == "":
			continue
		out.append(str(md.get("b_id", "")) if w == str(md.get("a_id", "")) else str(md.get("a_id", "")))
	return out


func _saw_consolation(log: Array) -> bool:
	for a in log:
		if bool((a as Dictionary).get("consolation_started", false)):
			return true
	return false


func test_full16() -> void:
	var d = _new_director()
	var brains := _fakes(16)
	var res: Dictionary = d.build_bracket(_ids(brains), 16, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "16-bracket builds")
	_check(_r0_real_matches(d) == 8, "16-bracket round 0 has 8 real matches")
	var log := _run_to_end(d)
	_check(not log.is_empty(), "16-bracket produced an advance log")
	_check(_saw_consolation(log), "16-bracket starts consolation")
	_check(str((log[log.size() - 1] as Dictionary).get("action", "")) == "tournament_end",
		"16-bracket ends the tournament")
	_check(str(d.tourney.get("champion_id", "")) != "", "16-bracket crowns a champion")
	var last := str(d.tourney.get("last_place_id", ""))
	_check(last != "", "16-bracket decides last place through combat")
	_check(last in _r0_real_losers(d), "last place is a round-0 loser")


func test_short15() -> void:
	# The live 15-roster shape: 7 real matches + 1 bye. Consolation
	# needs exactly 2/4/8 round-0 losers, so it can never start here -
	# this is why a short bracket must never be built.
	var d = _new_director()
	var brains := _fakes(15)
	var res: Dictionary = d.build_bracket(_ids(brains), 16, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "15-bracket builds (bye covers the gap)")
	var r0: Array = d.tourney["rounds"][0]
	var real := 0
	var byes := 0
	for m in r0:
		var md := m as Dictionary
		if bool(md.get("bye", false)):
			byes += 1
		elif str(md.get("a_id", "")) != "" and str(md.get("b_id", "")) != "":
			real += 1
	_check(real == 7 and byes == 1, "15-bracket round 0 is 7 real + 1 bye")
	var log := _run_to_end(d)
	_check(not log.is_empty(), "15-bracket produced an advance log")
	_check(not _saw_consolation(log), "15-bracket can never start consolation")
	_check(str((log[log.size() - 1] as Dictionary).get("action", "")) == "tournament_end",
		"15-bracket still ends")
	_check(str(d.tourney.get("last_place_id", "")) == "",
		"15-bracket decides no last place (would need ranking fallback)")


func _initialize() -> void:
	test_full16()
	test_short15()
	if failures == 0:
		print("ALL EVO-BRACKET-FILL TESTS PASSED")
	else:
		printerr("EVO-BRACKET-FILL TESTS: %d FAILURES" % failures)
	quit(failures)
