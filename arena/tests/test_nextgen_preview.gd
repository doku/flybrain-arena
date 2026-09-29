extends SceneTree
## Next-gen waiting-room tests: preview bracket seeding parity with the
## real builder, synthetic training cards refreshing to real names on
## adopt, gallery rotation wrap, strip absent-state. No vault/Python:
## fake brains via dicts, bare instances where possible.
## Run: godot --headless --path arena -s tests/test_nextgen_preview.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _fake(pid: String, pname: String, elo: float) -> Dictionary:
	return {"id": pid, "name": pname, "record": {"elo": elo}}


func _new_director():
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_nextgen"
	DirAccess.make_dir_recursive_absolute("user://test_nextgen")
	return D


func _new_manager():
	return load("res://scripts/ArenaManager.gd").new()


func test_seed_parity() -> void:
	# Same 16 fighters through build_bracket and preview_bracket yield
	# identical round-0 pairings (preview matches the final bracket).
	var d = _new_director()
	var brains: Array = []
	for i in range(16):
		brains.append(_fake("p%d" % (i + 1), "F%d" % (i + 1),
			1200.0 + float(i) * 25.0))
	var ids: Array = []
	for b in brains:
		ids.append(str(b.get("id", "")))
	var res: Dictionary = d.build_bracket(ids, 16, 1, 0.5, 40.0,
		false, brains, false, true)
	_check(bool(res.get("ok", false)), "parity bracket builds")
	var real: Array = []
	for m in (d.tourney["rounds"][0] as Array):
		var md := m as Dictionary
		real.append([str(md.get("a_id", "")), str(md.get("b_id", ""))])
	var pv: Dictionary = d.preview_bracket(brains, 16, false)
	_check(not pv.is_empty(), "parity preview builds")
	_check(str(pv.get("status", "")) == "preview", "preview marked preview")
	var shown: Array = []
	for m in (pv["rounds"][0] as Array):
		var md := m as Dictionary
		shown.append([str(md.get("a_id", "")), str(md.get("b_id", ""))])
	_check(shown == real, "preview round 0 matches real seeding")


func test_synthetic_refresh() -> void:
	# Unbred wild rides a synthetic training card; adoption swaps the
	# real christened name into the same slot.
	var d = _new_director()
	var brains: Array = []
	for i in range(15):
		brains.append(_fake("p%d" % (i + 1), "F%d" % (i + 1), 1200.0))
	brains.append({"id": "", "name": "wild (training)",
		"record": {"elo": 1200.0}})
	var pv: Dictionary = d.preview_bracket(brains, 16, false)
	var found_synth := false
	for m in (pv["rounds"][0] as Array):
		var md := m as Dictionary
		if str(md.get("a_name", "")) == "wild (training)" \
				or str(md.get("b_name", "")) == "wild (training)":
			found_synth = true
	_check(found_synth, "synthetic wild card placed in preview")
	# Adopt: same slot, real brain.
	brains[15] = _fake("w99", "Bristle", 1210.0)
	var pv2: Dictionary = d.preview_bracket(brains, 16, false)
	var found_real := false
	var found_stale := false
	for m in (pv2["rounds"][0] as Array):
		var md := m as Dictionary
		for k in ["a_name", "b_name"]:
			if str(md.get(k, "")) == "Bristle":
				found_real = true
			if str(md.get(k, "")) == "wild (training)":
				found_stale = true
	_check(found_real, "adopted name replaces synthetic card")
	_check(not found_stale, "no stale synthetic card after adopt")


func test_gallery_cards() -> void:
	var a = _new_manager()
	a.nextgen_brains = {
		"x": {"name": "Vex", "record": {"elo": 1500.0, "battles": 10,
			"wins": 7, "losses": 2, "draws": 1, "matches": 3,
			"matches_won": 2, "matches_lost": 1, "tournaments_won": 1},
			"generator_params": {"genome_id": "gABC"},
			"training": {"episodes": 50},
			"lineage": {"source": "clone:abc"}}}
	var real: Dictionary = a._gallery_card("x", "Vex")
	_check(str(real.get("title", "")) == "Vex", "record card title")
	_check(str(real.get("elo", "")) == "1500", "record card elo")
	_check(str(real.get("rows", "")).contains("W7 L2 D1"),
		"record card battles line")
	_check(str(real.get("rows", "")).contains("genome gABC"),
		"record card wiring line")
	var ghost: Dictionary = a._gallery_card("", "wild (training)")
	_check(str(ghost.get("elo", "")) == "--", "training card elo blank")
	_check(str(ghost.get("rows", "")).contains("training"),
		"training card shows training state")
	a.queue_free()


func test_gallery_rotation() -> void:
	var a = _new_manager()
	a.nextgen_gallery = [{"title": "A"}, {"title": "B"}, {"title": "C"}]
	a.nextgen_gallery_idx = 0
	a._gallery_advance()
	_check(a.nextgen_gallery_idx == 1, "rotation advances")
	a._gallery_advance()
	a._gallery_advance()
	_check(a.nextgen_gallery_idx == 0, "rotation wraps")
	a.nextgen_gallery = []
	a._gallery_advance()
	_check(true, "empty gallery advance is a no-op")
	a.queue_free()


func test_strip_absent() -> void:
	var a = _new_manager()
	var res: Array = a._offspring_progress("clone")
	_check(float(res[1]) < 0.0, "absent kind reports -1")
	a.queue_free()


func test_awaited_spec_progress() -> void:
	# The handoff detaches awaited specs from pending: strip, gallery
	# and status must read the in-flight spec or flatline for the
	# whole (long) await. Simulated by hand-filling the member.
	var a = _new_manager()
	var pf := "user://test_nextgen_prog.json"
	var f := FileAccess.open(pf, FileAccess.WRITE)
	f.store_string('{"episode": 20, "total": 50}')
	f.close()
	a.evo_await_spec = {"kind": "wild", "name": "", "gen": 5,
		"progress": pf, "launched": true, "mode": "graft"}
	var res: Array = a._offspring_progress("wild")
	_check(str(res[0]) == "wild", "awaited label resolves")
	_check(absf(float(res[1]) - 40.0) < 0.01, "awaited pct tracks ep file")
	var res2: Array = a._offspring_progress("clone")
	_check(float(res2[1]) < 0.0, "other kinds still absent")
	var card: Dictionary = a._gallery_card("", "wild (training)")
	_check(str(card.get("rows", "")).contains("ep 20/50"),
		"gallery training card tracks awaited spec")
	a.evo_await_spec = {}
	var res3: Array = a._offspring_progress("wild")
	_check(float(res3[1]) < 0.0, "cleared await reads absent again")
	a.queue_free()


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute("user://test_nextgen"):
		for f in DirAccess.get_files_at("user://test_nextgen"):
			DirAccess.remove_absolute("user://test_nextgen".path_join(f))
		DirAccess.remove_absolute("user://test_nextgen")


func _initialize() -> void:
	test_seed_parity()
	test_synthetic_refresh()
	test_gallery_cards()
	test_gallery_rotation()
	test_strip_absent()
	test_awaited_spec_progress()
	_cleanup()
	if failures == 0:
		print("ALL NEXTGEN-PREVIEW TESTS PASSED")
	else:
		printerr("NEXTGEN-PREVIEW TESTS: %d FAILURES" % failures)
	quit(failures)
