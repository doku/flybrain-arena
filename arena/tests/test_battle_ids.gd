extends SceneTree
## Battle-id display + uniqueness tests: expanded human labels for the
## UI (wire ids stay compact), and collision-proof tournament ids.
## Run: godot --headless --path arena -s tests/test_battle_ids.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_expand_match() -> void:
	var A = load("res://scripts/ArenaManager.gd")
	_check(A.expand_match_label("R1M1") == "Round 1, Match 1",
		"R1M1 expands")
	_check(A.expand_match_label("R12M8") == "Round 12, Match 8",
		"multi-digit expands")
	_check(A.expand_match_label("FREE") == "FREE", "FREE passes through")
	_check(A.expand_match_label("") == "", "empty passes through")
	_check(A.expand_match_label("R1M1-B1") == "R1M1-B1",
		"battle id is not a match label")


func test_expand_battle() -> void:
	var A = load("res://scripts/ArenaManager.gd")
	_check(A.expand_battle_id("R1M1-B1") == "Round 1, Match 1, Battle 1",
		"R1M1-B1 expands")
	_check(A.expand_battle_id("R2M3-B12") == "Round 2, Match 3, Battle 12",
		"multi-digit battle expands")
	_check(A.expand_battle_id("-B1") == "Battle 1",
		"labelless battle has no leading comma")
	_check(A.expand_battle_id("FREE-123456") == "FREE-123456",
		"free id passes through")
	_check(A.expand_battle_id("junk") == "junk", "junk passes through")


func test_report_id_unique() -> void:
	# Cross-group collision-proofing: every report carries a nonce, and
	# display strips it back to the familiar label.
	var A = load("res://scripts/ArenaManager.gd")
	_check(A.expand_battle_id("R1M1-B7-1728001234-5678")
		== "Round 1, Match 1, Battle 7", "nonce strips in display")
	_check(A.expand_battle_id("R1M1-B7") == "Round 1, Match 1, Battle 7",
		"un-nonced legacy still expands")
	var I = load("res://scripts/ArenaManager.gd").new()
	I.set("tourney_match_label", "R1M1")
	var seen := {}
	for i in range(10):
		var bid: String = I.call("_current_battle_id")
		seen[bid] = true
		_check(A.expand_battle_id(bid) == "Round 1, Match 1, Battle 1",
			"fresh id displays clean")
	_check(seen.size() >= 9, "report ids unique per call")
	I.free()


func test_forgivable_reply() -> void:
	# Post-fail-loud late replies apply only for the still-owed battle.
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("tourney_match_label", "R1M1")
	A.set("tournament_active", true)
	_check(not bool(A.call("_forgivable_reply", "R1M1-B7-1-1")),
		"nothing owed, nothing forgiven")
	A.set("_seq_forgive_match", {"tournament_id": "", "match": "R1M1",
		"battle": "R1M1-B7-100-200"})
	_check(bool(A.call("_forgivable_reply", "R1M1-B7-100-200")),
		"owed battle forgiven")
	_check(not bool(A.call("_forgivable_reply", "R1M1-B7-100-201")),
		"fresh nonce not forgiven")
	_check(not bool(A.call("_forgivable_reply", "R1M1-B8-100-200")),
		"other battle not forgiven")
	A.set("tourney_match_label", "R1M2")
	_check(not bool(A.call("_forgivable_reply", "R1M1-B7-100-200")),
		"moved-on match not forgiven")
	A.set("tourney_match_label", "R1M1")
	A.set("tournament_active", false)
	_check(not bool(A.call("_forgivable_reply", "R1M1-B7-100-200")),
		"free mode not forgiven")
	A.free()


func test_battle_progress_extends() -> void:
	# Server proof-of-life pushes the confirm deadline out; stray ids
	# and idle contexts never move it.
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("_seq_context", "battle")
	A.set("_seq_battle_id", "R1M1-B7-1-1")
	A.set("_seq_deadline_msec", 1)
	A.call("_on_battle_progress", "R1M1-B7-1-1")
	_check(int(A.get("_seq_deadline_msec")) > Time.get_ticks_msec(),
		"heartbeat extends deadline")
	A.set("_seq_deadline_msec", 1)
	A.call("_on_battle_progress", "R1M1-B7-1-2")
	_check(int(A.get("_seq_deadline_msec")) == 1,
		"stray id never moves deadline")
	A.set("_seq_context", "")
	A.call("_on_battle_progress", "R1M1-B7-1-1")
	_check(int(A.get("_seq_deadline_msec")) == 1,
		"idle context never moves deadline")
	A.free()


func test_tournament_id_unique() -> void:
	# Same-second rebuilds must never share an id (shared ids share a
	# state file AND the server's battle dedup key).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_battle_ids"
	DirAccess.make_dir_recursive_absolute("user://test_battle_ids")
	var id1: String = D.call("_next_tournament_id")
	_check(id1.begins_with("T"), "tid has T prefix")
	var f := FileAccess.open("user://test_battle_ids".path_join(id1 + ".json"),
		FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	var id2: String = D.call("_next_tournament_id")
	_check(id1 != id2, "colliding second yields a distinct id")
	D.queue_free()


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute("user://test_battle_ids"):
		for f in DirAccess.get_files_at("user://test_battle_ids"):
			DirAccess.remove_absolute("user://test_battle_ids".path_join(f))
		DirAccess.remove_absolute("user://test_battle_ids")


func _initialize() -> void:
	test_expand_match()
	test_expand_battle()
	test_report_id_unique()
	test_forgivable_reply()
	test_battle_progress_extends()
	test_tournament_id_unique()
	_cleanup()
	if failures == 0:
		print("ALL BATTLE-ID TESTS PASSED")
	else:
		printerr("BATTLE-ID TESTS: %d FAILURES" % failures)
	quit(failures)
