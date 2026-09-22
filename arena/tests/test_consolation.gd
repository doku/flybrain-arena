extends SceneTree
## Headless consolation-bracket tests (loser-advance semantics).
## Run: godot --headless --path arena -s tests/test_consolation.gd
## Uses fake players via brains_override (no vault/Python needed).
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
	# Untyped on purpose: Variant receivers keep director calls dynamic
	# (a static Node annotation would fail compilation on every call).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_consolation"
	DirAccess.make_dir_recursive_absolute("user://test_consolation")
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


func _fight_current(d, slot: String) -> void:
	# best_of=1 -> single battle decides the match.
	var res: Dictionary = d.on_battle_result(slot)
	_check(str(res.get("action", "")) == "match_over", "match over after 1 battle")


func _run_to_end(d) -> Array:
	# Plays every pending match (alpha always wins) until tournament_end.
	# Returns the advance-action log.
	var log: Array = []
	var guard := 0
	while guard < 200:
		guard += 1
		var m: Dictionary = d.current_match()
		if m.is_empty():
			break
		if str(m.get("winner_id", "")) == "" \
				and not bool(m.get("bye", false)) \
				and not bool(m.get("vacant", false)):
			_fight_current(d, "alpha")
		var adv: Dictionary = d.advance_after_match()
		log.append(adv)
		if str(adv.get("action", "")) == "tournament_end":
			break
	return log


func _r0_losers(d) -> Array:
	var out: Array = []
	for m in (d.tourney["rounds"][0] as Array):
		var md := m as Dictionary
		if bool(md.get("bye", false)) or bool(md.get("vacant", false)):
			continue
		var w := str(md.get("winner_id", ""))
		if w == "":
			continue
		out.append(str(md.get("b_id", "")) if w == str(md.get("a_id", "")) else str(md.get("a_id", "")))
	return out


func _match_loser_of(md: Dictionary) -> String:
	var w := str(md.get("winner_id", ""))
	if w == "":
		return ""
	return str(md.get("b_id", "")) if w == str(md.get("a_id", "")) else str(md.get("a_id", ""))


func test_match_loser_unit(d) -> void:
	_check(d._match_loser({"a_id": "x", "b_id": "y", "winner_id": "x"}) == "y",
		"loser of x-beats-y is y")
	_check(d._match_loser({"a_id": "x", "b_id": "y", "winner_id": "y"}) == "x",
		"loser of y-beats-x is x")
	_check(d._match_loser({"a_id": "x", "b_id": "", "winner_id": "x", "bye": true}) == "",
		"bye walkover has no loser")
	_check(d._match_loser({"a_id": "", "b_id": "", "winner_id": "", "vacant": true}) == "",
		"vacant has no loser")
	_check(d._match_loser({"a_id": "x", "b_id": "y", "winner_id": ""}) == "",
		"undecided has no loser")


func test_size4(d) -> void:
	# 1-match consolation: loser-advance == winner-advance outcome.
	var brains := _fakes(4)
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-4 bracket builds")
	var log := _run_to_end(d)
	var saw_cons := false
	for a in log:
		if bool((a as Dictionary).get("consolation_started", false)):
			saw_cons = true
	_check(saw_cons, "size-4 consolation started")
	_check(int(d.tourney.get("losers_start_round", -1)) > 0, "losers rounds appended")
	var last := str(d.tourney.get("last_place_id", ""))
	_check(last != "", "size-4 last place decided")
	_check(last in _r0_losers(d), "size-4 last place is an R0 loser")
	var fin: Dictionary = (d.tourney["rounds"][d.tourney["rounds"].size() - 1] as Array)[0]
	_check(str(fin.get("winner_id", "")) != "" and str(fin.get("winner_id", "")) != last,
		"size-4 second-last is the final winner")


func test_size8(d) -> void:
	# 4-fighter consolation: last must be 0-3 (R0 loss + 2 consolation
	# losses), NOT the old 2-1 shape (R0 loss + SF win + F loss).
	var brains := _fakes(8)
	var res: Dictionary = d.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-8 bracket builds")
	_run_to_end(d)
	var lf := int(d.tourney.get("losers_start_round", -1))
	_check(lf > 0, "size-8 losers rounds appended")
	_check((d.tourney["rounds"][lf] as Array).size() == 2, "size-8 consolation R1 has 2 matches")
	_check((d.tourney["rounds"][lf + 1] as Array).size() == 1, "size-8 consolation final has 1 match")
	# Consolation R1 losers must be the two finalists...
	var r1_losers: Array = []
	for m in (d.tourney["rounds"][lf] as Array):
		r1_losers.append(_match_loser_of(m))
	var fin: Dictionary = (d.tourney["rounds"][lf + 1] as Array)[0]
	var fin_ids := [str(fin.get("a_id", "")), str(fin.get("b_id", ""))]
	_check(fin_ids[0] in r1_losers and fin_ids[1] in r1_losers,
		"size-8 finalists are both consolation R1 losers (loser-advance)")
	var last := str(d.tourney.get("last_place_id", ""))
	_check(last == _match_loser_of(fin), "size-8 last place is the final loser")
	_check(last in _r0_losers(d), "size-8 last place is an R0 loser")
	# ...and the R1 winners must be neither last nor second-last.
	var second := str(fin.get("winner_id", ""))
	for m in (d.tourney["rounds"][lf] as Array):
		var w := str((m as Dictionary).get("winner_id", ""))
		_check(w != last and w != second,
			"size-8 R1 winner %s is neither last nor second-last" % w)


func test_skip(d) -> void:
	# 5 players in size-8: R0 losers != 2/4/8 -> no consolation, clean end.
	var brains := _fakes(5)
	var res: Dictionary = d.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-8/5-roster bracket builds")
	var log := _run_to_end(d)
	_check(not log.is_empty(), "skip run produced an advance log")
	var saw_cons := false
	for a in log:
		if bool((a as Dictionary).get("consolation_started", false)):
			saw_cons = true
	_check(not saw_cons, "underfull consolation skipped")
	_check(str((log[log.size() - 1] as Dictionary).get("action", "")) == "tournament_end",
		"tournament ends cleanly without consolation")


func test_tba_templates() -> void:
	var R = load("res://scripts/TournamentBracket.gd").new()
	var D = _new_director()
	var brains := _fakes(8)
	D.build_bracket(_ids(brains), 8, 1, 0.5, 40.0, false, brains, false, true)
	var before: int = (D.tourney["rounds"] as Array).size()
	R.render_bracket(D.tourney, 0, 0)
	_check((D.tourney["rounds"] as Array).size() == before,
		"TBA synthesis does not mutate tourney rounds")
	# Full template, compact metrics (4 cols > 3): 3 main cols + champion.
	# width = SIDE_PAD + 3*(120+22) + 120 + SIDE_PAD = 570.
	_check(absf(R.custom_minimum_size.x - 570.0) < 0.01,
		"size-8 fresh bracket renders full 3-round template, compact")
	R.queue_free()


func _run_to_consolation(d) -> bool:
	# Plays main-bracket matches (alpha always wins) until the losers
	# bracket starts. Returns true on consolation_started.
	var guard := 0
	while guard < 100:
		guard += 1
		var m: Dictionary = d.current_match()
		if m.is_empty():
			return false
		if str(m.get("winner_id", "")) == "" \
				and not bool(m.get("bye", false)) \
				and not bool(m.get("vacant", false)):
			_fight_current(d, "alpha")
		var adv: Dictionary = d.advance_after_match()
		if bool(adv.get("consolation_started", false)):
			return true
		if str(adv.get("action", "")) == "tournament_end":
			return false
	return false


func test_focus_losers() -> void:
	var R = load("res://scripts/TournamentBracket.gd").new()
	var D = _new_director()
	var brains := _fakes(8)
	D.build_bracket(_ids(brains), 8, 1, 0.5, 40.0, false, brains, false, true)
	_check(_run_to_consolation(D), "consolation starts for focus test")
	var lf := int(D.tourney.get("losers_start_round", -1))
	R.render_bracket(D.tourney, lf, 0)
	# Losers-only (2 cols + final) at normal metrics (3 cols, 2 rows):
	# 12 + 2*(210+52) + 210 + 12 = 758.
	_check(absf(R.custom_minimum_size.x - 758.0) < 0.01,
		"focus mode renders losers-only at 758px")
	var seen_losers := false
	var seen_main := false
	var bad := ["ROUND 1", "ROUND 2", "SEMIFINAL", "FINAL", "CHAMPION"]
	for c in R.get_children():
		if c is Label:
			if str(c.text).begins_with("LOSERS"):
				seen_losers = true
			if str(c.text) in bad:
				seen_main = true
	_check(seen_losers, "focus mode shows losers headers")
	_check(not seen_main, "focus mode hides main-bracket headers")
	R.queue_free()


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute("user://test_consolation"):
		for f in DirAccess.get_files_at("user://test_consolation"):
			DirAccess.remove_absolute("user://test_consolation".path_join(f))
		DirAccess.remove_absolute("user://test_consolation")


func _initialize() -> void:
	var d1 = _new_director()
	# Feature guards: a missing method/arity must FAIL loudly, not
	# false-pass (runtime errors abort the test frame but not the run).
	_check(d1.has_method("_match_loser"), "director has _match_loser (loser-advance present)")
	_check(d1.has_method("build_bracket"), "director has build_bracket")
	if failures > 0:
		printerr("CONSOLATION TESTS: missing features, aborting")
		quit(failures)
		return
	test_match_loser_unit(d1)
	var d2 = _new_director()
	test_size4(d2)
	var d3 = _new_director()
	test_size8(d3)
	var d4 = _new_director()
	test_skip(d4)
	test_tba_templates()
	test_focus_losers()
	_cleanup()
	if failures == 0:
		print("ALL CONSOLATION TESTS PASSED")
	else:
		printerr("CONSOLATION TESTS: %d FAILURES" % failures)
	quit(failures)
