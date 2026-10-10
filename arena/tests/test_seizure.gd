extends SceneTree
## Headless seizure-detector tests (FlyPhysics.seizure_tick state machine).
## Run: godot --headless --path arena -s tests/test_seizure.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_fly():
	# Bare instance: _ready never runs (no tree), so only the float
	# state seizure_tick touches is exercised - exactly the unit.
	return load("res://scripts/FlyPhysics.gd").new()


func test_quiet_never_triggers() -> void:
	var f = _new_fly()
	for i in range(100): # 5 s of moderate steering at 20 ms ticks
		_check(not f.seizure_tick(0.5, 0.3, 0.02), "quiet tick %d stays clear" % i)
	_check(f.seizure_events == 0, "no events recorded")
	f.queue_free()


func test_saturated_stuck_is_not_seizure() -> void:
	var f = _new_fly()
	for i in range(100): # firewall yaw, body not turning
		f.seizure_tick(1.0, 0.0, 0.02)
	_check(not f.seizing, "pinned command without spin stays clear")
	f.queue_free()


func test_sustained_spin_latches() -> void:
	var f = _new_fly()
	for i in range(74): # 1.48 s < 1.5 s window
		_check(not f.seizure_tick(1.0, 3.0, 0.02), "pre-window tick %d clear" % i)
	_check(f.seizure_tick(1.0, 3.0, 0.02), "window reached latches seizing")
	_check(f.seizing, "seizing flag latched")
	f.queue_free()


func test_recovery_resets() -> void:
	var f = _new_fly()
	for i in range(100): # 2 s spin -> seizing
		f.seizure_tick(1.0, 3.0, 0.02)
	_check(f.seizing, "spinning fly seizes")
	for i in range(24): # 0.48 s pause < 1.0 s recover
		f.seizure_tick(0.0, 0.0, 0.02)
	_check(f.seizing, "brief pause keeps seizure latched")
	for i in range(30): # 0.6 s more -> full clear second
		f.seizure_tick(0.0, 0.0, 0.02)
	_check(not f.seizing, "full recover second clears seizure")
	_check(f.seizure_time == 0.0, "accumulator reset")
	f.queue_free()


func _initialize() -> void:
	test_quiet_never_triggers()
	test_saturated_stuck_is_not_seizure()
	test_sustained_spin_latches()
	test_recovery_resets()
	if failures == 0:
		print("ALL SEIZURE TESTS PASSED")
	else:
		printerr("SEIZURE TESTS: %d FAILURES" % failures)
	quit(failures)
