extends SceneTree
## Headless killing-blow ledger tests (FlyPhysics.take_damage routing).
## Run: godot --headless --path arena -s tests/test_killing_blow.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_fly():
	# Bare instance: physics never runs, only the ledger is exercised.
	return load("res://scripts/FlyPhysics.gd").new()


func test_ledger_keeps_last_blow() -> void:
	var f = _new_fly()
	f.health = 100.0
	f.take_damage(15.0, "tree_clip")
	_check(f.health == 85.0, "health reduced")
	_check(f.last_damage_source == "tree_clip", "source recorded")
	_check(f.last_damage_amount == 15.0, "amount recorded")
	f.take_damage(50.0, "tree_slam")
	_check(f.last_damage_source == "tree_slam", "later blow overwrites")
	_check(f.last_damage_amount == 50.0, "later amount overwrites")
	f.queue_free()


func test_disabled_blocks_damage() -> void:
	var f = _new_fly()
	f.health = 10.0
	f.is_disabled = true
	f.take_damage(50.0, "tree_slam")
	_check(f.health == 10.0, "disabled fly takes no damage")
	_check(f.last_damage_source == "", "disabled hit not recorded")
	f.queue_free()


func test_wing_tear_records_forfeit() -> void:
	var f = _new_fly()
	f.health = 100.0
	f.tear_wing("left")
	_check(f.is_disabled, "tear disables (forfeit KO)")
	_check(f.last_damage_source == "wing_tear", "tear recorded as killing event")
	f.queue_free()


func _initialize() -> void:
	test_ledger_keeps_last_blow()
	test_disabled_blocks_damage()
	test_wing_tear_records_forfeit()
	if failures == 0:
		print("ALL KILLING-BLOW TESTS PASSED")
	else:
		printerr("KILLING-BLOW TESTS: %d FAILURES" % failures)
	quit(failures)
