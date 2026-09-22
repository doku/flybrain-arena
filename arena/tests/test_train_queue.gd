extends SceneTree
## Headless menu-training-queue tests (director logic only, no workers).
## Run: godot --headless --path arena -s tests/test_train_queue.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_director():
	# Untyped on purpose (see test_consolation.gd): Variant receivers
	# keep director calls dynamic. _ready never runs, so python stays
	# unprobed and start_training refuses (safe: no workers spawn).
	var D = load("res://scripts/TournamentDirector.gd").new()
	return D


func test_enqueue_cancel_clear() -> void:
	var d = _new_director()
	_check(d.train_queue.is_empty(), "queue starts empty")
	_check(d.enqueue_training("id1", "Alpha", 50, {}) == 1, "first enqueue pos 1")
	_check(d.enqueue_training("id2", "Beta", 25, {}) == 2, "second enqueue pos 2")
	_check(d.enqueue_training("id1", "Alpha", 10, {}) == 3, "duplicates allowed pos 3")
	_check(d.train_queue.size() == 3, "three deep")
	_check(d.cancel_queued(1), "cancel middle ok")
	_check(d.train_queue.size() == 2, "two remain")
	_check(str(d.train_queue[0].get("id", "")) == "id1", "head intact")
	_check(str(d.train_queue[1].get("id", "")) == "id1", "tail intact")
	_check(not d.cancel_queued(-1), "cancel negative rejected")
	_check(not d.cancel_queued(5), "cancel overrun rejected")
	d.clear_train_queue()
	_check(d.train_queue.is_empty(), "clear empties")
	d.clear_train_queue()
	_check(d.train_queue.is_empty(), "clear idempotent")


func test_purge_queued() -> void:
	var d = _new_director()
	d.enqueue_training("id1", "Alpha", 50, {})
	d.enqueue_training("id2", "Beta", 25, {})
	d.enqueue_training("id1", "Alpha", 10, {})
	_check(d.purge_queued("id1") == 2, "purge drops both entries")
	_check(d.train_queue.size() == 1, "unrelated entry survives")
	_check(str(d.train_queue[0].get("id", "")) == "id2", "survivor is Beta")
	_check(d.purge_queued("ghost") == 0, "purge no-op on absent id")
	_check(d.train_queue.size() == 1, "no-op changes nothing")


func test_pump_refuses_safely() -> void:
	var d = _new_director()
	d.enqueue_training("idx", "Xray", 50, {})
	# No python probed (_ready never ran): spawn refuses, head stays.
	_check(not d.pump_train_queue(), "pump refuses without python")
	_check(d.train_queue.size() == 1, "head kept on failed launch")
	# Busy slot: pump must not touch the queue either.
	d.active_job = {"pid": 999999}
	_check(not d.pump_train_queue(), "pump refuses while busy")
	_check(d.train_queue.size() == 1, "queue intact while busy")


func _initialize() -> void:
	var dd = _new_director()
	_check(dd.has_method("enqueue_training"), "director has enqueue_training")
	_check(dd.has_method("pump_train_queue"), "director has pump_train_queue")
	if failures > 0:
		printerr("TRAIN QUEUE TESTS: missing features, aborting")
		quit(failures)
		return
	test_enqueue_cancel_clear()
	test_purge_queued()
	test_pump_refuses_safely()
	if failures == 0:
		print("ALL TRAIN QUEUE TESTS PASSED")
	else:
		printerr("TRAIN QUEUE TESTS: %d FAILURES" % failures)
	quit(failures)
