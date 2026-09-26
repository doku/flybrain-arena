extends SceneTree
## Headless evo-queue gate tests: a launched breed blocks its sibling
## until adopted, so the pipeline stays sequential (queued means queued).
## Run: godot --headless --path arena -s tests/test_evo_queue.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_arena():
	# Bare instance: no tree, so no director - pending is empty and only
	# the pure spec-state logic is exercised.
	return load("res://scripts/ArenaManager.gd").new()


func test_unlaunched_never_blocks() -> void:
	var a = _new_arena()
	_check(not a._evo_spec_alive({"launched": false, "pid": 0, "result": ""}),
		"unlaunched spec is not alive")
	_check(a._evo_blocking_spec("clone").is_empty(),
		"empty queue blocks nothing")
	a.queue_free()


func test_launched_without_verdict_blocks() -> void:
	var a = _new_arena()
	# Launched, no pid proof, no verdict file: treated as running, so a
	# silently cleared slot can never double-launch the pipeline.
	_check(a._evo_spec_alive({"launched": true, "pid": 0,
		"result": "user://nope_missing_result.json"}),
		"launched spec with no verdict counts as running")
	a.queue_free()


func test_dead_worker_blocks_nothing() -> void:
	var a = _new_arena()
	# Absurd pid is certainly not running; no verdict file either: the
	# liveness gate would drop this spec, so it must not block.
	_check(not a._evo_spec_alive({"launched": true, "pid": 999999999,
		"result": "user://nope_missing_result.json"}),
		"dead worker with no verdict is not alive")
	a.queue_free()


func test_wild_mode_rotation() -> void:
	var a = _new_arena()
	_check(a._evo_wild_mode(1) == "graft", "gen 1 wild grafts")
	_check(a._evo_wild_mode(2) == "shuffle", "gen 2 wild shuffles")
	_check(a._evo_wild_mode(3) == "novelty", "gen 3 wild seeks novelty")
	_check(a._evo_wild_mode(4) == "graft", "rotation wraps at gen 4")
	_check(a._evo_wild_mode(7) == "graft", "gen 7 wild grafts")
	_check(a._evo_clone_parent2(3, "champ") == "",
		"non-4th gen never crosses over")
	_check(a._evo_clone_parent2(4, "champ") == "",
		"no director means no crossover partner")
	a.queue_free()


func test_pip_throttle() -> void:
	var a = _new_arena()
	a.perf_pip = false
	a._update_pip_throttled({}, {})
	_check(a._pip_hidden, "pip hidden flag set when disabled")
	a.perf_pip = true
	a._pip_tick = 0
	a._update_pip_throttled({}, {})
	_check(not a._pip_hidden, "pip restored when enabled")
	a.queue_free()


func test_perf_defaults() -> void:
	var D = load("res://scripts/TournamentDirector.gd").new()
	_check(D.perf_get("pip"), "pip defaults on")
	_check(D.perf_get("glow"), "glow defaults on")
	_check(D.perf_get("shadows"), "shadows defaults on")
	_check(not D.perf_get("nope", false), "unknown key returns default")
	D.queue_free()


func _initialize() -> void:
	test_unlaunched_never_blocks()
	test_launched_without_verdict_blocks()
	test_dead_worker_blocks_nothing()
	test_wild_mode_rotation()
	test_pip_throttle()
	test_perf_defaults()
	if failures == 0:
		print("ALL EVO-QUEUE TESTS PASSED")
	else:
		printerr("EVO-QUEUE TESTS: %d FAILURES" % failures)
	quit(failures)
