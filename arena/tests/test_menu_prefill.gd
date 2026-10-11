extends SceneTree
## Headless menu prefill tests: explicit-null numerics (e.g. brains
## whose record carries "yaw_bias": null) fall back like missing keys
## instead of crashing float(null).
## Run: godot --headless --path arena -s tests/test_menu_prefill.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_prefill_num_null_falls_back() -> void:
	# Load guard first: a script with a parse error makes load()
	# return null, and calling .new() on null aborts this function
	# WITHOUT failing - the suite would print PASSED while testing
	# nothing (this exact blind spot once hid a broken voice-picker
	# cast in MainMenu).
	var scr = load("res://scripts/MainMenu.gd")
	_check(scr != null and scr.can_instantiate(), "menu script loads")
	if scr == null:
		return
	var m = scr.new()
	_check(m._prefill_num(null, 9.0) == 9.0, "null yaw_bias falls back to 9.0")
	_check(m._prefill_num(null, 0.008) == 0.008, "null rate falls back")
	_check(m._prefill_num(3, 1.0) == 3.0, "int converts")
	_check(m._prefill_num(2.5, 1.0) == 2.5, "float passes through")
	_check(m._prefill_num("nope", 4.0) == 4.0, "non-numeric falls back")
	m.queue_free()


func _write_resume_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


func test_find_resume_file() -> void:
	# Resume takes the newest RUNNING tournament: pointer files
	# (_last_battle_verdict), event ledgers (E*) and finished
	# brackets never qualify, whatever their mtimes. The director
	# global is reached as the autoload singleton (the -s runner
	# compiles before autoload names exist, so the bare identifier
	# will not compile here).
	var scr = load("res://scripts/MainMenu.gd")
	_check(scr != null and scr.can_instantiate(), "menu script loads")
	if scr == null:
		return
	var TD = root.get_node_or_null("TournamentDirector")
	_check(TD != null, "director singleton live")
	if TD == null:
		return
	var m = scr.new()
	m._build_layout()
	var old_dir: String = TD.tournament_dir
	TD.tournament_dir = "user://test_resume"
	DirAccess.make_dir_recursive_absolute("user://test_resume")
	var td: String = TD.tournament_dir
	_write_resume_json(td.path_join("Tdead.json"),
		{"id": "DEAD", "status": "complete", "rounds": [[]]})
	_write_resume_json(td.path_join("Trun.json"),
		{"id": "RUN", "status": "running", "rounds": [[]]})
	_write_resume_json(td.path_join("_last_battle_verdict.json"),
		{"key": "x", "result": {}})
	_write_resume_json(td.path_join("Eev.json"),
		{"id": "E", "status": "running", "rounds": [[]]})
	_check(m._find_resume_file().ends_with("Trun.json"),
		"resume picks the running bracket")
	# Nothing runnable: empty, and _on_resume says so instead of
	# opening a stranger.
	DirAccess.remove_absolute(td.path_join("Trun.json"))
	_check(m._find_resume_file() == "", "no running bracket finds none")
	TD.tourney = {}
	m._on_resume()
	_check(str(m.bracket_status.text).begins_with("No running bracket"),
		"empty resume names the next step")
	m.queue_free()
	TD.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_resume"):
		for f in DirAccess.get_files_at("user://test_resume"):
			DirAccess.remove_absolute("user://test_resume".path_join(f))
		DirAccess.remove_absolute("user://test_resume")


func _initialize() -> void:
	test_prefill_num_null_falls_back()
	test_find_resume_file()
	if failures == 0:
		print("ALL MENU-PREFILL TESTS PASSED")
	else:
		printerr("MENU-PREFILL TESTS: %d FAILURES" % failures)
	quit(failures)
