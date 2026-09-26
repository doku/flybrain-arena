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
	test_tournament_id_unique()
	_cleanup()
	if failures == 0:
		print("ALL BATTLE-ID TESTS PASSED")
	else:
		printerr("BATTLE-ID TESTS: %d FAILURES" % failures)
	quit(failures)
