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


func _initialize() -> void:
	test_prefill_num_null_falls_back()
	if failures == 0:
		print("ALL MENU-PREFILL TESTS PASSED")
	else:
		printerr("MENU-PREFILL TESTS: %d FAILURES" % failures)
	quit(failures)
