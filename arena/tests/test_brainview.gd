extends SceneTree
## Headless raster header tests (live firing count + saturation badge).
## Run: godot --headless --path arena -s tests/test_brainview.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _make_raster():
	var R = load("res://scripts/BrainRaster.gd").new()
	return R


func test_header_counts() -> void:
	var r = _make_raster()
	r.setup("visual_t4a", [1, 2, 3], 1684, Color.WHITE, "Alpha")
	_check(r.last_lit == 0, "fresh setup reports zero firing")
	r.push_step([1, 3, 999])
	_check(r.last_lit == 2, "known ids counted, unknown ignored")
	r.push_step([1, 2, 3])
	_check(r.last_lit == 3, "latest step wins")
	r.clear()
	_check(r.last_lit == 0, "clear resets firing count")
	r.setup("visual_t4a", [1], 1684, Color.WHITE, "Alpha")
	_check(r.last_lit == 0, "re-setup resets firing count")


func _initialize() -> void:
	var probe = load("res://scripts/BrainRaster.gd")
	_check(probe != null, "BrainRaster loads")
	if failures > 0:
		quit(failures)
		return
	test_header_counts()
	if failures == 0:
		print("ALL BRAINVIEW TESTS PASSED")
	else:
		printerr("BRAINVIEW TESTS: %d FAILURES" % failures)
	quit(failures)
