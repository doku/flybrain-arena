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
	# Returns the advance-action log. Director runtime errors abort the
	# caller frame WITHOUT failing the run, so a null/empty advance is
	# recorded as a failure here instead of silently skipping the rest
	# of the test.
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
		var adv = d.advance_after_match()
		if adv == null or not (adv is Dictionary) or (adv as Dictionary).is_empty():
			_check(false, "advance_after_match returned null/empty (director error above?)")
			break
		log.append(adv)
		if str((adv as Dictionary).get("action", "")) == "tournament_end":
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
	# 1-match consolation IS the final: skipped outright, both archived
	# without fighting (fewer battle wins = last).
	var brains := _fakes(4)
	var res: Dictionary = d.build_bracket(_ids(brains), 4, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-4 bracket builds")
	var log := _run_to_end(d)
	if log.is_empty():
		_check(false, "size-4 produced an advance log")
		return
	var saw_cons := false
	for a in log:
		if bool((a as Dictionary).get("consolation_started", false)):
			saw_cons = true
	_check(not saw_cons, "size-4 final skipped, no consolation start")
	_check(str((log[log.size() - 1] as Dictionary).get("action", "")) == "tournament_end",
		"size-4 ends the tournament")
	_check(int(d.tourney.get("losers_start_round", -1)) > 0, "losers round appended")
	var fin: Dictionary = (d.tourney["rounds"][d.tourney["rounds"].size() - 1] as Array)[0]
	_check(bool(fin.get("skipped", false)), "size-4 final marked skipped")
	var last := str(d.tourney.get("last_place_id", ""))
	_check(last != "", "size-4 last place decided")
	_check(last in _r0_losers(d), "size-4 last place is an R0 loser")
	_check(str(fin.get("winner_id", "")) != "" and str(fin.get("winner_id", "")) != last,
		"size-4 second-last is the final winner")


func test_size8(d) -> void:
	# 4-fighter consolation: last must be 0-3 (R0 loss + 2 consolation
	# losses), NOT the old 2-1 shape (R0 loss + SF win + F loss).
	var brains := _fakes(8)
	var res: Dictionary = d.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-8 bracket builds")
	var log8 := _run_to_end(d)
	if log8.is_empty():
		_check(false, "size-8 produced an advance log")
		return
	_check(str((log8[log8.size() - 1] as Dictionary).get("action", "")) == "tournament_end",
		"size-8 ends the tournament")
	var lf := int(d.tourney.get("losers_start_round", -1))
	_check(lf > 0, "size-8 losers rounds appended")
	_check((d.tourney["rounds"][lf] as Array).size() == 2, "size-8 consolation R1 has 2 matches")
	_check((d.tourney["rounds"][lf + 1] as Array).size() == 1, "size-8 consolation final has 1 match")
	var fin0: Dictionary = (d.tourney["rounds"][lf + 1] as Array)[0]
	_check(bool(fin0.get("skipped", false)), "size-8 final skipped, not fought")
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


func test_skipped_final_tiebreak() -> void:
	# Fewer total battle wins = last place; ties go to b (a takes last).
	var d = _new_director()
	d.tourney = {"rounds": [[
		{"a_id": "p", "b_id": "z", "wins_a": 2, "wins_b": 0, "winner_id": "p"},
		{"a_id": "q", "b_id": "z", "wins_a": 0, "wins_b": 0, "winner_id": "z"},
	]]}
	var fin := {"a_id": "p", "b_id": "q", "wins_a": 0, "wins_b": 0, "winner_id": ""}
	d._resolve_skipped_final(fin)
	_check(str(fin.get("winner_id", "")) == "p", "more wins takes second-last")
	_check(str(d.tourney.get("last_place_id", "")) == "q", "fewer wins is last")
	_check(bool(fin.get("skipped", false)), "resolved final marked skipped")
	var fin2 := {"a_id": "p", "b_id": "q", "wins_a": 0, "wins_b": 0, "winner_id": ""}
	d.tourney = {"rounds": [[]]}
	d._resolve_skipped_final(fin2)
	_check(str(fin2.get("winner_id", "")) == "q", "tie goes to b")
	_check(str(d.tourney.get("last_place_id", "")) == "p", "tie loser a is last")


func test_skip(d) -> void:
	# 5 players in size-8: R0 losers != 2/4/8 -> no consolation, clean end.
	var brains := _fakes(5)
	var res: Dictionary = d.build_bracket(_ids(brains), 8, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "size-8/5-roster bracket builds")
	var log := _run_to_end(d)
	if log.is_empty():
		_check(false, "skip run produced an advance log")
		return
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
	# width = SIDE_PAD + 3*(108+16) + 108 + SIDE_PAD = 504.
	_check(absf(R.custom_minimum_size.x - 504.0) < 0.01,
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
		var adv = d.advance_after_match()
		if adv == null or not (adv is Dictionary) or (adv as Dictionary).is_empty():
			_check(false, "advance_after_match returned null/empty (director error above?)")
			return false
		if bool((adv as Dictionary).get("consolation_started", false)):
			return true
		if str((adv as Dictionary).get("action", "")) == "tournament_end":
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
	# 12 + 2*(190+40) + 190 + 12 = 674.
	_check(absf(R.custom_minimum_size.x - 674.0) < 0.01,
		"focus mode renders losers-only at 674px")
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


func test_bracket_views() -> void:
	var R = load("res://scripts/TournamentBracket.gd").new()
	var D = _new_director()
	var brains := _fakes(8)
	D.build_bracket(_ids(brains), 8, 1, 0.5, 40.0, false, brains, false, true)
	# Fresh size-8 main page: compact pitch fits round 0 outright.
	R.render_bracket(D.tourney, 0, 0, 1)
	_check(absf(R.custom_minimum_size.y - 324.0) < 0.01,
		"compact size-8 main view is 324px tall (no vertical scroll)")
	_check(absf(R.custom_minimum_size.x - 504.0) < 0.01,
		"main-only view keeps 3 cols + champion")
	# No consolation rounds yet: placeholder, not a crash.
	R.render_bracket(D.tourney, 0, 0, 2)
	_check(R.custom_minimum_size.x == 200.0,
		"losers view without consolation shows placeholder")
	_check(_run_to_consolation(D), "consolation starts for view test")
	var lf := int(D.tourney.get("losers_start_round", -1))
	R.render_bracket(D.tourney, lf, 0, 1)
	var seen_losers := false
	var seen_champ := false
	for c in R.get_children():
		if c is Label:
			if str(c.text).begins_with("LOSERS"):
				seen_losers = true
			if str(c.text) == "CHAMPION":
				seen_champ = true
	_check(not seen_losers, "main-only view hides losers columns")
	_check(seen_champ, "main-only view keeps champion column")
	# Losers page at review time: forced focus, not just while live.
	_run_to_end(D)
	R.render_bracket(D.tourney, -1, -1, 2)
	var seen_losers2 := false
	var seen_last := false
	var seen_main := false
	var bad := ["ROUND 1", "ROUND 2", "SEMIFINAL", "FINAL", "CHAMPION"]
	for c in R.get_children():
		if c is Label:
			if str(c.text).begins_with("LOSERS"):
				seen_losers2 = true
			if str(c.text) == "LAST PLACE":
				seen_last = true
			if str(c.text) in bad:
				seen_main = true
	_check(seen_losers2, "losers page shows losers headers at review")
	_check(seen_last, "losers page ends in LAST PLACE")
	_check(not seen_main, "losers page hides main-bracket headers")
	R.queue_free()


func test_review_shows_main_only() -> void:
	# End-of-tournament review (status complete): auto view shows the
	# winners' bracket only - no appended losers columns. Losers stay
	# one toggle away (view 2).
	var R = load("res://scripts/TournamentBracket.gd").new()
	var D = _new_director()
	var brains := _fakes(8)
	D.build_bracket(_ids(brains), 8, 1, 0.5, 40.0, false, brains, false, true)
	_run_to_end(D)
	_check(str(D.tourney.get("status", "")) == "complete",
		"review fixture finished the tournament")
	R.render_bracket(D.tourney,
		int(D.tourney.get("current_round", 0)),
		int(D.tourney.get("current_match", 0)))
	var seen_losers := false
	var seen_champ := false
	for c in R.get_children():
		if c is Label:
			if str(c.text).begins_with("LOSERS"):
				seen_losers = true
			if str(c.text) == "CHAMPION":
				seen_champ = true
	_check(not seen_losers, "review auto view hides losers columns")
	_check(seen_champ, "review auto view ends in CHAMPION")
	R.queue_free()


func test_champ_name_card_bounded() -> void:
	# Long champion names must read prefix-first inside the card:
	# left-aligned in a card-bounded rect (centered text overdraws the
	# card edge and clips away both ends of the name).
	var R = load("res://scripts/TournamentBracket.gd").new()
	var D = _new_director()
	var brains := [_fake("f-long-champion-name-that-overflows-the-card"),
		_fake("f2"), _fake("f3"), _fake("f4")]
	D.build_bracket(_ids(brains), 4, 1, 0.5, 40.0, false, brains)
	# Rig the long name to the title: whoever holds its slot wins.
	var guard := 0
	while guard < 20:
		guard += 1
		var m: Dictionary = D.current_match()
		if m.is_empty():
			break
		if str(m.get("winner_id", "")) == "" \
				and not bool(m.get("bye", false)) \
				and not bool(m.get("vacant", false)):
			var slot := "alpha" if str(m.get("a_id", "")) == "f-long-champion-name-that-overflows-the-card" else "beta"
			_fight_current(D, slot)
		var adv = D.advance_after_match()
		if str((adv as Dictionary).get("action", "")) == "tournament_end":
			break
	_check(str(D.tourney.get("champion_id", "")) == "f-long-champion-name-that-overflows-the-card",
		"rigged final crowns the long name")
	R.render_bracket(D.tourney, -1, -1)
	var found := false
	for c in R.get_children():
		if not (c is PanelContainer):
			continue
		var vb = (c as PanelContainer).get_child(0)
		var labels: Array = []
		for k in vb.get_children():
			if k is Label:
				labels.append(k)
		if labels.size() == 2 and str((labels[0] as Label).text) == "CHAMPION":
			found = true
			var nm := labels[1] as Label
			_check((nm as Label).horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT,
				"champion name left-aligned (prefix survives)")
			_check((nm as Label).clip_text, "champion name clips inside the card")
			_check((nm as Label).custom_minimum_size.x <= R.CARD_W - 16.0 + 0.01,
				"champion name rect fits the card width")
	_check(found, "champion card present in review render")
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
	_check(d1.has_method("_resolve_skipped_final"), "director has _resolve_skipped_final (final skip present)")
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
	test_skipped_final_tiebreak()
	var d4 = _new_director()
	test_skip(d4)
	test_tba_templates()
	test_focus_losers()
	test_bracket_views()
	test_review_shows_main_only()
	test_champ_name_card_bounded()
	_cleanup()
	if failures == 0:
		print("ALL CONSOLATION TESTS PASSED")
	else:
		printerr("CONSOLATION TESTS: %d FAILURES" % failures)
	quit(failures)
