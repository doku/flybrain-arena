extends SceneTree
## Activation drive curve tests (mirrors Python drive_speed): hover at
## zero, ~4 m/s knee, 12 m/s asymptote, ram headroom, hard cap.
## Run: godot --headless --path arena -s tests/test_drive_curve.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_curve() -> void:
	var f = load("res://scripts/FlyPhysics.gd").new()
	_check(f.drive_speed(0.0) == 0.0, "hover at zero drive")
	_check(absf(f.drive_speed(1.0) - 12.0) < 0.001, "full drive is 12")
	_check(absf(f.drive_speed(0.15) - 4.0) < 0.5, "knee near 4 m/s")
	var prev: float = f.drive_speed(0.0)
	for a in [0.1, 0.2, 0.4, 0.6, 0.8, 1.0]:
		var v: float = f.drive_speed(a)
		_check(v > prev, "monotonic at %s" % str(a))
		_check(v <= 12.0, "never above max at %s" % str(a))
		prev = v
	_check(f.drive_speed(-2.0) == 0.0, "negative clamps to hover")
	_check(f.drive_speed(99.0) == 12.0, "overdrive clamps to max")
	_check(absf(f.RAM_EXTRA - 6.0) < 0.001, "ram headroom 6 m/s")
	f.free()


func test_ram_channel() -> void:
	var f = load("res://scripts/FlyPhysics.gd").new()
	f.apply_brain_controls({"thrust": 0.5, "ram_burst": false})
	_check(f.ram_drive == 0.0, "no ram without drive")
	f.apply_brain_controls({"thrust": 0.5, "ram_burst": true})
	_check(f.ram_drive == 1.0, "legacy gate implies full charge")
	f.apply_brain_controls({"thrust": 0.5, "ram_burst": true, "ram_drive": 0.25})
	_check(absf(f.ram_drive - 0.25) < 0.001, "explicit rate wins")
	f.free()


func _initialize() -> void:
	test_curve()
	test_ram_channel()
	if failures == 0:
		print("ALL DRIVE-CURVE TESTS PASSED")
	else:
		printerr("DRIVE-CURVE TESTS: %d FAILURES" % failures)
	quit(failures)
