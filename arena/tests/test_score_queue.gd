extends SceneTree
## Headless scoring-queue tests: FIFO batch eval probes (enqueue,
## dedupe, cancel/clear, completion advance, progress signal).
## Bare director (python never ready) so nothing spawns.
## Run: godot --headless --path arena -s tests/test_score_queue.gd
## Exit code = failure count (0 = all green).

var failures := 0
var stamped: Array = []
var progressed: Array = []


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_director():
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_score_queue"
	DirAccess.make_dir_recursive_absolute("user://test_score_queue")
	return D


func test_enqueue_dedupe() -> void:
	var d = _new_director()
	_check(d.enqueue_score("a", "Alpha") == 1, "first enqueue position 1")
	_check(d.enqueue_score("b", "Beta") == 2, "second enqueue position 2")
	_check(d.enqueue_score("a", "Alpha") == 0, "duplicate refused")
	_check(d.enqueue_score("", "Nameless") == 0, "empty id refused")
	_check(d.score_queue.size() == 2, "queue holds two")
	d.score_job = {"brain_id": "c"}
	_check(d.enqueue_score("c", "Active") == 0, "active brain refused")
	d.score_job = {}
	_check(d.enqueue_score("c", "Active") == 3, "queued after slot freed")
	d.queue_free()


func test_cancel_clear() -> void:
	var d = _new_director()
	d.enqueue_score("a", "Alpha")
	d.enqueue_score("b", "Beta")
	d.cancel_score_queued(5)
	_check(d.score_queue.size() == 2, "bad index ignored")
	d.cancel_score_queued(0)
	_check(d.score_queue.size() == 1
		and str(d.score_queue[0].get("id", "")) == "b",
		"cancel removes head")
	d.clear_score_queue()
	_check(d.score_queue.is_empty(), "clear empties")
	d.clear_score_queue()
	_check(true, "double clear safe")
	d.queue_free()


func test_pump_without_python() -> void:
	var d = _new_director()
	d.enqueue_score("a", "Alpha")
	# Bare instance: python never ready, launch fails, head retained.
	_check(not d.pump_score_queue(), "pump fails without python")
	_check(d.score_queue.size() == 1, "head retained on failed launch")
	d.queue_free()


func test_completion_advances() -> void:
	var d = _new_director()
	d.score_stamped.connect(func(bid, sc): stamped.append([bid, sc]))
	d.enqueue_score("a", "Alpha")
	d.enqueue_score("b", "Beta")
	# "a" launched (slot set manually); only "b" still queued.
	d.score_queue.pop_front()
	var rf := "user://test_score_queue_done.json"
	var f := FileAccess.open(rf, FileAccess.WRITE)
	f.store_string('{"ok": true, "eval_score": 12.5}')
	f.close()
	d.score_job = {"brain_id": "a", "result_file": rf, "progress_path": ""}
	d._poll_score()
	_check(d.score_job.is_empty(), "slot freed on verdict")
	_check(stamped == [["a", 12.5]], "score stamped with value")
	# No python to launch the next head: it waits, not dropped.
	_check(d.score_queue.size() == 1
		and str(d.score_queue[0].get("id", "")) == "b",
		"next head retained without python")
	d.queue_free()


func test_progress_signal() -> void:
	var d = _new_director()
	d.score_progress.connect(func(ep, total): progressed.append([ep, total]))
	var pf := "user://test_score_queue_prog.json"
	var f := FileAccess.open(pf, FileAccess.WRITE)
	f.store_string('{"episode": 3, "total": 6, "pct": 50.0}')
	f.close()
	d.score_job = {"brain_id": "a",
		"result_file": "user://test_score_queue_missing.json",
		"progress_path": pf}
	d._poll_score()
	_check(progressed == [[3, 6]], "progress emitted ep/total")
	_check(str(d.score_job.get("brain_id", "")) == "a",
		"slot held without verdict")
	d.queue_free()


func _cleanup() -> void:
	if DirAccess.dir_exists_absolute("user://test_score_queue"):
		for f in DirAccess.get_files_at("user://test_score_queue"):
			DirAccess.remove_absolute("user://test_score_queue".path_join(f))
		DirAccess.remove_absolute("user://test_score_queue")


func _initialize() -> void:
	test_enqueue_dedupe()
	test_cancel_clear()
	test_pump_without_python()
	test_completion_advances()
	test_progress_signal()
	_cleanup()
	if failures == 0:
		print("ALL SCORE-QUEUE TESTS PASSED")
	else:
		printerr("SCORE-QUEUE TESTS: %d FAILURES" % failures)
	quit(failures)
