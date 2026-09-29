extends Node
## Autoload singleton: fly-brain vault access + single-elimination tournament flow.
## The arena scene calls into this; it never touches 3D nodes itself.
## Tournament state persists to tournaments/<id>.json after every battle.

const TOURNAMENT_DIRNAME := "tournaments"
const JOB_DIRNAME := "jobs"
const WIN_RATE_FALLBACK := 0.5

var python_exe: String = "python"
var python_extra_args: Array = []
var python_ready: bool = false
var python_probe_error: String = ""
var vault_cli_path: String = ""
var brains_dir: String = ""
var tournament_dir: String = ""
var job_dir: String = ""

# Live arena hook (null while the menu scene is showing).
var arena: Node = null

# Brain-view settings (menu -> arena bus): in-arena neural activation
# overlay. Layers: "bars" (pool rates), "flow" (activation paths),
# "raster" (per-neuron drill-down). Detail 0/1/2 gates UDP payload
# size (counts / +context / +spike ids for raster).
var brainview_enabled: bool = true
var brainview_layer: String = "bars"
var brainview_detail: int = 1
var brainview_replay: bool = false

# Performance settings (menu -> arena bus, persisted user://perf.cfg):
# pip = eye-view PiPs on/off, glow = bloom chain, shadows = sun shadow
# pass. Arena reads them at boot; all default true (current look).
const PERF_PATH := "user://perf.cfg"
const PERF_KEYS := ["pip", "glow", "shadows"]
var _perf_cache := {}


func perf_get(key: String, default: bool = true) -> bool:
	if _perf_cache.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(PERF_PATH) == OK:
			for k in PERF_KEYS:
				_perf_cache[k] = bool(cfg.get_value("video", k, true))
	if _perf_cache.has(key):
		return bool(_perf_cache[key])
	return default


func perf_set(key: String, value: bool) -> void:
	if _perf_cache.is_empty():
		perf_get(key)
	_perf_cache[key] = bool(value)
	var cfg := ConfigFile.new()
	cfg.load(PERF_PATH)
	cfg.set_value("video", key, bool(value))
	cfg.save(PERF_PATH)

# Tournament state (empty dict = inactive).
var tourney: Dictionary = {}
var sudden_death_armed: bool = false

# Background training job: {pid, progress_path, result_file, brain_id,
# episodes, school} or {}.
var active_job: Dictionary = {}
# Eval restamp job after a school train: {pid, result_file, brain_id}
# or {}. Separate slot from training (read-only probe).
var score_job: Dictionary = {}

# One-shot async vault op (e.g. generate): {pid, result_file, op} or {}.
var pending_async: Dictionary = {}

# Menu training queue: FIFO of {id, name, episodes, params}. The menu
# enqueues while a job runs; the pump starts the head whenever the
# shared worker slot frees up. In-memory only (menu restart drops it;
# a running worker keeps going but is no longer polled).
var train_queue: Array = []
# Spawn hold (arena sets from is_round_active): queue pumps refuse to
# boot workers mid-battle (process-boot spikes frame pacing); queued
# work drains in the gaps. Never drops anything, only defers.
var hold_spawns := false

signal vault_changed()
signal job_progress(episode: int, total: int)
signal job_failed(error: String)
signal async_done(op: String, result: Dictionary)
signal train_queue_changed()
signal score_stamped(brain_id: String, score: float)
signal score_progress(episode: int, total: int)
signal score_queue_changed()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Roster cache self-invalidates on every vault change, so hot
	# paths can serve it without shelling Python onto the game thread.
	if not vault_changed.is_connected(invalidate_brains_cache):
		vault_changed.connect(invalidate_brains_cache)
	_resolve_python()
	var env_cli := OS.get_environment("FO_VAULT_CLI")
	if env_cli != "":
		vault_cli_path = env_cli
	else:
		vault_cli_path = ProjectSettings.globalize_path("res://../brain_engine/vault_cli.py")
	var root := ProjectSettings.globalize_path("res://../")
	brains_dir = root.path_join("brains")
	tournament_dir = root.path_join(TOURNAMENT_DIRNAME)
	job_dir = brains_dir.path_join(JOB_DIRNAME)
	DirAccess.make_dir_recursive_absolute(tournament_dir)
	DirAccess.make_dir_recursive_absolute(job_dir)


func _resolve_python() -> void:
	# Probe candidates in order: launcher-provided exe, then PATH lookups,
	# then the Windows py launcher. The first that runs --version wins.
	var candidates: Array = []
	var env_py := OS.get_environment("FO_PY")
	if env_py != "":
		candidates.append([env_py])
	candidates.append(["python3"])
	candidates.append(["python"])
	candidates.append(["py", "-3"])
	for cand in candidates:
		var exe: String = cand[0]
		var pargs: Array = cand.slice(1)
		var out: Array = []
		var code := OS.execute(exe, pargs + ["--version"], out, true)
		if code == 0:
			python_exe = exe
			python_extra_args = pargs
			python_ready = true
			python_probe_error = ""
			return
		python_probe_error = "probe '%s --version' -> exit %d (%s)" % [exe, code,
			str(out[0]) if not out.is_empty() else "no output"]
	python_ready = false


func python_status() -> Dictionary:
	return {"ready": python_ready, "exe": python_exe,
		"extra": python_extra_args, "probe": python_probe_error}


var _project_root_cache := ""


func project_root() -> String:
	# Memoized: path globalization is a per-click cost on export/import/
	# breed; the res:// root never changes within a session.
	if _project_root_cache == "":
		_project_root_cache = ProjectSettings.globalize_path("res://../")
	return _project_root_cache


# ── Vault operations (via vault_cli.py) ─────────────────────────────

func _cli_argv(args: Array) -> Array:
	return python_extra_args + [vault_cli_path] + args


func _parse_cli_output(out: Array, code: int) -> Dictionary:
	# vault_cli prints log lines (loader etc.) before the final result JSON:
	# scan for the LAST line that parses to a result dict.
	var lines: Array = []
	for item in out:
		for line in str(item).split("\n"):
			var trimmed := line.strip_edges()
			if not trimmed.is_empty():
				lines.append(trimmed)
	var seen: Dictionary = {}
	for i in range(lines.size() - 1, -1, -1):
		var parsed = JSON.parse_string(str(lines[i]))
		if parsed is Dictionary and (parsed as Dictionary).has("ok"):
			seen = parsed
			break
	if not seen.is_empty():
		return seen
	var snippet := ""
	for i in range(mini(lines.size(), 4)):
		snippet += str(lines[i]) + " | "
	if code != 0:
		return {"ok": false, "error": "vault_cli exit %d (%s %s): %s" % [
			code, python_exe, str(python_extra_args), snippet]}
	return {"ok": false, "error": "vault_cli bad JSON: %s" % snippet}


func _run_cli(args: Array) -> Dictionary:
	if not python_ready:
		return {"ok": false, "error": "no working python found (%s)" % python_probe_error}
	var out: Array = []
	var code := OS.execute(python_exe, _cli_argv(args), out, true)
	return _parse_cli_output(out, code)


func _worker_affinity_mask_for(n: int) -> int:
	# Bitmask keeping workers off the game's cores: reserve CPU 0 on
	# small machines, CPUs 0-1 on roomy ones. Pure (unit-tested).
	if n <= 2:
		return (1 << n) - 1  # Nowhere to hide; priority alone must do.
	var full := -1 if n >= 63 else (1 << n) - 1
	if n <= 4:
		return full & ~1
	return full & ~3


func _soften_worker(pid: int) -> void:
	# Background workers (breeds/trains/probes) run long CPU-heavy jobs
	# beside the live fight: drop them below normal priority AND pin them
	# off the game's cores, so frame pacing never contends with them.
	# Fire-and-forget helper process; any failure (exited pid,
	# non-Windows host) is silently ignored.
	if pid <= 0 or OS.get_name() != "Windows":
		return
	var mask := _worker_affinity_mask_for(maxi(OS.get_processor_count(), 1))
	OS.create_process("powershell.exe", ["-NoProfile", "-NonInteractive",
		"-WindowStyle", "Hidden", "-Command",
		"try { $p=[System.Diagnostics.Process]::GetProcessById(%d); $p.PriorityClass='BelowNormal'; $p.ProcessorAffinity=[Int64]%d } catch {}" % [pid, mask]],
		false)


func _spawn_worker(argv: Array) -> int:
	# Spawn a background Python worker confined to the non-game cores:
	# single-threaded BLAS (numpy would otherwise fan OpenBLAS/MKL
	# threads across every core) + below-normal priority + affinity
	# (see _soften_worker). Env is restored right after spawn; the
	# child already inherited its copy.
	var saved := {}
	for key in ["OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"]:
		saved[key] = OS.get_environment(key) if OS.has_environment(key) else null
		OS.set_environment(key, "1")
	var pid := OS.create_process(python_exe, argv, false)
	for key in saved.keys():
		if saved[key] == null:
			OS.set_environment(key, "")
		else:
			OS.set_environment(key, str(saved[key]))
	if pid > 0:
		_soften_worker(pid)
	return pid


func run_cli_async(op: String, args: Array, result_file: String,
		timeout_msec: int = 1800000) -> Dictionary:
	# Non-blocking vault op: the CLI writes its result JSON to result_file;
	# _process polls it and emits async_done(op, result). Keeps the menu alive.
	# timeout_msec bounds the wait (default 30 min); long breeds pass an
	# episodes-proportional budget so a still-training worker is never
	# reported timed-out while it keeps working.
	if not python_ready:
		return {"ok": false, "error": "no working python found (%s)" % python_probe_error}
	if not pending_async.is_empty():
		return {"ok": false, "error": "another operation is already running"}
	if FileAccess.file_exists(result_file):
		DirAccess.remove_absolute(result_file)
	var pid := _spawn_worker(_cli_argv(args + ["--result-file", result_file]))
	if pid <= 0:
		return {"ok": false, "error": "could not spawn '%s'" % python_exe}
	pending_async = {"pid": pid, "result_file": result_file, "op": op,
		"started": Time.get_ticks_msec(), "timeout_msec": timeout_msec}
	return {"ok": true, "pid": pid}


func _poll_async() -> void:
	if pending_async.is_empty():
		return
	var rf := str(pending_async.get("result_file", ""))
	if FileAccess.file_exists(rf):
		var f := FileAccess.open(rf, FileAccess.READ)
		var result: Dictionary = {"ok": false, "error": "unreadable result file"}
		if f != null:
			var text := f.get_as_text().strip_edges()
			f.close()
			if text.begins_with("{") and text.ends_with("}"):
				var parsed = JSON.parse_string(text)
				if parsed is Dictionary:
					result = parsed
			elif not text.is_empty():
				return  # Partial write; retry next frame.
		var op := str(pending_async.get("op", ""))
		pending_async = {}
		if result.get("ok", false):
			vault_changed.emit()
		async_done.emit(op, result)
	elif Time.get_ticks_msec() - int(pending_async.get("started", 0)) \
			> int(pending_async.get("timeout_msec", 1800000)):
		var op2 := str(pending_async.get("op", ""))
		pending_async = {}
		async_done.emit(op2, {"ok": false, "error": "operation timed out"})


const BRAINS_CACHE_TTL_MSEC := 60000
var brains_cache: Array = []
var brains_cache_msec: int = 0
# Event-manifest cache (mtime-gated): the 5 s watcher tick re-parsed the
# manifest 3x per tick mid-battle. Writers write through; handoff code
# keeps the forcing (uncached) path.
var event_cache: Dictionary = {}
var event_cache_mtime: int = 0
# Progress emit-once tracking (job + score slots): signals fire only on
# (episode, total) change, never per poll tick.
var _last_job_ep := -1
var _last_job_total := -1
var _last_job_text := ""
var _last_job_res := {}
var _last_score_ep := -1
var _last_score_total := -1
var _last_score_text := ""


func invalidate_brains_cache() -> void:
	brains_cache = []


func list_brains() -> Array:
	var res := _run_cli(["list"])
	if res.get("ok", false):
		return res.get("brains", [])
	push_warning("[Director] vault list failed: %s" % res.get("error", "?"))
	return []


func list_brains_cached(ttl_msec: int = BRAINS_CACHE_TTL_MSEC) -> Array:
	# Hot-path roster (topup tick, gallery, previews): serves the cache
	# instead of booting a Python interpreter on the game thread (~1-2 s
	# freeze per call). Self-invalidates on vault_changed; a backend
	# hiccup serves stale rather than empty.
	if not brains_cache.is_empty() \
			and Time.get_ticks_msec() - brains_cache_msec < ttl_msec:
		return brains_cache
	var fresh := list_brains()
	if fresh.is_empty() and not brains_cache.is_empty():
		return brains_cache
	brains_cache = fresh
	brains_cache_msec = Time.get_ticks_msec()
	return brains_cache


func archive_list() -> Array:
	# Hall of shame: archived biggest losers, newest last.
	var res := _run_cli(["archive-list"])
	if res.get("ok", false):
		return res.get("archived", [])
	push_warning("[Director] archive list failed: %s" % res.get("error", "?"))
	return []


func restore_archived(arch_id: String) -> Dictionary:
	return _run_cli(["restore", "--id", arch_id])


func delete_archived(arch_id: String) -> Dictionary:
	var res := _run_cli(["archive-delete", "--id", arch_id])
	if res.get("ok", false):
		vault_changed.emit()
	return res


func generate_brain_async(brain_name: String, params: Dictionary) -> Dictionary:
	var params_file := job_dir.path_join("gen_params_%d.json" % Time.get_ticks_msec())
	var f := FileAccess.open(params_file, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "cannot write params file"}
	f.store_string(JSON.stringify(params))
	f.close()
	var result_file := job_dir.path_join("gen_result_%d.json" % Time.get_ticks_msec())
	return run_cli_async("generate", ["generate", "--name", brain_name,
		"--params-file", params_file], result_file)


func derive_mapping(genome_seed: int, genome_rules: int) -> Dictionary:
	# Resolves a wiring genome seed to its mapping without touching the
	# CSR (pure rule-table lookup, ~100 ms): returns {ok, mapping,
	# genome_id, genome_label, n_rules}. Menus call this to display a
	# genome before generating; records always carry concrete stacks.
	return _run_cli(["derive-mapping", "--genome-seed", str(genome_seed),
		"--genome-rules", str(genome_rules)])


func delete_brain(brain_id: String) -> Dictionary:
	var res := _run_cli(["delete", "--id", brain_id])
	if res.get("ok", false):
		vault_changed.emit()
		# A queued entry for a deleted brain would burn at launch
		# (worker fails instantly, fail-path pump eats the next) and
		# look exactly like vanishing queue items. Purge up front.
		purge_queued(brain_id)
	return res


func rename_brain(brain_id: String, new_name: String) -> Dictionary:
	var res := _run_cli(["rename", "--id", brain_id, "--name", new_name])
	if res.get("ok", false):
		vault_changed.emit()
	return res


func export_brain(brain_id: String, out_path: String) -> Dictionary:
	return _run_cli(["export", "--id", brain_id, "--out", out_path])


func import_brain(npz_path: String, brain_name: String) -> Dictionary:
	var res := _run_cli(["import", "--npz", npz_path, "--name", brain_name])
	if res.get("ok", false):
		vault_changed.emit()
	return res


func start_training(brain_id: String, episodes: int, params: Dictionary,
		snapshot: bool = true) -> Dictionary:
	if not python_ready:
		return {"ok": false, "error": "no working python found (%s)" % python_probe_error}
	if not active_job.is_empty():
		return {"ok": false, "error": "a training job is already running"}
	var progress_path := job_dir.path_join("train_%s.json" % brain_id)
	var f := FileAccess.open(progress_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"episode": 0, "total": episodes, "pct": 0.0}))
		f.close()
	var params_file := job_dir.path_join("train_params_%s.json" % brain_id)
	var pf := FileAccess.open(params_file, FileAccess.WRITE)
	if pf == null:
		return {"ok": false, "error": "cannot write params file"}
	pf.store_string(JSON.stringify(params))
	pf.close()
	# Result file carries the backend's final verdict (success summary or
	# error text). Without it a crash before episode 1 leaves progress at
	# 0/50 forever with no explanation.
	var result_file := job_dir.path_join("train_%s_result.json" % brain_id)
	if FileAccess.file_exists(result_file):
		DirAccess.remove_absolute(result_file)
	var args: Array = _cli_argv(["train", "--id", brain_id,
		"--episodes", str(episodes), "--params-file", params_file,
		"--progress", progress_path, "--result-file", result_file]
		+ (["--snapshot"] if snapshot else []))
	var pid := _spawn_worker(args)
	if pid <= 0:
		return {"ok": false, "error": "could not spawn '%s'" % python_exe}
	active_job = {"pid": pid, "progress_path": progress_path,
		"result_file": result_file, "brain_id": brain_id,
		"episodes": episodes, "school": params.has("curriculum")}
	_last_job_text = ""
	_last_job_res = {}
	return {"ok": true, "pid": pid}


func poll_job() -> Dictionary:
	if active_job.is_empty():
		return {}
	var res := {"episode": 0, "total": int(active_job.get("episodes", 0)), "pct": 0.0}
	var f := FileAccess.open(str(active_job.get("progress_path", "")), FileAccess.READ)
	if f != null:
		# Guard: the CLI rewrites this file concurrently; never feed a
		# partial read to the JSON parser (it logs an error per bad call).
		var text := f.get_as_text().strip_edges()
		f.close()
		if text.begins_with("{") and text.ends_with("}"):
			# Skip the parse when the text is unchanged (the poller
			# re-reads between episode writes); reuse the last parsed
			# dict so the emit check below never fires on a zero
			# default (progress-bar flicker to 0 between episodes).
			if text != _last_job_text:
				_last_job_text = text
				var parsed = JSON.parse_string(text)
				if parsed is Dictionary:
					res = parsed
					_last_job_res = res
			else:
				res = _last_job_res
	var ep_now := int(res.get("episode", 0))
	var total_now := int(res.get("total", 0))
	if ep_now != _last_job_ep or total_now != _last_job_total:
		_last_job_ep = ep_now
		_last_job_total = total_now
		job_progress.emit(ep_now, total_now)
	if float(res.get("pct", 0.0)) >= 100.0:
		print("[Director] Job done: %s (%d/%d)" % [
			str(active_job.get("brain_id", "?")),
			int(res.get("episode", 0)), int(res.get("total", 0))])
		# School trains earn a probe top-up (eval_only, weights
		# untouched): its points bank into the single score odometer
		# under the same rules as training.
		var done_school := bool(active_job.get("school", false))
		var done_id := str(active_job.get("brain_id", ""))
		active_job = {}
		vault_changed.emit()
		_pump_train_queue()
		if done_school and done_id != "":
			# Via the queue (never silently dropped when a batch
			# probe holds the slot; id doubles as display name).
			enqueue_score(done_id, done_id)
		return res
	# Fail loud: the backend writes its result file on success AND on
	# error. If the process is gone without reaching 100%, the job
	# crashed (e.g. arity mismatch before episode 1) - report the backend
	# error instead of hanging at episode 0/50 forever.
	var pid := int(active_job.get("pid", 0))
	if pid > 0 and not OS.is_process_running(pid):
		var err_text := _read_job_result_error(str(active_job.get("result_file", "")))
		print("[Director] Job failed: %s - %s" % [
			str(active_job.get("brain_id", "?")), err_text])
		active_job = {}
		job_failed.emit(err_text)
		_pump_train_queue()
	return res


func enqueue_training(brain_id: String, brain_name: String, episodes: int,
		params: Dictionary) -> int:
	# Appends a training job; returns its 1-based queue position. The
	# caller decides start-now vs queue (see _pump_train_queue).
	train_queue.append({"id": brain_id, "name": brain_name,
		"episodes": maxi(1, episodes), "params": params})
	print("[Director] Queued %s x%d (#%d, depth %d)" % [brain_name,
		maxi(1, episodes), train_queue.size(), train_queue.size()])
	train_queue_changed.emit()
	return train_queue.size()


func cancel_queued(index: int) -> bool:
	if index < 0 or index >= train_queue.size():
		return false
	print("[Director] Queue cancel: %s (had %d waiting)" % [
		str((train_queue[index] as Dictionary).get("name", "?")),
		train_queue.size()])
	train_queue.remove_at(index)
	train_queue_changed.emit()
	return true


func purge_queued(brain_id: String) -> int:
	# Drops every queued entry for a deleted brain. Returns the count
	# removed (0 = nothing to do, no signal).
	var kept: Array = []
	for spec in train_queue:
		if str((spec as Dictionary).get("id", "")) != brain_id:
			kept.append(spec)
	var dropped := train_queue.size() - kept.size()
	if dropped > 0:
		print("[Director] Queue purge: dropped %d entr%s for deleted %s" % [
			dropped, "y" if dropped == 1 else "ies", brain_id])
		train_queue = kept
		train_queue_changed.emit()
	return dropped


func clear_train_queue() -> void:
	if train_queue.is_empty():
		return
	train_queue.clear()
	train_queue_changed.emit()


func pump_train_queue() -> bool:
	# Starts the queue head when the worker slot is free. Returns true
	# when a job launched. A failed launch keeps the head (transient
	# spawn trouble must not eat the queue).
	return _pump_train_queue()


func _pump_train_queue() -> bool:
	if hold_spawns:
		return false
	if not active_job.is_empty() or train_queue.is_empty():
		return false
	var head: Dictionary = train_queue[0]
	# Queued/top-up trains skip the pre-train snapshot (opt-in backups):
	# a full 19-100 MB copy per queued episode batch is disk-safety only.
	var res: Dictionary = start_training(str(head.get("id", "")),
		int(head.get("episodes", 0)), head.get("params", {}), false)
	if not bool(res.get("ok", false)):
		print("[Director] Queued training deferred for %s: %s" % [
			str(head.get("name", "?")), str(res.get("error", "?"))])
		return false
	print("[Director] Auto-starting queued %s (%d left waiting)" % [
		str(head.get("name", "?")), train_queue.size() - 1])
	train_queue.pop_front()
	train_queue_changed.emit()
	return true


func _read_job_result_error(result_file: String) -> String:
	if result_file != "" and FileAccess.file_exists(result_file):
		var rf := FileAccess.open(result_file, FileAccess.READ)
		if rf != null:
			var text := rf.get_as_text().strip_edges()
			rf.close()
			if text.begins_with("{") and text.ends_with("}"):
				var parsed = JSON.parse_string(text)
				if parsed is Dictionary:
					if not bool(parsed.get("ok", false)):
						return str(parsed.get("error", "training process exited"))
					return "training process exited before finishing"
	return "training process exited before episode 1 (see brains/jobs log)"


const POLL_EVERY_SEC := 0.25
var _poll_accum := 0.0


func _process(delta: float) -> void:
	# Job-slot polling throttled to ~4 Hz: per-frame file opens + JSON
	# parses were pure syscall churn; a 0.25 s delay is invisible on a
	# progress bar and pushes completion detection by at most one tick.
	_poll_accum += delta
	if _poll_accum < POLL_EVERY_SEC:
		return
	_poll_accum = 0.0
	if not active_job.is_empty():
		poll_job()
	if not score_job.is_empty():
		_poll_score()
	if not pending_async.is_empty():
		_poll_async()


# Menu scoring queue: FIFO of {id, name}. Batch eval probes run one
# at a time in the score slot; in-memory only like the train queue.
var score_queue: Array = []


func enqueue_score(brain_id: String, brain_name: String) -> int:
	# Appends unless empty/already active/queued; pumps immediately.
	# Returns 1-based queue position (0 = refused).
	if brain_id == "":
		return 0
	if str(score_job.get("brain_id", "")) == brain_id:
		return 0
	for item in score_queue:
		if str((item as Dictionary).get("id", "")) == brain_id:
			return 0
	score_queue.append({"id": brain_id, "name": brain_name})
	var pos := score_queue.size()
	print("[Director] Queued scoring %s (#%d)" % [brain_name, pos])
	score_queue_changed.emit()
	pump_score_queue()
	return pos


func cancel_score_queued(index: int) -> void:
	if index < 0 or index >= score_queue.size():
		return
	print("[Director] Unqueued scoring %s (%d left)" % [
		str((score_queue[index] as Dictionary).get("name", "?")),
		score_queue.size() - 1])
	score_queue.remove_at(index)
	score_queue_changed.emit()


func clear_score_queue() -> void:
	if score_queue.is_empty():
		return
	score_queue.clear()
	score_queue_changed.emit()


func pump_score_queue() -> bool:
	# Starts the queue head when the score slot is free. A failed
	# launch keeps the head (transient spawn trouble must not eat it).
	return _pump_score_queue()


func _pump_score_queue() -> bool:
	if hold_spawns:
		return false
	if not score_job.is_empty() or score_queue.is_empty():
		return false
	var head: Dictionary = score_queue[0]
	if not _launch_score(str(head.get("id", ""))):
		print("[Director] Queued scoring deferred for %s." % [
			str(head.get("name", "?"))])
		return false
	print("[Director] Auto-starting scoring %s (%d left waiting)" % [
		str(head.get("name", "?")), score_queue.size() - 1])
	score_queue.pop_front()
	score_queue_changed.emit()
	return true


func _launch_score(brain_id: String) -> bool:
	# Eval-only probe after a school train (~2 min, weights untouched).
	# One at a time; a probe failure only logs (the train already banked).
	if not score_job.is_empty() or not python_ready:
		return false
	var result_file := job_dir.path_join("score_%s_result.json" % brain_id)
	if FileAccess.file_exists(result_file):
		DirAccess.remove_absolute(result_file)
	var progress_path := job_dir.path_join("score_%s.json" % brain_id)
	var f := FileAccess.open(progress_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"episode": 0, "total": 6, "pct": 0.0}))
		f.close()
	var pid := _spawn_worker(_cli_argv(["score", "--id", brain_id, "--episodes", "6",
		"--seed", "7", "--progress", progress_path,
		"--result-file", result_file]))
	if pid <= 0:
		print("[Director] Eval probe failed to spawn for %s." % brain_id)
		return false
	score_job = {"pid": pid, "result_file": result_file,
		"progress_path": progress_path, "brain_id": brain_id}
	_last_score_text = ""
	print("[Director] Eval probe started for %s." % brain_id)
	return true


func _poll_score() -> void:
	var rf := str(score_job.get("result_file", ""))
	var bid := str(score_job.get("brain_id", ""))
	var pf := str(score_job.get("progress_path", ""))
	if pf != "":
		var pfr := FileAccess.open(pf, FileAccess.READ)
		if pfr != null:
			var ptext := pfr.get_as_text().strip_edges()
			pfr.close()
			# Skip the parse when the text is unchanged; emit only on
			# (episode, total) change.
			if ptext != _last_score_text:
				_last_score_text = ptext
				if ptext.begins_with("{") and ptext.ends_with("}"):
					var pparsed = JSON.parse_string(ptext)
					if pparsed is Dictionary:
						var ep_s := int(pparsed.get("episode", 0))
						var total_s := int(pparsed.get("total", 0))
						if ep_s != _last_score_ep or total_s != _last_score_total:
							_last_score_ep = ep_s
							_last_score_total = total_s
							score_progress.emit(ep_s, total_s)
	var f := FileAccess.open(rf, FileAccess.READ)
	if f != null:
		var text := f.get_as_text().strip_edges()
		f.close()
		if text.begins_with("{") and text.ends_with("}"):
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary:
				score_job = {}
				if bool(parsed.get("ok", false)):
					var sc := float(parsed.get("eval_score", 0.0))
					print("[Director] Eval score %.1f stamped for %s." % [sc, bid])
					score_stamped.emit(bid, sc)
				else:
					print("[Director] Eval probe failed for %s: %s" % [
						bid, str(parsed.get("error", "?"))])
				vault_changed.emit()
				pump_score_queue()
				return
			return  # Partial write; retry next frame.
	var pid := int(score_job.get("pid", 0))
	if pid > 0 and not OS.is_process_running(pid):
		print("[Director] Eval probe died silently for %s (see brains/jobs log)." % bid)
		score_job = {}
		pump_score_queue()


# ── Tournament setup ────────────────────────────────────────────────

func tournament_active() -> bool:
	return not tourney.is_empty() and tourney.get("status", "") == "running"


func is_quick() -> bool:
	return tournament_active() and bool(tourney.get("quick", false))


func start_quick_battle(a_id: String, b_id: String, random_draw: bool = false) -> Dictionary:
	if a_id == "" or b_id == "" or a_id == b_id:
		return {"ok": false, "error": "pick two different brains"}
	return build_bracket([a_id, b_id], 2, 1, 0.5, 40.0, true, [], random_draw)


func best_of_options() -> Array:
	return [1, 3, 5, 7, 9, 11]


# ── Continuous tournament mode: eternal loop ──────────────────────
# Each generation archives the biggest loser and breeds 1 winner-clone
# + 1 random, holding roster size constant. State rides in
# tourney["evo"] (persisted by save_state), so quit/resume just works.

func evo_ranking() -> Array:
	# Player ids worst-first: earliest exit round, then fewest battle
	# wins. Mirrors evo_breeder.biggest_loser (Python, unit-tested);
	# keep the two in sync when touching this rule.
	var last_round := {}
	var bwins := {}
	for ri in range(tourney.get("rounds", []).size()):
		var rnd: Array = tourney["rounds"][ri]
		for m in rnd:
			if not (m is Dictionary):
				continue
			for side in ["a", "b"]:
				var pid := str(m.get("a_id" if side == "a" else "b_id", ""))
				if pid == "":
					continue
				last_round[pid] = ri
				var wkey := "wins_a" if side == "a" else "wins_b"
				bwins[pid] = int(bwins.get(pid, 0)) + int(m.get(wkey, 0))
	var ids := last_round.keys()
	ids.sort_custom(func(p, q):
		if last_round[p] != last_round[q]:
			return last_round[p] < last_round[q]
		if int(bwins.get(p, 0)) != int(bwins.get(q, 0)):
			return int(bwins.get(p, 0)) < int(bwins.get(q, 0))
		return str(p) < str(q))
	return ids


func evo_vault_ids() -> Array:
	# Ids physically present in the vault right now. Tournament rounds
	# can reference brains deleted/archived mid-event (resumed old
	# brackets, manual deletes); elimination must skip the missing
	# instead of aborting the generation on a ghost.
	var ids: Array = []
	for b in list_brains_cached():
		ids.append(str((b as Dictionary).get("id", "")))
	return ids


func evo_biggest_loser() -> Dictionary:
	return evo_bottom_two().get("last", {"id": "", "via": "none"})


func evo_bottom_two() -> Dictionary:
	# Bottom two THROUGH COMBAT: the losers-final loser is last place,
	# the losers-final winner is second-last — both decided by a full
	# best-of match, never by battle win/loss tallies. Falls back to
	# earliest-exit ranking only when no consolation ran.
	var present := evo_vault_ids()
	var champ := str(tourney.get("champion_id", ""))
	var last := str(tourney.get("last_place_id", ""))
	if last != "" and last != champ and last in present:
		var second := ""
		var losers_from := int(tourney.get("losers_start_round", -1))
		if losers_from >= 0:
			var rounds: Array = tourney.get("rounds", [])
			var fin: Dictionary = (rounds[rounds.size() - 1] as Array)[0]
			var w := str(fin.get("winner_id", ""))
			if w != "" and w != last and w in present:
				second = w
		if second != "":
			return {"last": {"id": last, "via": "consolation"},
				"second": {"id": second, "via": "consolation"}}
	var ranked: Array = []
	for pid in evo_ranking():
		if str(pid) != champ and str(pid) in present:
			ranked.append(str(pid))
	# A valid consolation last-place survives even when its partner is
	# missing: second falls back to ranking, never the reverse.
	if last != "" and last != champ and last in present:
		var rest: Array = []
		for pid in ranked:
			if str(pid) != last:
				rest.append(str(pid))
		return {"last": {"id": last, "via": "consolation"},
			"second": {"id": str(rest[0]) if rest.size() > 0 else "",
				"via": "ranking" if rest.size() > 0 else "none"}}
	return {"last": {"id": str(ranked[0]) if ranked.size() > 0 else "",
			"via": "ranking" if ranked.size() > 0 else "none"},
		"second": {"id": str(ranked[1]) if ranked.size() > 1 else "",
			"via": "ranking" if ranked.size() > 1 else "none"}}


func evo_archive(brain_id: String, reason: String) -> Dictionary:
	# Blocking: local file move, milliseconds.
	return _run_cli(["archive", "--id", brain_id, "--reason", reason])


func size_options() -> Array:
	return [4, 8, 16]


func _strength(rec: Dictionary) -> Array:
	# Primary sort key is ELO (descending); win rates stay as tiebreaks.
	var r: Dictionary = rec.get("record", {})
	return [float(r.get("elo", 1200.0)),
		_match_rate(r), _battle_rate(r), rec.get("name", "")]


func _match_rate(r: Dictionary) -> float:
	var d := int(r.get("matches_won", 0)) + int(r.get("matches_lost", 0))
	return float(r.get("matches_won", 0)) / max(d, 1) if d > 0 else WIN_RATE_FALLBACK


func _battle_rate(r: Dictionary) -> float:
	var d := int(r.get("wins", 0)) + int(r.get("losses", 0))
	return float(r.get("wins", 0)) / max(d, 1) if d > 0 else WIN_RATE_FALLBACK


func build_bracket(player_ids: Array, size: int, best_of: int, lr_scale: float, round_time: float = 40.0, quick: bool = false, brains_override: Array = [], random_draw: bool = false, consolation: bool = false, fixed_order: bool = false) -> Dictionary:
	var all_brains: Array = list_brains_cached() if brains_override.is_empty() else brains_override
	var by_id := {}
	for b in all_brains:
		by_id[str(b.get("id", ""))] = b
	var players: Array = []
	for pid in player_ids:
		if by_id.has(str(pid)):
			players.append(by_id[str(pid)])
	if players.size() < 2:
		return {"ok": false, "error": "select at least 2 brains"}
	if players.size() > size:
		return {"ok": false, "error": "more brains than bracket slots"}
	# No wiring gate: the server runs each fighter on its native wiring
	# (base or experimental overlay), so any vault brains may share a
	# bracket. Vault files keep their native arity end-to-end.
	var seeded := seed_first_round(players, size, random_draw, fixed_order)
	players = seeded["players"]
	var matches: Array = seeded["matches"]
	var seeding := str(seeded["seeding"])
	var tid := _next_tournament_id()
	tourney = {
		"id": tid, "status": "running", "size": size, "best_of": best_of,
		"wins_needed": best_of / 2 + 1, "lr_scale": lr_scale,
		"round_time": round_time, "quick": quick, "seeding": seeding,
		"random_draw": random_draw,
		"consolation": consolation and not quick,
		"losers_start_round": -1, "last_place_id": "",
		"created": Time.get_datetime_string_from_system(),
		"players": players, "byes": [],
		"rounds": [matches], "current_round": 0, "current_match": 0,
		"champion_id": "",
	}
	sudden_death_armed = false
	save_state()
	return {"ok": true, "tournament_id": tid}


func _next_tournament_id() -> String:
	# Hex-second ids collide when two brackets start in the same second
	# (quick battle + tournament, back-to-back evo gens): identical ids
	# share a state file AND the server's battle dedup key, so the
	# second event's battles get answered from the first's verdicts and
	# are never banked. Suffix on collision; normal case keeps T+8hex.
	var base := int(Time.get_unix_time_from_system())
	var tid := "T%08X" % base
	var n := 0
	while FileAccess.file_exists(tournament_dir.path_join(tid + ".json")):
		n += 1
		tid = "T%08X-%d" % [base, n]
	return tid


func seed_first_round(player_dicts: Array, size: int, random_draw: bool, fixed_order: bool = false) -> Dictionary:
	# Canonical single-elim seeding shared by build_bracket (vault brains)
	# and preview_bracket (synthetic offspring welcome): place the
	# strongest first into the standard power-of-two seed order, so the
	# top seeds take the byes, the weakest meet earliest, and round 0
	# holds exactly size/2 slots (real matches, BYE cards for resting
	# seeds, VACANT cards for empty subtrees when under half full).
	# Random draw shuffles instead (byes fall luck-of-the-draw).
	# Fixed order (event finals) pairs consecutive entries untouched.
	# Returns {players, matches, seeding}. Player dicts need id/name
	# (record optional - missing ELO sorts as 1200).
	var players: Array = player_dicts.duplicate()
	if fixed_order:
		var fmatches: Array = []
		var i := 0
		while i + 1 < players.size():
			fmatches.append(_new_match(players[i], players[i + 1]))
			i += 2
		return {"players": players, "matches": fmatches, "seeding": "fixed"}
	var seeding := "strength"
	if random_draw:
		seeding = "random"
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for i in range(players.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp = players[i]
			players[i] = players[j]
			players[j] = tmp
	else:
		players.sort_custom(func(a, b):
			var sa := _strength(a)
			var sb := _strength(b)
			if sa[0] != sb[0]:
				return sa[0] > sb[0]
			if sa[1] != sb[1]:
				return sa[1] > sb[1]
			if sa[2] != sb[2]:
				return sa[2] > sb[2]
			return str(sa[3]) < str(sb[3]))
	var order := _seed_order(size)
	var leaves: Array = []
	leaves.resize(size)
	for i in range(size):
		var seed_num: int = order[i]
		leaves[i] = players[seed_num - 1] if seed_num <= players.size() else null
	var matches: Array = []
	for k in range(size / 2):
		matches.append(_new_match(leaves[2 * k], leaves[2 * k + 1]))
		var m: Dictionary = matches[k]
		if str(m.get("a_id", "")) != "" and str(m.get("b_id", "")) == "":
			m["winner_id"] = str(m.get("a_id", ""))
		elif str(m.get("a_id", "")) == "" and str(m.get("b_id", "")) != "":
			m["winner_id"] = str(m.get("b_id", ""))
	return {"players": players, "matches": matches, "seeding": seeding}


func preview_bracket(player_dicts: Array, size: int, random_draw: bool) -> Dictionary:
	# Display-only next-generation preview (never saved, never played):
	# round 0 seeded exactly like the real thing; the renderer pads the
	# rest as TBD. Unbred offspring ride synthetic {id,name} cards that
	# refresh to real names on adoption.
	if player_dicts.size() < 2 or player_dicts.size() > size:
		return {}
	var seeded := seed_first_round(player_dicts, size, random_draw)
	return {"players": seeded["players"], "rounds": [seeded["matches"]],
		"size": size, "current_round": 0, "current_match": 0,
		"status": "preview", "seeding": str(seeded["seeding"])}


func _new_match(a, b) -> Dictionary:
	return {
		"a_id": str(a.get("id", "")) if a != null else "",
		"a_name": str(a.get("name", "?")) if a != null else "",
		"b_id": str(b.get("id", "")) if b != null else "",
		"b_name": str(b.get("name", "?")) if b != null else "",
		"bye": (b == null and a != null), "vacant": (a == null and b == null),
		"wins_a": 0, "wins_b": 0, "draws": 0,
		"winner_id": "", "battles": 0,
		"ko_a": 0, "ko_b": 0,
	}


func _match_wins(pid: String) -> int:
	# Decided pairings taken in this event file (drawn splits count
	# for neither side): the sudden-death tiebreak currency.
	var n := 0
	for rnd in (tourney.get("rounds", []) as Array):
		for mm in (rnd as Array):
			if str((mm as Dictionary).get("winner_id", "")) == pid:
				n += 1
	return n


func _battle_wins(pid: String) -> int:
	# Total battle wins across every round (main + consolation): the
	# deterministic tiebreak for skipped losers finals.
	var n := 0
	for rnd in (tourney.get("rounds", []) as Array):
		for mm in (rnd as Array):
			var d := mm as Dictionary
			if str(d.get("a_id", "")) == pid:
				n += int(d.get("wins_a", 0))
			if str(d.get("b_id", "")) == pid:
				n += int(d.get("wins_b", 0))
	return n


func _resolve_skipped_final(fin: Dictionary) -> void:
	# Last-two archiving without fighting: fewer total battle wins is
	# last place (ties go to b, so a_id takes last). Marks the card
	# skipped for honest display; evo_bottom_two reads it like a played
	# final (loser = last, winner = second-last).
	var a := str(fin.get("a_id", ""))
	var b := str(fin.get("b_id", ""))
	var w := b
	if _battle_wins(a) > _battle_wins(b):
		w = a
	fin["winner_id"] = w
	fin["skipped"] = true
	tourney["last_place_id"] = b if w == a else a


func _match_loser(mm: Dictionary) -> String:
	# Loser of a decided match for loser-advance consolation rounds.
	# Bye walkovers have no loser (a walkover is not loss evidence);
	# undecided or vacant matches yield "" like missing winners do.
	var w := str(mm.get("winner_id", ""))
	if w == "" or bool(mm.get("bye", false)) or bool(mm.get("vacant", false)):
		return ""
	var a := str(mm.get("a_id", ""))
	var b := str(mm.get("b_id", ""))
	if w == a and b != "":
		return b
	if w == b and a != "":
		return a
	return ""


func _seed_order(size: int) -> Array:
	# Standard single-elim seed-to-bracket-slot order (1 = strongest).
	# Recursive: the half bracket's slots alternate with their high-seed
	# mirrors, e.g. size 8 => [1, 8, 4, 5, 2, 7, 3, 6].
	if size <= 2:
		return [1, 2]
	var half := _seed_order(size / 2)
	var out: Array = []
	for s in half:
		out.append(s)
		out.append(size + 1 - s)
	return out


func current_match() -> Dictionary:
	if not tournament_active():
		return {}
	var rounds: Array = tourney.get("rounds", [])
	var ri := int(tourney.get("current_round", 0))
	if ri < 0 or ri >= rounds.size():
		return {}
	var r: Array = rounds[ri]
	var mi := int(tourney.get("current_match", 0))
	if mi < 0 or mi >= r.size():
		return {}
	return r[mi]


# Walk past anything unplayable at the current position (resolved byes,
# plus legacy walkovers with an empty opponent slot) so the arena never
# tries to load an empty brain path and stalls. Builds rounds as needed.
# Returns an advance-style dict: "next_match" (a real fight is up),
# "tournament_end", or "idle"/"broken".
func skip_unplayable() -> Dictionary:
	while tournament_active():
		var rounds: Array = tourney.get("rounds", [])
		var ri := int(tourney.get("current_round", 0))
		if ri < 0 or ri >= rounds.size():
			return {"action": "broken"}
		var r: Array = rounds[ri]
		var mi := int(tourney.get("current_match", 0))
		if mi < 0 or mi > r.size():
			return {"action": "broken"}
		if mi == r.size():
			# Round exhausted: complete it (builds the next round or ends).
			var done := advance_after_match()
			if str(done.get("action", "")) != "next_match":
				return done
			continue
		var m: Dictionary = r[mi]
		if bool(m.get("vacant", false)):
			# Empty subtree: no players on either side, nothing to load.
			# It already has no winner; just walk past it.
			var adv0 := advance_after_match()
			if str(adv0.get("action", "")) != "next_match":
				return adv0
			continue
		var is_bye := bool(m.get("bye", false))
		var wid := str(m.get("winner_id", ""))
		if is_bye and wid == "" and str(m.get("b_id", "")) == "":
			# Walkover with no opponent recorded: a_id advances.
			m["winner_id"] = str(m.get("a_id", ""))
			wid = str(m.get("winner_id", ""))
			save_state()
		if is_bye and wid != "":
			var adv := advance_after_match()
			if str(adv.get("action", "")) != "next_match":
				return adv
			continue
		return {"action": "next_match"}
	return {"action": "idle"}


func brain_path(brain_id: String) -> String:
	# Cached roster: get_load_params shells this TWICE per battle load
	# (alpha + beta); an uncached shell here was ~1-2 s of loading each.
	for b in list_brains_cached():
		if str((b as Dictionary).get("id", "")) == brain_id:
			return brains_dir.path_join(str((b as Dictionary).get("filename", "")))
	return ""


func get_load_params() -> Dictionary:
	var m := current_match()
	# One roster pass for both fighters (cached; never two shells).
	var by_id := {}
	for b in list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	var alpha_fn := ""
	var beta_fn := ""
	for pid in [str(m.get("a_id", "")), str(m.get("b_id", ""))]:
		var rec: Dictionary = by_id.get(pid, {})
		if pid == str(m.get("a_id", "")):
			alpha_fn = str(rec.get("filename", ""))
		else:
			beta_fn = str(rec.get("filename", ""))
	return {
		"alpha_path": brains_dir.path_join(alpha_fn) if alpha_fn != "" else "",
		"beta_path": brains_dir.path_join(beta_fn) if beta_fn != "" else "",
		"tournament_id": str(tourney.get("id", "")),
		"match": "R%dM%d" % [int(tourney.get("current_round", 0)) + 1,
			int(tourney.get("current_match", 0)) + 1],
		"lr_scale": float(tourney.get("lr_scale", 0.5)),
		"a_name": str(m.get("a_name", "ALPHA")),
		"b_name": str(m.get("b_name", "BETA")),
		"score_a": int(m.get("wins_a", 0)),
		"score_b": int(m.get("wins_b", 0)),
	}


func on_battle_result(winner: String, flight_a: Dictionary = {}, flight_b: Dictionary = {}, brain_stream: Dictionary = {}, kills_a: int = -1, kills_b: int = -1) -> Dictionary:
	# winner: "alpha" | "beta" | "draw". Per-battle flight telemetry is
	# banked on the match ("flights" list) so flight-style regressions
	# have recorded evidence; the pool-rate stream rides along when the
	# menu record toggle is on (gated arena-side; ~50 KB per battle).
	# kills_a/b bank takedowns per side for group standings (negative =
	# unreported, e.g. legacy callers). Returns sequencing action.
	var m := current_match()
	if m.is_empty():
		return {"action": "idle"}
	m["battles"] = int(m.get("battles", 0)) + 1
	if kills_a >= 0:
		m["ko_a"] = int(m.get("ko_a", 0)) + kills_a
	if kills_b >= 0:
		m["ko_b"] = int(m.get("ko_b", 0)) + kills_b
	if not flight_a.is_empty() or not flight_b.is_empty():
		if not m.has("flights"):
			m["flights"] = []
		var entry := {
			"battle": int(m.get("battles", 0)), "winner": winner,
			"a": flight_a, "b": flight_b}
		if not brain_stream.is_empty() and int((brain_stream.get("alpha", []) as Array).size()) > 0:
			entry["stream"] = brain_stream
		(m["flights"] as Array).append(entry)
	if winner == "draw":
		m["draws"] = int(m.get("draws", 0)) + 1
		if int(m.get("draws", 0)) >= 3:
			# Third draw resolves the match outright (no infinite
			# rematches): higher start-of-match ELO advances, ties go
			# alpha like fitness verdicts. Both ELOs were already
			# docked when the draw was reported.
			sudden_death_armed = true
			var aid := str(m.get("a_id", ""))
			var bid := str(m.get("b_id", ""))
			# Prior match-wins decide (baseball merit, not rating): the
			# side that already proved itself takes the pairing. Tied
			# priors split the point in group play (drawn, 0.5 each);
			# finals stay decisive via the legacy ELO fallback so a
			# champion is always crowned.
			var wa := _match_wins(aid)
			var wb := _match_wins(bid)
			if wa != wb:
				var wslot := "alpha" if wa > wb else "beta"
				m["winner_id"] = str(m.get("a_id" if wslot == "alpha" else "b_id", ""))
				m["decided_by_draw"] = true
				save_state()
				return {"action": "match_over", "match_winner": wslot,
					"score_a": int(m.get("wins_a", 0)),
					"score_b": int(m.get("wins_b", 0)),
					"resolved_by_draw": true}
			if str(tourney.get("format", "bracket")) == "groups":
				m["drawn"] = true
				save_state()
				return {"action": "match_over", "match_winner": "draw",
					"score_a": int(m.get("wins_a", 0)),
					"score_b": int(m.get("wins_b", 0)),
					"resolved_by_draw": true}
			var ea := _player_elo(aid)
			var eb := _player_elo(bid)
			var dslot := "alpha" if ea >= eb else "beta"
			m["winner_id"] = str(m.get("a_id" if dslot == "alpha" else "b_id", ""))
			# Display honesty: the card shows battle score (e.g. 1-3),
			# so the tiebreak must be visible or the green winner
			# looks wrong. The renderer tags these DRAW-BREAK.
			m["decided_by_draw"] = true
			save_state()
			return {"action": "match_over", "match_winner": dslot,
				"score_a": int(m.get("wins_a", 0)),
				"score_b": int(m.get("wins_b", 0)),
				"resolved_by_draw": true}
		save_state()
		return {"action": "replay", "sudden_death": sudden_death_armed,
			"score_a": int(m.get("wins_a", 0)), "score_b": int(m.get("wins_b", 0))}
	sudden_death_armed = false
	if winner == "alpha":
		m["wins_a"] = int(m.get("wins_a", 0)) + 1
	else:
		m["wins_b"] = int(m.get("wins_b", 0)) + 1
	var need := int(tourney.get("wins_needed", 4))
	var score_a := int(m.get("wins_a", 0))
	var score_b := int(m.get("wins_b", 0))
	if score_a >= need or score_b >= need:
		var match_winner_slot := "alpha" if score_a >= need else "beta"
		m["winner_id"] = str(m.get("a_id" if score_a >= need else "b_id", ""))
		save_state()
		return {"action": "match_over", "match_winner": match_winner_slot,
			"score_a": score_a, "score_b": score_b}
	save_state()
	return {"action": "next_battle", "score_a": score_a, "score_b": score_b,
		"last_winner": winner}


func advance_after_match() -> Dictionary:
	# Move to next match (building next round when needed) or finish.
	var rounds: Array = tourney["rounds"]
	var r: Array = rounds[int(tourney["current_round"])]
	tourney["current_match"] = int(tourney["current_match"]) + 1
	if int(tourney["current_match"]) < r.size():
		# Skip resolved bye matches and vacant cards (no fighters to load).
		while int(tourney["current_match"]) < r.size():
			var nm: Dictionary = r[int(tourney["current_match"])]
			if (str(nm.get("winner_id", "")) != "" and bool(nm.get("bye", false))) \
					or bool(nm.get("vacant", false)):
				tourney["current_match"] = int(tourney["current_match"]) + 1
			else:
				break
		if int(tourney["current_match"]) < r.size():
			save_state()
			return {"action": "next_match"}
	# Group format: the round-robin schedule is precomputed, so rounds
	# just step forward (no winner-progression rebuild). Exhausting the
	# schedule completes the group; standings decide advancers.
	if str(tourney.get("format", "bracket")) == "groups":
		tourney["current_round"] = int(tourney["current_round"]) + 1
		tourney["current_match"] = 0
		if int(tourney["current_round"]) >= (tourney["rounds"] as Array).size():
			tourney["status"] = "complete"
			save_state()
			return {"action": "group_complete",
				"group": str(tourney.get("group", "?")),
				"event_id": str(tourney.get("event_id", "")),
				"standings": group_standings()}
		save_state()
		return {"action": "next_match"}
	# Round complete: build next from winners - or from losers inside
	# the consolation bracket (loser advances, converging down to last
	# place + second-last for the archives). Empty slots = vacant subtrees.
	var _losers_from := int(tourney.get("losers_start_round", -1))
	var _loser_mode := _losers_from >= 0 and int(tourney["current_round"]) >= _losers_from
	var winners: Array = []
	for mm in r:
		if _loser_mode:
			winners.append(_match_loser(mm))
		else:
			winners.append(str(mm.get("winner_id", "")))
	if winners.size() == 1:
		var losers_from := int(tourney.get("losers_start_round", -1))
		if losers_from < 0:
			# Main final decided: crown the champion, then maybe run
			# the losers bracket to find last place (loser advances;
			# the losers-final loser is last).
			tourney["champion_id"] = winners[0]
			if bool(tourney.get("consolation", false)):
				if _build_losers_bracket():
					var lr: Array = tourney["rounds"][int(tourney.get("losers_start_round", -1))]
					if lr.size() == 1:
						# Single-match consolation IS the final: both are
						# last-two, archive them without fighting it.
						_resolve_skipped_final(lr[0])
						tourney["status"] = "complete"
						save_state()
						return {"action": "tournament_end",
							"champion_id": str(tourney.get("champion_id", "")),
							"last_place_id": str(tourney.get("last_place_id", ""))}
					save_state()
					return {"action": "next_match",
						"consolation_started": true}
				print("[Director] Consolation skipped: need exactly 2/4/8 "
					+ "real round-0 losers.")
		else:
			# Losers final decided: its loser is last place (a loss in
			# every consolation round it fought). The main champion set
			# earlier stands; the final winner is second-last.
			var fin: Dictionary = r[0]
			var w := str(fin.get("winner_id", ""))
			tourney["last_place_id"] = str(fin.get(
				"b_id" if w == str(fin.get("a_id", "")) else "a_id", ""))
		tourney["status"] = "complete"
		save_state()
		return {"action": "tournament_end",
			"champion_id": str(tourney.get("champion_id", "")),
			"last_place_id": str(tourney.get("last_place_id", ""))}
	# Loser-advance converging to a 2-fighter final: both are last-two,
	# archive them without fighting it (needs two real advancers;
	# ghosts fall through to the normal bye/vacant machinery).
	if _loser_mode and winners.size() == 2 and str(winners[0]) != "" and str(winners[1]) != "":
		var names2 := {}
		for p in tourney.get("players", []):
			names2[str(p.get("id", ""))] = str(p.get("name", "?"))
		var fin2 := _new_match(
			{"id": winners[0], "name": str(names2.get(winners[0], "?"))},
			{"id": winners[1], "name": str(names2.get(winners[1], "?"))})
		rounds.append([fin2])
		_resolve_skipped_final(fin2)
		tourney["status"] = "complete"
		save_state()
		return {"action": "tournament_end",
			"champion_id": str(tourney.get("champion_id", "")),
			"last_place_id": str(tourney.get("last_place_id", ""))}
	var names := {}
	for p in tourney.get("players", []):
		names[str(p.get("id", ""))] = str(p.get("name", "?"))
	var next_round: Array = []
	for i in range(0, winners.size(), 2):
		var wa: String = winners[i]
		var wb: String = winners[i + 1] if i + 1 < winners.size() else ""
		if wa == "" and wb == "":
			next_round.append(_new_match(null, null))
		elif wb == "":
			var nm1 := _new_match({"id": wa, "name": str(names.get(wa, "?"))}, null)
			nm1["winner_id"] = wa
			next_round.append(nm1)
		else:
			next_round.append(_new_match(
				{"id": wa, "name": str(names.get(wa, "?"))},
				{"id": wb, "name": str(names.get(wb, "?"))}))
	rounds.append(next_round)
	tourney["current_round"] = int(tourney["current_round"]) + 1
	tourney["current_match"] = 0
	# Skip leading byes and vacant cards (odd winner counts / empty subtrees).
	while int(tourney["current_match"]) < next_round.size():
		var nm2: Dictionary = next_round[int(tourney["current_match"])]
		if (str(nm2.get("winner_id", "")) != "" and bool(nm2.get("bye", false))) \
				or bool(nm2.get("vacant", false)):
			tourney["current_match"] = int(tourney["current_match"]) + 1
		else:
			break
	save_state()
	return {"action": "next_match"}


func _build_losers_bracket() -> bool:
	# Collects real round-0 losers (played matches only: no byes, no
	# vacant cards, decided winner) and appends their mini-bracket as
	# new rounds. Only exact powers 2/4/8 (else the evidence distorts).
	# Returns true when a losers bracket starts.
	var names := {}
	for p in tourney.get("players", []):
		names[str(p.get("id", ""))] = str(p.get("name", "?"))
	var losers: Array = []
	var r0: Array = tourney["rounds"][0]
	for m in r0:
		if not (m is Dictionary):
			continue
		if bool(m.get("bye", false)) or bool(m.get("vacant", false)):
			continue
		var a := str(m.get("a_id", ""))
		var b := str(m.get("b_id", ""))
		var w := str(m.get("winner_id", ""))
		if a == "" or b == "" or w == "":
			continue
		losers.append(b if w == a else a)
	if not (losers.size() == 2 or losers.size() == 4 or losers.size() == 8):
		return false
	var first: Array = []
	for k in range(0, losers.size(), 2):
		first.append(_new_match(
			{"id": losers[k], "name": str(names.get(losers[k], "?"))},
			{"id": losers[k + 1], "name": str(names.get(losers[k + 1], "?"))}))
	var rounds: Array = tourney["rounds"]
	tourney["losers_start_round"] = rounds.size()
	rounds.append(first)
	tourney["current_round"] = rounds.size() - 1
	tourney["current_match"] = 0
	return true


func last_place_name() -> String:
	var lid := str(tourney.get("last_place_id", ""))
	for p in tourney.get("players", []):
		if str(p.get("id", "")) == lid:
			return str(p.get("name", "?"))
	return "?"


func champion_name() -> String:
	var cid := str(tourney.get("champion_id", ""))
	for p in tourney.get("players", []):
		if str(p.get("id", "")) == cid:
			return str(p.get("name", "?"))
	return "?"


# Crossable wirings mirrored from experimental_wiring.FROZEN_GENOMES
# (genome parents always qualify; these legacy mixes expand to rules).
const CROSSABLE_MIXES := ["lplc2_contra_dn", "retina_wide", "spear_lunge"]


func is_genome_bearing(pid: String) -> bool:
	# True when a roster brain can parent a crossover (genome or single
	# frozen mix). Base/legacy/multi-mix brains would fail breeding and
	# abort the generation, so the evo loop must never pick them.
	for p in tourney.get("players", []):
		if not (p is Dictionary):
			continue
		var pd := p as Dictionary
		if str(pd.get("id", "")) != pid:
			continue
		var gp = pd.get("generator_params", {})
		if not (gp is Dictionary):
			return false
		if (gp as Dictionary).get("genome", null) != null:
			return true
		var exp = (gp as Dictionary).get("experiment", null)
		if exp is String and str(exp) in CROSSABLE_MIXES:
			return true
		if exp is Array and exp.size() == 1 \
				and str(exp[0]) in CROSSABLE_MIXES:
			return true
		return false
	return false


func kin_base_name(champ_name: String) -> String:
	# Pedigree base for clone specs: strip one leading G<N>- prefix,
	# one trailing -kin[N]/-jr[N] suffix, and one trailing old wild
	# " G<N>"/"_G<N>" tag. The worker appends -kin/-jr with the
	# lineage counters at banking (counters are never parsed); the
	# spec carries the base only. Unparseable names fall back to the
	# full original.
	var base := champ_name.strip_edges()
	var gpos := base.find("-")
	if gpos > 1 and base.substr(0, 1) == "G" \
			and base.substr(1, gpos - 1).is_valid_int():
		base = base.substr(gpos + 1)
	for tag in ["-kin", "-jr"]:
		var kpos := base.rfind(tag)
		if kpos >= 0:
			var tail := base.substr(kpos + 4)
			if tail == "" or tail.is_valid_int():
				base = base.substr(0, kpos)
				break
	for sep in [" G", "_G"]:
		var gp := base.rfind(sep)
		if gp >= 0 and base.substr(gp + 2).is_valid_int():
			base = base.substr(0, gp)
			break
	if base == "":
		base = champ_name.strip_edges()
	return base


func _player_elo(pid: String) -> float:
	# Start-of-tournament ELO for bracket seeding tiebreaks and 3rd-draw
	# resolution (players array is snapshotted at bracket build).
	for p in tourney.get("players", []):
		if str((p as Dictionary).get("id", "")) == pid:
			return float(((p as Dictionary).get("record", {}) as Dictionary).get("elo", 1200.0))
	return 1200.0


func match_slot_name(slot: String) -> String:
	var m := current_match()
	return str(m.get("a_name" if slot == "alpha" else "b_name", slot.to_upper()))


func _fmt_wins(v) -> String:
	# Fractional match wins (0.5 splits) print trimmed ("2.5"), ints
	# stay ints ("3").
	var f := float(v)
	return "%d" % int(f) if absf(f - float(int(f))) < 0.01 else "%.1f" % f


func bracket_text() -> String:
	if tourney.is_empty():
		return "No tournament."
	var lines: Array = []
	var kind := "QUICK BATTLE" if bool(tourney.get("quick", false)) else "Tournament"
	lines.append("%s %s  best-of-%d  (first to %d)" % [kind,
		str(tourney.get("id", "")), int(tourney.get("best_of", 7)),
		int(tourney.get("wins_needed", 4))])
	var rounds: Array = tourney.get("rounds", [])
	var _lf := int(tourney.get("losers_start_round", -1))
	for ri in range(rounds.size()):
		var label := "Final" if ri == rounds.size() - 1 and rounds.size() > 1 else ("Round %d" % (ri + 1))
		if _lf >= 0 and ri >= _lf:
			label = "Losers final" if ri == rounds.size() - 1 else ("Losers R%d" % (ri - _lf + 1))
		lines.append("== %s ==" % label)
		var _la := _lf >= 0 and ri >= _lf
		for mi in range(rounds[ri].size()):
			var mm: Dictionary = rounds[ri][mi]
			var marker := ""
			if ri == int(tourney.get("current_round", 0)) and mi == int(tourney.get("current_match", 0)) and tournament_active():
				marker = "  <-- LIVE"
			if bool(mm.get("bye", false)):
				lines.append("  %s advances (bye)%s" % [str(mm.get("a_name", "?")), marker])
			else:
				var w := ""
				if bool(mm.get("drawn", false)):
					w = "  => DRAW SPLIT"
				elif str(mm.get("winner_id", "")) != "":
					if _la:
						var ln := str(mm.get("b_name", "?")) if str(mm.get("winner_id", "")) == str(mm.get("a_id", "")) else str(mm.get("a_name", "?"))
						w = "  => %s (loser advances)" % ln
					else:
						var wn := str(mm.get("a_name", "?")) if str(mm.get("winner_id", "")) == str(mm.get("a_id", "")) else str(mm.get("b_name", "?"))
						w = "  => %s" % wn
				lines.append("  %s %s - %s %s%s%s" % [str(mm.get("a_name", "?")),
					_fmt_wins(mm.get("wins_a", 0)), _fmt_wins(mm.get("wins_b", 0)),
					str(mm.get("b_name", "?")), w, marker])
	if str(tourney.get("status", "")) == "complete":
		lines.append("CHAMPION: %s" % champion_name())
		if str(tourney.get("last_place_id", "")) != "":
			lines.append("LAST PLACE: %s" % last_place_name())
	return "\n".join(lines)


func state_path() -> String:
	return tournament_dir.path_join("%s.json" % str(tourney.get("id", "draft")))


func save_state() -> void:
	if tourney.is_empty():
		return
	var f := FileAccess.open(state_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(tourney, "\t"))
		f.close()


func load_state_file(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("rounds"):
		tourney = parsed
		sudden_death_armed = false
		return true
	return false


func quit_to_menu() -> void:
	arena = null
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


# ── Group-stage events (evolution size-16) ──────────────────────────
# One event = 4 round-robin group files (A-D) + 1 single-elim final,
# chained by an event manifest (tournaments/E<id>.json). Bracket files
# stay ordinary tournaments, so the battle loop, banking, review and
# resume paths are untouched; only scheduling (fixed RR order, no
# winner-progression rebuild) and advancement (standings) differ.


func event_path(event_id: String) -> String:
	return tournament_dir.path_join(str(event_id) + ".json")


func event_load(event_id: String) -> Dictionary:
	var f := FileAccess.open(event_path(event_id), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func event_load_cached(event_id: String) -> Dictionary:
	# Mtime-gated manifest read for tick paths: serves memory when the
	# file is unchanged (writers write through below). Falls back to a
	# fresh parse on any change or miss.
	if event_id != "" and event_cache.get("id", "") == event_id:
		var mtime := FileAccess.get_modified_time(event_path(event_id))
		if mtime > 0 and mtime == event_cache_mtime:
			return event_cache
	var ev := event_load(event_id)
	if not ev.is_empty():
		event_cache = ev
		event_cache_mtime = FileAccess.get_modified_time(event_path(event_id))
	return ev


func event_save(ev: Dictionary) -> bool:
	var f := FileAccess.open(event_path(str(ev.get("id", ""))), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(ev, "\t"))
	f.close()
	event_cache = ev
	event_cache_mtime = FileAccess.get_modified_time(event_path(str(ev.get("id", ""))))
	return true


func _snake_sort(player_dicts: Array) -> Array:
	# ELO desc, deterministic (strength, then name): the snake draft
	# input, so groups balance star power evenly.
	var out: Array = player_dicts.duplicate()
	out.sort_custom(func(a, b):
		var sa := _strength(a)
		var sb := _strength(b)
		if sa[0] != sb[0]:
			return sa[0] > sb[0]
		if sa[1] != sb[1]:
			return sa[1] > sb[1]
		if sa[2] != sb[2]:
			return sa[2] > sb[2]
		return str(sa[3]) < str(sb[3]))
	return out


func event_begin(player_ids: Array, settings: Dictionary, generation: int, brains_override: Array = []) -> Dictionary:
	# Snake-drafts exactly 16 brains into groups A-D (ranks
	# 1,8,9,16 / 2,7,10,15 / 3,6,11,14 / 4,5,12,13) and writes the
	# event manifest. Returns {ok, event_id, groups}.
	var all_brains: Array = brains_override if not brains_override.is_empty() else list_brains_cached()
	var by_id := {}
	for b in all_brains:
		by_id[str((b as Dictionary).get("id", ""))] = b
	var players: Array = []
	for pid in player_ids:
		if by_id.has(str(pid)):
			players.append(by_id[str(pid)])
	if players.size() != 16:
		return {"ok": false, "error": "group events need exactly 16 brains"}
	players = _snake_sort(players)
	var snake := [[0, 7, 8, 15], [1, 6, 9, 14], [2, 5, 10, 13], [3, 4, 11, 12]]
	var letters := ["A", "B", "C", "D"]
	var eid := "E" + _next_tournament_id().trim_prefix("T")
	var en := 0
	while FileAccess.file_exists(event_path(eid)):
		en += 1
		eid = "E" + _next_tournament_id().trim_prefix("T") + "-%d" % en
	var groups := {}
	for gi in range(4):
		var gp: Array = []
		for idx in snake[gi]:
			gp.append(str(((players[idx]) as Dictionary).get("id", "")))
		groups[letters[gi]] = {"players": gp, "bracket_id": "",
			"standings": [], "done": false}
	var ev := {"id": eid, "status": "running", "generation": generation,
		"settings": settings, "groups": groups,
		"group_order": letters, "final_id": "", "champion_id": "",
		"pool": [], "phase": "groups_A",
		"created": Time.get_datetime_string_from_system()}
	if not event_save(ev):
		return {"ok": false, "error": "cannot write event file"}
	return {"ok": true, "event_id": eid, "groups": groups}


func build_group_bracket(group_dicts: Array, group_letter: String, event_id: String, best_of: int, lr_scale: float, round_time: float = 40.0) -> Dictionary:
	# One 4-fighter round-robin file: canonical circle-method schedule
	# (every pairing meets exactly once: 03/12, 02/31, 01/23).
	if group_dicts.size() != 4:
		return {"ok": false, "error": "groups need 4 brains"}
	var sched := [[0, 3], [1, 2], [0, 2], [3, 1], [0, 1], [2, 3]]
	var rounds: Array = []
	for r in range(3):
		var row: Array = []
		for k in range(2):
			var pair: Array = sched[r * 2 + k]
			row.append(_new_match(group_dicts[pair[0]], group_dicts[pair[1]]))
		rounds.append(row)
	var tid := _next_tournament_id()
	tourney = {"id": tid, "status": "running", "format": "groups",
		"group": group_letter, "event_id": event_id, "phase": "groups_" + group_letter,
		"size": 4, "best_of": best_of, "wins_needed": best_of / 2 + 1,
		"lr_scale": lr_scale, "round_time": round_time, "quick": false,
		"seeding": "snake", "random_draw": false, "consolation": false,
		"losers_start_round": -1, "last_place_id": "",
		"created": Time.get_datetime_string_from_system(),
		"players": group_dicts, "byes": [],
		"rounds": rounds, "current_round": 0, "current_match": 0,
		"champion_id": ""}
	sudden_death_armed = false
	save_state()
	return {"ok": true, "tournament_id": tid}


func group_standings(t: Dictionary = {}) -> Array:
	# [{id, name, wins, kos, matches, elo, dnf}] sorted wins desc, KO
	# scored desc, snapshot ELO desc. Undecided matches don't count.
	# dnf = timeout-tie battles fought (both sides of every drawn
	# battle implicate); feeds the booster rule. Defaults to the
	# loaded tourney; pass any bracket dict for overviews.
	var src: Dictionary = t if not t.is_empty() else tourney
	var table := {}
	for p in src.get("players", []):
		var pd := p as Dictionary
		var pid := str(pd.get("id", ""))
		if pid != "":
			table[pid] = {"id": pid, "name": str(pd.get("name", "?")),
				"wins": 0, "kos": 0, "matches": 0, "dnf": 0,
				"elo": float((pd.get("record", {}) as Dictionary).get("elo", 1200.0))}
	for rnd in (src.get("rounds", []) as Array):
		for mm in (rnd as Array):
			var m := mm as Dictionary
			var wid := str(m.get("winner_id", ""))
			var split := wid == "" and bool(m.get("drawn", false))
			if wid == "" and not split:
				continue
			for slot in ["a", "b"]:
				var sid := str(m.get(slot + "_id", ""))
				if table.has(sid):
					var row: Dictionary = table[sid]
					row["matches"] = int(row.get("matches", 0)) + 1
					row["kos"] = int(row.get("kos", 0)) + int(m.get("ko_" + slot, 0))
					row["dnf"] = int(row.get("dnf", 0)) + int(m.get("draws", 0))
					if split:
						row["wins"] = float(row.get("wins", 0)) + 0.5
			if table.has(wid):
				var wrow: Dictionary = table[wid]
				wrow["wins"] = float(wrow.get("wins", 0)) + 1.0
	var out: Array = table.values()
	out.sort_custom(func(x, y):
		if float(x["wins"]) != float(y["wins"]):
			return float(x["wins"]) > float(y["wins"])
		if int(x["kos"]) != int(y["kos"]):
			return int(x["kos"]) > int(y["kos"])
		return float(x["elo"]) > float(y["elo"]))
	return out


func event_note_bracket(event_id: String, group_letter: String, bracket_id: String) -> void:
	# Stamp the file id at BUILD time (completion records standings
	# later): the overview can already match the live file mid-group.
	var ev := event_load(event_id)
	if ev.is_empty():
		return
	var groups: Dictionary = ev.get("groups", {})
	if groups.has(group_letter):
		(groups[group_letter] as Dictionary)["bracket_id"] = bracket_id
		event_save(ev)


func event_booster_set() -> Array:
	# Booster rule (pure over the loaded group bracket file — call with
	# the completed group file loaded, same contract as
	# event_record_group): a fly qualifies iff it played >=1 match
	# (bye/vacant/undecided excluded by the canonical predicate) AND
	# every played match has draws >= 1 — a timeout-tie in each outing,
	# both sides implicated per drawn battle. Winners included: the
	# rule is mechanical, extra school never hurts. Returns [ids].
	var out: Array = []
	var played := {}
	var all_dnf := {}
	for rnd in (tourney.get("rounds", []) as Array):
		for mm in (rnd as Array):
			var m := mm as Dictionary
			var wid := str(m.get("winner_id", ""))
			var split := wid == "" and bool(m.get("drawn", false))
			if wid == "" and not split:
				continue
			var draws := int(m.get("draws", 0))
			for slot in ["a", "b"]:
				var sid := str(m.get(slot + "_id", ""))
				if sid == "":
					continue
				played[sid] = true
				if draws < 1:
					all_dnf[sid] = false
				elif not all_dnf.has(sid):
					all_dnf[sid] = true
	for pid in played.keys():
		if bool(all_dnf.get(pid, false)):
			out.append(str(pid))
	return out


func event_booster_queue(event_id: String) -> Dictionary:
	# Post-event booster schooling: every marked brain gets +50 eps
	# with the school curriculum (own stored wiring/rates — same
	# whitelist as the top-up trainer). Skips ghosts (left the vault)
	# and ids already queued/active (enqueue appends blindly). Called
	# BEFORE elimination (the archived leave the vault). One pump at
	# the end; hold_spawns keeps boots out of fights. Winners and
	# eliminated alike: the rule is mechanical. Returns {ok, queued}.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var queued: Array = []
	var by_id := {}
	for b in list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	for pid in (ev.get("booster", []) as Array):
		var s := str(pid)
		if not by_id.has(s):
			continue
		var busy := str(active_job.get("brain_id", "")) == s
		if not busy:
			for item in train_queue:
				if str((item as Dictionary).get("id", "")) == s:
					busy = true
					break
		if busy:
			continue
		var bd: Dictionary = by_id[s]
		var gp: Dictionary = (bd as Dictionary).get("generator_params", {})
		var params := {}
		for k in ["variant", "seed", "learning_rate", "dist_gain",
				"evasion", "align_bonus", "experiment", "genome",
				"genome_id", "mapping", "yaw_bias"]:
			if gp.has(k):
				params[k] = gp[k]
		params["curriculum"] = {}
		params["booster"] = {"event": event_id}
		enqueue_training(s, str(bd.get("name", "?")) + " [BOOSTER]",
			50, params)
		queued.append(s)
	pump_train_queue()
	return {"ok": true, "queued": queued}


func event_record_group(event_id: String, group_letter: String) -> Dictionary:
	# Call with the completed group file loaded: banks its standings
	# into the manifest and stamps the bracket id. Also banks the
	# booster set (per-group list + accumulated top-level list, deduped)
	# for post-event +50 booster schooling.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var groups: Dictionary = ev.get("groups", {})
	if not groups.has(group_letter):
		return {"ok": false, "error": "no such group"}
	var st := group_standings()
	var boosters := event_booster_set()
	var g: Dictionary = groups[group_letter]
	g["standings"] = st
	g["done"] = true
	g["bracket_id"] = str(tourney.get("id", ""))
	g["booster"] = boosters
	var accum: Array = ev.get("booster", [])
	for pid in boosters:
		if not (pid in accum):
			accum.append(pid)
	ev["booster"] = accum
	if not event_save(ev):
		return {"ok": false, "error": "cannot save event"}
	return {"ok": true, "standings": st, "booster": boosters}


func build_final_bracket(advancer_ids: Array, event_id: String, best_of: int, lr_scale: float, round_time: float = 40.0, brains_override: Array = []) -> Dictionary:
	# 8 advancers in fixed QF order (A1vB2, C1vD2, B1vA2, D1vC2):
	# consecutive pairing, no re-seeding. Standard single elim, no
	# consolation (elimination runs on the ELO rule instead).
	if advancer_ids.size() != 8:
		return {"ok": false, "error": "finals need 8 advancers"}
	var res := build_bracket(advancer_ids, 8, best_of, lr_scale,
		round_time, false, brains_override, false, false, true)
	if not bool(res.get("ok", false)):
		return res
	tourney["event_id"] = event_id
	tourney["phase"] = "final"
	save_state()
	return res


func event_advancers(event_id: String) -> Dictionary:
	# Top 2 per group in QF order from recorded standings.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var order: Array = []
	for g in ["A", "C", "B", "D"]:
		var st: Array = ((ev.get("groups", {}) as Dictionary).get(g, {}) as Dictionary).get("standings", [])
		if st.size() < 2:
			return {"ok": false, "error": "group %s unfinished" % g}
		order.append(str((st[0] as Dictionary).get("id", "")))
		order.append(str((st[1] as Dictionary).get("id", "")))
	# order is A1,A2,C1,C2,B1,B2,D1,D2 -> interleave to
	# A1vB2, C1vD2, B1vA2, D1vC2.
	var qf := [order[0], order[5], order[2], order[7],
		order[4], order[1], order[6], order[3]]
	return {"ok": true, "advancers": qf}


func event_eliminate_candidates(event_id: String, min_matches: int = 10, elo_cutoff: float = 0.0, live_override: Dictionary = {}) -> Dictionary:
	# Worst-first elimination order: event participants with CAREER
	# matches >= min_matches (vault record, not this event's files —
	# a whole event only plays ~6) and live ELO below the cutoff,
	# lowest ELO first. Green brains (< min_matches career) are never
	# demoted no matter how low their ELO. Fewer than 2 qualifiers is
	# a loud failure, never a silent widening: the loop must not eat
	# the unproven. Pure (no archiving) so the rule is unit-testable;
	# event_eliminate archives the bottom two.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var bids: Array = []
	for g in (ev.get("group_order", []) as Array):
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(str(g), {})
		if str(gd.get("bracket_id", "")) != "":
			bids.append(str(gd.get("bracket_id", "")))
	if str(ev.get("final_id", "")) != "":
		bids.append(str(ev.get("final_id", "")))
	var played := {}
	for bid in bids:
		var f := FileAccess.open(tournament_dir.path_join(bid + ".json"), FileAccess.READ)
		if f == null:
			continue
		var t = JSON.parse_string(f.get_as_text())
		f.close()
		if not (t is Dictionary):
			continue
		for rnd in ((t as Dictionary).get("rounds", []) as Array):
			for mm in (rnd as Array):
				var m := mm as Dictionary
				if str(m.get("winner_id", "")) == "" \
						and not bool(m.get("drawn", false)):
					continue
				for slot in ["a", "b"]:
					var sid := str(m.get(slot + "_id", ""))
					if sid != "":
						played[sid] = int(played.get(sid, 0)) + 1
	var cards := _event_live_cards(live_override)
	var experienced: Array = []
	for pid in played.keys():
		if not cards.has(pid):
			continue
		# Career gate (vault record matches): green brains stay out
		# of the axe regardless of ELO.
		if int((cards[pid] as Dictionary).get("matches", 0)) >= min_matches:
			experienced.append(pid)
	experienced.sort_custom(func(x, y): return float((cards[x] as Dictionary).get("elo", 0.0)) < float((cards[y] as Dictionary).get("elo", 0.0)))
	if elo_cutoff > 0.0:
		var cut: Array = []
		for pid in experienced:
			if float((cards[pid] as Dictionary).get("elo", 0.0)) < elo_cutoff:
				cut.append(pid)
		if cut.size() >= 2:
			return {"ok": true, "candidates": cut}
	return {"ok": true, "candidates": experienced}


func event_eliminate(event_id: String, min_matches: int = 10, elo_cutoff: float = 0.0) -> Dictionary:
	# Archives the bottom two candidates with the reason stamped.
	var cands := event_eliminate_candidates(event_id, min_matches, elo_cutoff)
	if not bool(cands.get("ok", false)):
		return cands
	var order: Array = cands.get("candidates", [])
	if order.size() < 2:
		return {"ok": false, "error": "fewer than 2 eligible brains"}
	var live := {}
	for b in list_brains_cached():
		var bd := b as Dictionary
		live[str(bd.get("id", ""))] = float((bd.get("record", {}) as Dictionary).get("elo", 1200.0))
	var out: Array = [order[0], order[1]]
	for pid in out:
		var ar := evo_archive(pid, "event %s elimination (ELO %.0f)" % [event_id, float(live.get(pid, 1200.0))])
		if not bool(ar.get("ok", false)):
			return {"ok": false, "error": str(ar.get("error", "?"))}
	return {"ok": true, "eliminated": out}


func _event_live_elo(live_override: Dictionary = {}) -> Dictionary:
	# Plain {id: elo} view (override values may be floats or full
	# cards - normalized here so trim/sort math never sees a dict).
	var cards := _event_live_cards(live_override)
	var out := {}
	for pid in cards.keys():
		out[pid] = float((cards[pid] as Dictionary).get("elo", 0.0))
	return out


func _event_live_card(bd: Dictionary) -> Dictionary:
	# Full live card for pool/elimination math: rating, schooling and
	# ring experience in one place.
	var r: Dictionary = bd.get("record", {})
	var t: Dictionary = bd.get("training", {})
	return {"elo": float(r.get("elo", 1200.0)),
		"train": int(t.get("episodes", 0)),
		"matches": int(r.get("matches", 0))}


func _event_live_cards(live_override: Dictionary = {}) -> Dictionary:
	var cards := {}
	if not live_override.is_empty():
		for pid in live_override.keys():
			var v = live_override[pid]
			if v is Dictionary:
				cards[str(pid)] = v
			else:
				cards[str(pid)] = {"elo": float(v), "train": 0, "matches": 0}
		return cards
	# Cached roster: this feeds the 5 s watcher tick mid-battle (pool
	# maintain/drain); an uncached shell here froze the fight ~1-2 s
	# every tick. Pool math tolerates 60 s staleness.
	for b in list_brains_cached():
		var bd := b as Dictionary
		cards[str(bd.get("id", ""))] = _event_live_card(bd)
	return cards


func event_pool_add(event_id: String, ids: Array, live_override: Dictionary = {}) -> Dictionary:
	# Bench bred offspring (cap 4, lowest live ELO trimmed first).
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var pool: Array = ev.get("pool", [])
	for pid in ids:
		var s := str(pid)
		if s != "" and not (s in pool):
			pool.append(s)
	while pool.size() > 4:
		var live := _event_live_elo(live_override)
		pool.sort_custom(func(x, y): return float(live.get(x, 0.0)) < float(live.get(y, 0.0)))
		pool.remove_at(0)
	ev["pool"] = pool
	if not event_save(ev):
		return {"ok": false, "error": "cannot save event"}
	return {"ok": true, "pool": pool}


func event_pool_qualified(event_id: String, min_train: int = 50, elo_floor: float = 0.0, live_override: Dictionary = {}) -> Dictionary:
	# Bench brains ready for the ring: schooled to min_train episodes
	# with live ELO at/above the floor (floor <= 0 disables). Pure
	# readout for handoff/maintain checks; the draw consumes.
	# Cached manifest (mtime-gated): this feeds the 5 s tick mid-battle.
	var ev := event_load_cached(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var cards := _event_live_cards(live_override)
	var qualified: Array = []
	for pid in (ev.get("pool", []) as Array):
		var s := str(pid)
		if not cards.has(s):
			continue
		var card: Dictionary = cards[s]
		if int(card.get("train", 0)) >= min_train \
				and float(card.get("elo", 0.0)) >= elo_floor:
			qualified.append(s)
	return {"ok": true, "qualified": qualified}


func event_draw_candidates(event_id: String, min_train: int = 50, elo_floor: float = 0.0, live_override: Dictionary = {}, brains_override: Array = []) -> Dictionary:
	# Promotion pool: the ENTIRE vault, not the bench — every schooled
	# brain (train >= min_train, ELO >= floor) outside the current
	# event's players. Archived brains are absent from the vault, so
	# they can never draw. Current-event players are excluded (they
	# advance or eliminate on their own path; survivors re-enter via
	# the roster, never the draw). Pure readout; the draw consumes.
	var ev := event_load_cached(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var participants := {}
	for g in (ev.get("group_order", []) as Array):
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(str(g), {})
		for pid in (gd.get("players", []) as Array):
			participants[str(pid)] = true
	var roster: Array = brains_override if not brains_override.is_empty() else list_brains_cached()
	var cards := _event_live_cards(live_override)
	var qualified: Array = []
	for b in roster:
		var pid := str((b as Dictionary).get("id", ""))
		if pid == "" or participants.has(pid) or not cards.has(pid):
			continue
		var card: Dictionary = cards[pid]
		if int(card.get("train", 0)) >= min_train \
				and float(card.get("elo", 0.0)) >= elo_floor:
			qualified.append(pid)
	return {"ok": true, "qualified": qualified}


func event_draw_pool(event_id: String, n: int, min_train: int = 50, elo_floor: float = 0.0, live_override: Dictionary = {}, brains_override: Array = []) -> Dictionary:
	# Random draw weighted toward the least-experienced qualifiers
	# (weight 1/(1+matches)): every schooled vault brain cycles into
	# the ring over time instead of the top-ELO pair hogging every
	# event. Drawn ids leave the bench pool when present there.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var q := event_draw_candidates(event_id, min_train, elo_floor,
		live_override, brains_override)
	if not bool(q.get("ok", false)):
		return q
	var qualified: Array = q.get("qualified", [])
	if qualified.size() < n:
		return {"ok": false, "error": "pool short (%d/%d qualified)" % [qualified.size(), n]}
	var cards := _event_live_cards(live_override)
	var drawn: Array = []
	var bag: Array = qualified.duplicate()
	for _i in range(n):
		var total := 0.0
		for pid in bag:
			total += 1.0 / (1.0 + float((cards[pid] as Dictionary).get("matches", 0)))
		var roll := randf() * total
		var pick := str(bag[bag.size() - 1])
		for pid in bag:
			roll -= 1.0 / (1.0 + float((cards[pid] as Dictionary).get("matches", 0)))
			if roll <= 0.0:
				pick = str(pid)
				break
		drawn.append(pick)
		bag.erase(pick)
	var pool: Array = ev.get("pool", [])
	for pid in drawn:
		pool.erase(str(pid))
	ev["pool"] = pool
	if not event_save(ev):
		return {"ok": false, "error": "cannot save event"}
	return {"ok": true, "drawn": drawn, "pool": ev["pool"]}


func event_overview_data(event_id: String) -> Dictionary:
	# 2x2 overview assembly: per group {letter, players, rounds,
	# standings, is_current, is_done, bracket_id}. Sibling files load
	# read-only; the loaded tourney (when it belongs to this event)
	# supplies the live table. Display-only, never written back.
	var ev := event_load(event_id)
	if ev.is_empty():
		return {}
	var live_id := str(tourney.get("id", ""))
	var live_event := str(tourney.get("event_id", ""))
	var out: Array = []
	for g in (ev.get("group_order", []) as Array):
		var letter := str(g)
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(letter, {})
		var bid := str(gd.get("bracket_id", ""))
		var is_current := bid != "" and bid == live_id and live_event == event_id
		var cell := {"letter": letter, "players": [], "rounds": [],
			"standings": [], "is_current": is_current,
			"is_done": bool(gd.get("done", false)), "bracket_id": bid,
			"cur_round": -1, "cur_match": -1}
		if is_current:
			cell["players"] = tourney.get("players", [])
			cell["rounds"] = tourney.get("rounds", [])
			cell["standings"] = group_standings()
			cell["cur_round"] = int(tourney.get("current_round", 0))
			cell["cur_match"] = int(tourney.get("current_match", 0))
		elif bid != "":
			var f := FileAccess.open(tournament_dir.path_join(bid + ".json"), FileAccess.READ)
			if f != null:
				var t = JSON.parse_string(f.get_as_text())
				f.close()
				if t is Dictionary:
					cell["players"] = (t as Dictionary).get("players", [])
					cell["rounds"] = (t as Dictionary).get("rounds", [])
					cell["standings"] = group_standings(t)
		if (cell["players"] as Array).is_empty():
			# Upcoming group (no file yet): resolve manifest ids to
			# cards for the preview table.
			var by_id := {}
			for b in list_brains_cached():
				by_id[str((b as Dictionary).get("id", ""))] = b
			var cards: Array = []
			var gd2: Dictionary = (ev.get("groups", {}) as Dictionary).get(letter, {})
			for pid in (gd2.get("players", []) as Array):
				if by_id.has(str(pid)):
					cards.append(by_id[str(pid)])
			cell["players"] = cards
		if (cell["standings"] as Array).is_empty():
			cell["standings"] = group_standings({"players": cell["players"], "rounds": []})
		out.append(cell)
	return {"groups": out,
		"current": str(tourney.get("group", "")) if live_event == event_id and str(tourney.get("format", "")) == "groups" else ""}


func event_topup_pick(event_id: String, target: int = 50, live_override: Dictionary = {}) -> Dictionary:
	# Least-trained bench brain below target: {ok, id, name, episodes,
	# deficit}. Pure over live cards (override for tests); empty when
	# the whole bench already graduated. Cached manifest (mtime-gated):
	# this feeds the 30 s top-up tick.
	var ev := event_load_cached(event_id)
	if ev.is_empty():
		return {"ok": false, "error": "no such event"}
	var cards := _event_live_cards(live_override)
	var worst := ""
	var worst_eps := target
	for pid in (ev.get("pool", []) as Array):
		var s := str(pid)
		if not cards.has(s):
			continue
		var eps := int((cards[s] as Dictionary).get("train", 0))
		if eps < worst_eps:
			worst_eps = eps
			worst = s
	if worst == "":
		return {"ok": false, "error": "bench graduated"}
	return {"ok": true, "id": worst, "episodes": worst_eps,
		"deficit": target - worst_eps}


func event_next_group(event_id: String, after_letter: String = "") -> String:
	# First unfinished group after the given letter ("" = from the top):
	# the gallery preview target. "" when every group is done (final).
	var ev := event_load(event_id)
	if ev.is_empty():
		return ""
	var groups: Dictionary = ev.get("groups", {})
	var order: Array = ev.get("group_order", [])
	var past := after_letter == ""
	for g in order:
		var letter := str(g)
		if not past:
			if letter == after_letter:
				past = true
			continue
		if not bool((groups.get(letter, {}) as Dictionary).get("done", false)):
			return letter
	return ""


func event_set_phase(event_id: String, phase: String) -> void:
	var ev := event_load(event_id)
	if ev.is_empty():
		return
	ev["phase"] = phase
	event_save(ev)


func event_finish(event_id: String, champion_id: String) -> void:
	var ev := event_load(event_id)
	if ev.is_empty():
		return
	ev["status"] = "complete"
	ev["phase"] = "done"
	ev["champion_id"] = champion_id
	event_save(ev)
