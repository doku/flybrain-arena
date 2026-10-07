extends SceneTree
## Headless queue-persistence tests: train/score queues, active jobs
## and the done ring survive a save/load round-trip; boot adopt
## reattaches live pids, finishes completed verdicts, requeues crashes
## and frees stale async slots; move/set ops reorder and clamp.
## Hermetic (user://test_queues, spawns held, no workers launched).
## Run: godot --headless --path arena -s tests/test_queues.gd
## Exit code = failure count (0 = all green).

var failures := 0
var D = null
var TDIR := "user://test_queues"
var JDIR := "user://test_queues/jobs"


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_director():
	var d = load("res://scripts/TournamentDirector.gd").new()
	d.tournament_dir = TDIR
	d.job_dir = JDIR
	d.hold_spawns = true
	return d


func _setup() -> void:
	DirAccess.make_dir_recursive_absolute(JDIR)
	D = _new_director()


func _cleanup() -> void:
	if D != null:
		D.queue_free()
		D = null
	if DirAccess.dir_exists_absolute(TDIR):
		for f in DirAccess.get_files_at(JDIR):
			DirAccess.remove_absolute(JDIR.path_join(f))
		DirAccess.remove_absolute(JDIR)
		for f in DirAccess.get_files_at(TDIR):
			DirAccess.remove_absolute(TDIR.path_join(f))
		DirAccess.remove_absolute(TDIR)


func _write_result(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func test_save_load_roundtrip() -> void:
	D.enqueue_training("b1", "Bee One", 50, {"curriculum": {}})
	D.enqueue_training("b2", "Bee Two", 30, {})
	D.enqueue_score("b3", "Bee Three")
	D.active_job = {"pid": 111, "progress_path": "p", "result_file": "r",
		"brain_id": "b0", "episodes": 50, "school": false, "name": "Bee Zero",
		"params": {}}
	D.score_job = {"pid": 222, "result_file": "sr", "progress_path": "sp",
		"brain_id": "bs"}
	D.completed_trains = [{"name": "Old", "episodes": 10}]
	D.pending_async = {"pid": 333, "result_file": "ar", "op": "generate"}
	D.call("_save_queues")
	_check(FileAccess.file_exists(JDIR.path_join("queues.json")),
		"queues file written")
	var d2 = _new_director()
	d2.call("_load_queues")
	_check((d2.train_queue as Array).size() == 2
		and str((d2.train_queue[0] as Dictionary).get("id", "")) == "b1",
		"train queue restored in order")
	_check((d2.score_queue as Array).size() == 1, "score queue restored")
	_check(str((d2.active_job as Dictionary).get("brain_id", "")) == "b0",
		"active job restored")
	_check(str((d2.score_job as Dictionary).get("brain_id", "")) == "bs",
		"score job restored")
	_check((d2.completed_trains as Array).size() == 1, "done ring restored")
	_check(str((d2.pending_async as Dictionary).get("op", "")) == "generate",
		"async slot restored")
	d2.queue_free()
	D.train_queue = []
	D.score_queue = []
	D.active_job = {}
	D.score_job = {}
	D.completed_trains = []
	D.pending_async = {}


func test_move_set_ops() -> void:
	D.enqueue_training("m1", "M1", 50, {})
	D.enqueue_training("m2", "M2", 50, {})
	D.enqueue_training("m3", "M3", 50, {})
	_check(not D.call("move_queued", 0, -1), "move off top refuses")
	_check(D.call("move_queued", 1, -1), "move up works")
	_check(str((D.train_queue[0] as Dictionary).get("id", "")) == "m2",
		"move up reorders")
	_check(D.call("move_queued", 0, 1), "move down works")
	_check(str((D.train_queue[1] as Dictionary).get("id", "")) == "m2",
		"move down reorders")
	_check(D.call("move_queued_top", 2), "promote works")
	_check(str((D.train_queue[0] as Dictionary).get("id", "")) == "m3",
		"promote heads the queue")
	_check(not D.call("move_queued_top", 0), "promote head refuses")
	_check(D.call("set_queued_episodes", 0, 100)
		and int((D.train_queue[0] as Dictionary).get("episodes", 0)) == 100,
		"episodes edit applies")
	_check(D.call("set_queued_episodes", 0, 0)
		and int((D.train_queue[0] as Dictionary).get("episodes", 0)) == 1,
		"episodes clamp low")
	_check(D.call("set_queued_episodes", 0, 999)
		and int((D.train_queue[0] as Dictionary).get("episodes", 0)) == 500,
		"episodes clamp high")
	_check(not D.call("set_queued_episodes", 9, 10), "edit off end refuses")
	D.enqueue_score("s1", "S1")
	D.enqueue_score("s2", "S2")
	_check(D.call("move_score_queued", 1, -1)
		and str((D.score_queue[0] as Dictionary).get("id", "")) == "s2",
		"score move reorders")
	_check(D.call("move_score_queued_top", 1)
		and str((D.score_queue[0] as Dictionary).get("id", "")) == "s1",
		"score promote heads")
	_check(not D.call("move_score_queued", 0, -5), "score move off top refuses")
	D.train_queue = []
	D.score_queue = []
	D.call("_save_queues")


func test_boot_adopt_complete() -> void:
	# Finished verdict on disk adopts immediately (done ring + clear).
	var rp := JDIR.path_join("train_done_result.json")
	_write_result(rp, JSON.stringify({"episode": 50, "total": 50,
		"pct": 100.0}))
	D.active_job = {"pid": 999999999, "progress_path": "p",
		"result_file": rp, "brain_id": "bd", "episodes": 50,
		"school": false, "name": "Bee Done", "params": {}}
	D.call("_adopt_boot_queues")
	_check(D.active_job.is_empty(), "completed job cleared")
	_check((D.completed_trains as Array).size() == 1
		and str((D.completed_trains[0] as Dictionary).get("name", "")) == "Bee Done",
		"completed job banked to done ring")
	var sp := JDIR.path_join("score_done_result.json")
	_write_result(sp, JSON.stringify({"ok": true, "eval_score": 4.5}))
	D.score_job = {"pid": 999999999, "result_file": sp,
		"progress_path": "sp", "brain_id": "bs"}
	D.call("_adopt_boot_queues")
	_check(D.score_job.is_empty(), "completed probe cleared")


func test_boot_requeue_crash() -> void:
	# Dead pid, no verdict: back to the head with the exact recipe.
	D.active_job = {"pid": 999999999, "progress_path": "p",
		"result_file": JDIR.path_join("train_gone_result.json"),
		"brain_id": "bc", "episodes": 40, "school": true,
		"name": "Bee Crash", "params": {"curriculum": {}}}
	D.call("_adopt_boot_queues")
	_check(D.active_job.is_empty(), "crashed job cleared")
	_check((D.train_queue as Array).size() == 1
		and str((D.train_queue[0] as Dictionary).get("id", "")) == "bc"
		and int((D.train_queue[0] as Dictionary).get("episodes", 0)) == 40,
		"crashed job requeued with its recipe")
	_check((D.train_queue[0] as Dictionary).has("params"),
		"requeue keeps params")
	D.score_job = {"pid": 999999999,
		"result_file": JDIR.path_join("score_gone_result.json"),
		"progress_path": "sp", "brain_id": "sc"}
	D.call("_adopt_boot_queues")
	_check(D.score_job.is_empty(), "crashed probe cleared")
	_check((D.score_queue as Array).size() == 1
		and str((D.score_queue[0] as Dictionary).get("id", "")) == "sc",
		"crashed probe requeued")
	# Explicit failure verdict fails now (no doomed relaunch).
	var fp := JDIR.path_join("train_fail_result.json")
	_write_result(fp, JSON.stringify({"ok": false, "error": "arity boom"}))
	D.active_job = {"pid": 999999999, "progress_path": "p",
		"result_file": fp, "brain_id": "bf", "episodes": 50,
		"school": false, "name": "Bee Fail", "params": {}}
	D.call("_adopt_boot_queues")
	_check(D.active_job.is_empty(), "failed job cleared")
	_check((D.train_queue as Array).is_empty()
		or str((D.train_queue[0] as Dictionary).get("id", "")) != "bf",
		"failed job not requeued")
	D.train_queue = []
	D.score_queue = []
	D.call("_save_queues")


func test_boot_live_and_stale() -> void:
	# Own process pid counts as alive (reattach); dead pid + no
	# verdict frees the async slot (no 30-minute wedge).
	D.active_job = {"pid": OS.get_process_id(), "progress_path": "p",
		"result_file": JDIR.path_join("train_live_result.json"),
		"brain_id": "bl", "episodes": 50, "school": false,
		"name": "Bee Live", "params": {}}
	D.call("_adopt_boot_queues")
	_check(str((D.active_job as Dictionary).get("brain_id", "")) == "bl",
		"live job reattached")
	D.active_job = {}
	D.pending_async = {"pid": 999999999,
		"result_file": JDIR.path_join("async_gone_result.json"),
		"op": "generate"}
	D.call("_adopt_boot_queues")
	_check((D.pending_async as Dictionary).is_empty(),
		"stale async slot freed")
	D.pending_async = {"pid": OS.get_process_id(),
		"result_file": JDIR.path_join("async_live_result.json"),
		"op": "generate"}
	D.call("_adopt_boot_queues")
	_check(not (D.pending_async as Dictionary).is_empty(),
		"live async slot kept")
	D.pending_async = {}
	D.call("_save_queues")


func test_corrupt_file() -> void:
	_write_result(JDIR.path_join("queues.json"), "not json{{{")
	var d2 = _new_director()
	d2.call("_load_queues")
	_check((d2.train_queue as Array).is_empty()
		and d2.active_job.is_empty(), "corrupt file starts empty")
	d2.queue_free()


func _initialize() -> void:
	_setup()
	test_save_load_roundtrip()
	test_move_set_ops()
	test_boot_adopt_complete()
	test_boot_requeue_crash()
	test_boot_live_and_stale()
	test_corrupt_file()
	_cleanup()
	if failures == 0:
		print("ALL QUEUE TESTS PASSED")
	else:
		printerr("QUEUE TESTS: %d FAILURES" % failures)
	quit(failures)
