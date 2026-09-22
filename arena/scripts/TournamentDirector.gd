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

# Tournament state (empty dict = inactive).
var tourney: Dictionary = {}
var sudden_death_armed: bool = false

# Background training job: {pid, progress_path, result_file, brain_id,
# episodes} or {}.
var active_job: Dictionary = {}

# One-shot async vault op (e.g. generate): {pid, result_file, op} or {}.
var pending_async: Dictionary = {}

signal vault_changed()
signal job_progress(episode: int, total: int)
signal job_failed(error: String)
signal async_done(op: String, result: Dictionary)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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


func project_root() -> String:
	return ProjectSettings.globalize_path("res://../")


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


func run_cli_async(op: String, args: Array, result_file: String) -> Dictionary:
	# Non-blocking vault op: the CLI writes its result JSON to result_file;
	# _process polls it and emits async_done(op, result). Keeps the menu alive.
	if not python_ready:
		return {"ok": false, "error": "no working python found (%s)" % python_probe_error}
	if not pending_async.is_empty():
		return {"ok": false, "error": "another operation is already running"}
	if FileAccess.file_exists(result_file):
		DirAccess.remove_absolute(result_file)
	var pid := OS.create_process(python_exe,
		_cli_argv(args + ["--result-file", result_file]), false)
	if pid <= 0:
		return {"ok": false, "error": "could not spawn '%s'" % python_exe}
	pending_async = {"pid": pid, "result_file": result_file, "op": op,
		"started": Time.get_ticks_msec()}
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
	elif Time.get_ticks_msec() - int(pending_async.get("started", 0)) > 1800000:
		var op2 := str(pending_async.get("op", ""))
		pending_async = {}
		async_done.emit(op2, {"ok": false, "error": "operation timed out (30 min)"})


func list_brains() -> Array:
	var res := _run_cli(["list"])
	if res.get("ok", false):
		return res.get("brains", [])
	push_warning("[Director] vault list failed: %s" % res.get("error", "?"))
	return []


func archive_list() -> Array:
	# Hall of shame: archived biggest losers, newest last.
	var res := _run_cli(["archive-list"])
	if res.get("ok", false):
		return res.get("archived", [])
	push_warning("[Director] archive list failed: %s" % res.get("error", "?"))
	return []


func restore_archived(arch_id: String) -> Dictionary:
	return _run_cli(["restore", "--id", arch_id])


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


func delete_brain(brain_id: String) -> Dictionary:
	var res := _run_cli(["delete", "--id", brain_id])
	if res.get("ok", false):
		vault_changed.emit()
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


func start_training(brain_id: String, episodes: int, params: Dictionary) -> Dictionary:
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
		"--progress", progress_path, "--result-file", result_file])
	var pid := OS.create_process(python_exe, args, false)
	if pid <= 0:
		return {"ok": false, "error": "could not spawn '%s'" % python_exe}
	active_job = {"pid": pid, "progress_path": progress_path,
		"result_file": result_file, "brain_id": brain_id, "episodes": episodes}
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
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary:
				res = parsed
	job_progress.emit(int(res.get("episode", 0)), int(res.get("total", 0)))
	if float(res.get("pct", 0.0)) >= 100.0:
		active_job = {}
		vault_changed.emit()
		return res
	# Fail loud: the backend writes its result file on success AND on
	# error. If the process is gone without reaching 100%, the job
	# crashed (e.g. arity mismatch before episode 1) - report the backend
	# error instead of hanging at episode 0/50 forever.
	var pid := int(active_job.get("pid", 0))
	if pid > 0 and not OS.is_process_running(pid):
		var err_text := _read_job_result_error(str(active_job.get("result_file", "")))
		active_job = {}
		job_failed.emit(err_text)
	return res


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


func _process(_delta: float) -> void:
	if not active_job.is_empty():
		poll_job()
	if not pending_async.is_empty():
		_poll_async()


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


# ── Evolution mode: eternal tournament loop ──────────────────────
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
	for b in list_brains():
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
	var r: Dictionary = rec.get("record", {})
	return [int(r.get("matches_won", 0)) - int(r.get("matches_lost", 0)),
		_match_rate(r), _battle_rate(r), rec.get("name", "")]


func _match_rate(r: Dictionary) -> float:
	var d := int(r.get("matches_won", 0)) + int(r.get("matches_lost", 0))
	return float(r.get("matches_won", 0)) / max(d, 1) if d > 0 else WIN_RATE_FALLBACK


func _battle_rate(r: Dictionary) -> float:
	var d := int(r.get("wins", 0)) + int(r.get("losses", 0))
	return float(r.get("wins", 0)) / max(d, 1) if d > 0 else WIN_RATE_FALLBACK


func build_bracket(player_ids: Array, size: int, best_of: int, lr_scale: float, round_time: float = 40.0, quick: bool = false, brains_override: Array = [], random_draw: bool = false, consolation: bool = false) -> Dictionary:
	var all_brains: Array = list_brains() if brains_override.is_empty() else brains_override
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
	# Canonical single-elim seeding: place the strongest first into the
	# standard power-of-two seed order, so the top seeds take the byes,
	# the weakest meet earliest, and round 0 holds exactly size/2 slots
	# (real matches, BYE cards for the resting seeds, VACANT cards for
	# empty subtrees when the roster is under half full). Random draw
	# shuffles the entrants instead (byes fall luck-of-the-draw).
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
	var tid := "T%08X" % int(Time.get_unix_time_from_system())
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


func _new_match(a, b) -> Dictionary:
	return {
		"a_id": str(a.get("id", "")) if a != null else "",
		"a_name": str(a.get("name", "?")) if a != null else "",
		"b_id": str(b.get("id", "")) if b != null else "",
		"b_name": str(b.get("name", "?")) if b != null else "",
		"bye": (b == null and a != null), "vacant": (a == null and b == null),
		"wins_a": 0, "wins_b": 0, "draws": 0,
		"winner_id": "", "battles": 0,
	}


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
	for b in list_brains():
		if str(b.get("id", "")) == brain_id:
			return brains_dir.path_join(str(b.get("filename", "")))
	return ""


func get_load_params() -> Dictionary:
	var m := current_match()
	return {
		"alpha_path": brain_path(str(m.get("a_id", ""))),
		"beta_path": brain_path(str(m.get("b_id", ""))),
		"tournament_id": str(tourney.get("id", "")),
		"match": "R%dM%d" % [int(tourney.get("current_round", 0)) + 1,
			int(tourney.get("current_match", 0)) + 1],
		"lr_scale": float(tourney.get("lr_scale", 0.5)),
		"a_name": str(m.get("a_name", "ALPHA")),
		"b_name": str(m.get("b_name", "BETA")),
		"score_a": int(m.get("wins_a", 0)),
		"score_b": int(m.get("wins_b", 0)),
	}


func on_battle_result(winner: String, flight_a: Dictionary = {}, flight_b: Dictionary = {}, brain_stream: Dictionary = {}) -> Dictionary:
	# winner: "alpha" | "beta" | "draw". Per-battle flight telemetry is
	# banked on the match ("flights" list) so flight-style regressions
	# have recorded evidence; the pool-rate stream rides along when the
	# menu record toggle is on (gated arena-side; ~50 KB per battle).
	# Returns sequencing action for arena.
	var m := current_match()
	if m.is_empty():
		return {"action": "idle"}
	m["battles"] = int(m.get("battles", 0)) + 1
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
			sudden_death_armed = true
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


func match_slot_name(slot: String) -> String:
	var m := current_match()
	return str(m.get("a_name" if slot == "alpha" else "b_name", slot.to_upper()))


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
				if str(mm.get("winner_id", "")) != "":
					if _la:
						var ln := str(mm.get("b_name", "?")) if str(mm.get("winner_id", "")) == str(mm.get("a_id", "")) else str(mm.get("a_name", "?"))
						w = "  => %s (loser advances)" % ln
					else:
						var wn := str(mm.get("a_name", "?")) if str(mm.get("winner_id", "")) == str(mm.get("a_id", "")) else str(mm.get("b_name", "?"))
						w = "  => %s" % wn
				lines.append("  %s %d - %d %s%s%s" % [str(mm.get("a_name", "?")),
					int(mm.get("wins_a", 0)), int(mm.get("wins_b", 0)),
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
