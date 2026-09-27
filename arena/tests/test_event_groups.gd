extends SceneTree
## Group-stage event tests: snake draft, round-robin schedule, standings
## (wins -> KO -> ELO), fixed-order final, elimination order, pool bench.
## Run: godot --headless --path arena -s tests/test_event_groups.gd
## Exit code = failure count (0 = all green).

var failures := 0
var D = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _brains(n: int, base_elo: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({"id": "f%02d" % (i + 1), "name": "F%d" % (i + 1),
			"record": {"elo": float(base_elo - i * 10)}})
	return out


func _setup() -> void:
	D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_event_groups"
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")


func _cleanup() -> void:
	if D != null:
		D.queue_free()
		D = null
	if DirAccess.dir_exists_absolute("user://test_event_groups"):
		for f in DirAccess.get_files_at("user://test_event_groups"):
			DirAccess.remove_absolute("user://test_event_groups".path_join(f))
		DirAccess.remove_absolute("user://test_event_groups")


func test_snake_draft() -> void:
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 1, brains)
	_check(bool(beg.get("ok", false)), "event_begin accepts 16")
	var groups: Dictionary = beg.get("groups", {})
	# Ranks 1,8,9,16 -> A; 2,7,10,15 -> B; 3,6,11,14 -> C; 4,5,12,13 -> D.
	_check(groups["A"]["players"] == ["f01", "f08", "f09", "f16"], "snake group A")
	_check(groups["B"]["players"] == ["f02", "f07", "f10", "f15"], "snake group B")
	_check(groups["C"]["players"] == ["f03", "f06", "f11", "f14"], "snake group C")
	_check(groups["D"]["players"] == ["f04", "f05", "f12", "f13"], "snake group D")
	_check(str(beg.get("event_id", "")).begins_with("E"), "event id E-prefixed")


func _play_group() -> Dictionary:
	# Four fixtures through a full group file: p1 sweeps 3-0, p2 2-1,
	# p3 1-2, p4 0-3. Returns the group_complete result.
	var ps := _brains(4, 1500)
	var res: Dictionary = D.call("build_group_bracket", ps, "A", "E0",
		1, 0.5, 40.0)
	_check(bool(res.get("ok", false)), "group file builds")
	# Pair order: R1 (0v3,1v2) R2 (0v2,3v1) R3 (0v1,2v3). Winners:
	# R1M1 p1, R1M2 p2, R2M1 p1, R2M2 p2, R3M1 p1, R3M2 p3.
	var winners := ["alpha", "alpha", "alpha", "beta", "alpha", "alpha"]
	var last := {}
	for w in winners:
		var br: Dictionary = D.call("on_battle_result", w, {}, {}, {}, 2, 1)
		_check(str(br.get("action", "")) == "match_over", "best-of-1 decides")
		last = D.call("advance_after_match")
	_check(str(last.get("action", "")) == "group_complete", "schedule exhausts to group_complete")
	return last


func test_schedule_and_ko() -> void:
	_play_group()
	var st: Array = D.call("group_standings")
	_check(st.size() == 4, "four standings rows")
	_check(str(st[0]["id"]) == "f01" and int(st[0]["wins"]) == 3, "sweep takes group")
	_check(str(st[1]["id"]) == "f02" and int(st[1]["wins"]) == 2, "runner-up 2-1")
	_check(str(st[2]["id"]) == "f03" and int(st[2]["wins"]) == 1, "third 1-2")
	_check(str(st[3]["id"]) == "f04" and int(st[3]["wins"]) == 0, "cellar 0-3")
	_check(int(st[0]["kos"]) == 6, "KO scored accumulate (3 wins x ko_a 2)")
	_check(int(st[0]["matches"]) == 3, "everyone plays 3")


func test_ko_tiebreak() -> void:
	var ps := _brains(4, 1500)
	D.call("build_group_bracket", ps, "A", "E0", 1, 0.5, 40.0)
	# Force a 1-1 tie on wins between p2/p3 with different KO.
	# R1M1 p1, R1M2 p2 (ko 3), R2M1 p1, R2M2 p4, R3M1 p1, R3M2 p3
	# (ko 1): p1 3W; p2 W,L,L = 1W ko3; p3 L,L,W = 1W ko1; p4 1W.
	var plan := [["alpha", 0, 0], ["alpha", 3, 0], ["alpha", 0, 0],
		["alpha", 0, 0], ["alpha", 0, 0], ["alpha", 0, 1]]
	for p in plan:
		D.call("on_battle_result", p[0], {}, {}, {}, p[1], p[2])
		D.call("advance_after_match")
	var st: Array = D.call("group_standings")
	_check(int(st[1]["wins"]) == 1 and int(st[2]["wins"]) == 1, "tie on wins")
	_check(str(st[1]["id"]) == "f02", "KO breaks the tie")


func test_final_fixed_order() -> void:
	var brains := _brains(16, 2000)
	var res: Dictionary = D.call("build_final_bracket",
		["f01", "f02", "f03", "f04", "f05", "f06", "f07", "f08"],
		"E0", 1, 0.5, 40.0, brains)
	_check(bool(res.get("ok", false)), "final builds")
	var r0: Array = (D.tourney.get("rounds", []) as Array)[0]
	_check(r0.size() == 4, "four quarterfinals")
	_check(str((r0[0] as Dictionary).get("a_id", "")) == "f01"
		and str((r0[0] as Dictionary).get("b_id", "")) == "f02", "QF order preserved, no reseeding")


func test_event_chain() -> void:
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 3, brains)
	var eid := str(beg.get("event_id", ""))
	# Play all four groups (alpha sweeps every match), record each.
	var groups: Dictionary = beg.get("groups", {})
	for g in ["A", "B", "C", "D"]:
		var gp: Array = []
		var ginfo: Dictionary = groups.get(g, {})
		for pid in (ginfo.get("players", []) as Array):
			for b in brains:
				if str((b as Dictionary).get("id", "")) == str(pid):
					gp.append(b)
		D.call("build_group_bracket", gp, g, eid, 1, 0.5, 40.0)
		for _i in range(6):
			D.call("on_battle_result", "alpha", {}, {}, {}, 1, 0)
			D.call("advance_after_match")
		var rec: Dictionary = D.call("event_record_group", eid, g)
		_check(bool(rec.get("ok", false)), "group %s recorded" % g)
	var adv: Dictionary = D.call("event_advancers", eid)
	_check(bool(adv.get("ok", false)), "advancers resolve")
	# Alpha swept every group: A1 = first-listed of each snake group.
	var qf: Array = adv.get("advancers", [])
	_check(qf.size() == 8, "eight advancers")
	_check(qf[0] == "f01" and qf[1] == "f07", "QF1 A1 v B2")
	# Elimination order with rigged ELO: lowest first, min 3 matches.
	var live := {}
	for b in brains:
		live[str(b["id"])] = float(b["record"]["elo"])
	live["f16"] = 900.0
	live["f15"] = 950.0
	var cands: Dictionary = D.call("event_eliminate_candidates", eid, 3, live)
	_check(bool(cands.get("ok", false)), "candidates resolve")
	var order: Array = cands.get("candidates", [])
	_check(order[0] == "f16" and order[1] == "f15", "lowest ELO eliminated first")
	# Pool bench: cap trims lowest, draw takes highest.
	D.call("event_pool_add", eid, ["f16", "f15", "f01", "f02", "f03"], live)
	var ev: Dictionary = D.call("event_load", eid)
	_check((ev.get("pool", []) as Array).size() == 4, "pool capped at 4")
	_check(not ("f16" in (ev.get("pool", []) as Array)), "cap trims lowest ELO")
	var draw: Dictionary = D.call("event_draw_pool", eid, 2, live)
	_check((draw.get("drawn", []) as Array) == ["f01", "f02"], "draw takes top ELO")


func _initialize() -> void:
	_setup()
	test_snake_draft()
	test_schedule_and_ko()
	test_ko_tiebreak()
	test_final_fixed_order()
	test_event_chain()
	_cleanup()
	if failures == 0:
		print("ALL EVENT-GROUP TESTS PASSED")
	else:
		printerr("EVENT-GROUP TESTS: %d FAILURES" % failures)
	quit(failures)
