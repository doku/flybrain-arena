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


func _panels(bracket) -> Array:
	# The 4 quadrant panels in order A, B, C, D.
	var grid: VBoxContainer = bracket.get_child(0)
	_check(grid.get_child_count() == 2, "overview has 2 rows")
	var out: Array = []
	for r in range(2):
		var row: HBoxContainer = grid.get_child(r)
		_check(row.get_child_count() == 2, "overview row has 2 panels")
		for k in range(2):
			out.append(row.get_child(k))
	return out


func _panel_border(panel: PanelContainer) -> Color:
	var sb := panel.get_theme_stylebox("panel") as StyleBoxFlat
	return sb.border_color


func _panel_texts(panel: PanelContainer) -> Array:
	var out: Array = []
	var vb: VBoxContainer = panel.get_child(0)
	for ch in vb.get_children():
		if ch is Label:
			out.append((ch as Label).text)
	return out


func test_overview_render() -> void:
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 5, brains)
	var eid := str(beg.get("event_id", ""))
	# Group B live after one pairing; A/C/D upcoming (no files).
	var groups: Dictionary = beg.get("groups", {})
	var bp: Array = []
	for pid in ((groups.get("B", {}) as Dictionary).get("players", []) as Array):
		for b in brains:
			if str((b as Dictionary).get("id", "")) == str(pid):
				bp.append(b)
	D.call("build_group_bracket", bp, "B", eid, 1, 0.5, 40.0)
	D.call("event_note_bracket", eid, "B", str(D.tourney.get("id", "")))
	D.call("on_battle_result", "alpha", {}, {}, {}, 2, 0)
	D.call("advance_after_match")
	var data: Dictionary = D.call("event_overview_data", eid)
	_check((data.get("groups", []) as Array).size() == 4, "overview has 4 groups")
	_check(str(data.get("current", "")) == "B", "current group resolved")
	var B = load("res://scripts/TournamentBracket.gd").new()
	B.call("render_event_groups", data, "B")
	var panels := _panels(B)
	_check(panels.size() == 4, "four quadrant panels")
	var heads: Array = []
	for p in panels:
		for t in _panel_texts(p):
			if str(t).begins_with("GROUP"):
				heads.append(str(t))
	_check(heads == ["GROUP A", "GROUP B  •  LIVE", "GROUP C", "GROUP D"],
		"headers placed A|B over C|D with live mark")
	var gold := 0
	for p in panels:
		if _panel_border(p) == Color(1.0, 0.82, 0.3, 1.0):
			gold += 1
	_check(gold == 1, "exactly the current group is gold-bordered")
	_check(_panel_border(panels[1]) == Color(1.0, 0.82, 0.3, 1.0),
		"group B (top-right) is the live one")
	# Quadrant B embeds a live fixture: R1M2 (cur 0,1) gold with LIVE.
	var labels := _all_labels(B)
	var live := 0
	for t in labels:
		if str(t).contains("LIVE") and str(t).begins_with("R"):
			live += 1
	_check(live == 1, "exactly one live pairing card")
	var champy := false
	var finals := false
	var r1 := false
	for t in labels:
		if str(t) == "CHAMPION":
			champy = true
		if str(t) in ["FINAL", "SEMIFINAL"]:
			finals = true
		if str(t) == "ROUND 1":
			r1 = true
	_check(not champy, "no champion column in group view")
	_check(not finals, "no final/semifinal headers in group view")
	_check(r1, "fixture round headers present")
	# Played group shows standings stars.
	var btexts := _panel_texts(panels[1])
	var stars := 0
	for t in btexts:
		if str(t).begins_with("★"):
			stars += 1
	_check(stars == 2, "top-2 starred in live table")
	B.free()


func _all_labels(node: Node) -> Array:
	var out: Array = []
	if node is Label:
		out.append((node as Label).text)
	for ch in node.get_children():
		out += _all_labels(ch)
	return out


func test_prebuilt_overview() -> void:
	# All four fixtures built up front: every quadrant renders versus
	# cards, never the "No tournament." placeholder.
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 9, brains)
	var eid := str(beg.get("event_id", ""))
	var groups: Dictionary = beg.get("groups", {})
	for g in ["A", "B", "C", "D"]:
		var gp: Array = []
		for pid in (((groups.get(g, {}) as Dictionary).get("players", [])) as Array):
			for b in brains:
				if str((b as Dictionary).get("id", "")) == str(pid):
					gp.append(b)
		D.call("build_group_bracket", gp, g, eid, 1, 0.5, 40.0)
		D.call("event_note_bracket", eid, g, str(D.tourney.get("id", "")))
	# Back to group A, play one pairing.
	var aid := str((((D.call("event_load", eid) as Dictionary).get("groups", {}) as Dictionary).get("A", {}) as Dictionary).get("bracket_id", ""))
	_check(D.call("load_state_file", D.tournament_dir.path_join(aid + ".json")),
		"group A reloads")
	D.call("on_battle_result", "alpha", {}, {}, {}, 1, 0)
	D.call("advance_after_match")
	var data: Dictionary = D.call("event_overview_data", eid)
	var cells: Array = data.get("groups", [])
	_check(cells.size() == 4, "four overview cells")
	for cell in cells:
		_check(((cell as Dictionary).get("rounds", []) as Array).size() == 3,
			"every quadrant has its fixture")
	_check(str(data.get("current", "")) == "A", "current is group A")
	var B = load("res://scripts/TournamentBracket.gd").new()
	B.call("render_event_groups", data, "A")
	var labels := _all_labels(B)
	var no_tourney := 0
	var heads := 0
	var cards := 0
	for t in labels:
		var s := str(t)
		if s == "No tournament.":
			no_tourney += 1
		if s == "ROUND 1" or s == "ROUND 2" or s == "ROUND 3":
			heads += 1
		if s.begins_with("R") and s.contains("M"):
			cards += 1
	_check(no_tourney == 0, "no empty quadrants")
	_check(heads == 12, "twelve fixture round headers")
	_check(cards == 24, "twenty-four versus cards")
	B.free()


func test_draw_break_stamp() -> void:
	# Three draws resolve by start-of-match ELO even when battle wins
	# disagree (1-3): the match is stamped and the card tagged, so the
	# green winner never looks wrong.
	var ps := _brains(4, 1500)
	D.call("build_group_bracket", ps, "A", "E0", 3, 0.5, 40.0)
	var adv := {}
	for i in range(3):
		adv = D.call("on_battle_result", "draw", {}, {}, {})
		if i < 2:
			_check(str(adv.get("action", "")) == "replay", "early draws replay")
	_check(str(adv.get("action", "")) == "match_over", "third draw ends match")
	_check(str(adv.get("match_winner", "")) == "alpha", "higher ELO takes it")
	_check(bool(adv.get("resolved_by_draw", false)), "resolved_by_draw flagged")
	var m: Dictionary = ((D.tourney.get("rounds", []) as Array)[0] as Array)[0]
	_check(bool(m.get("decided_by_draw", false)), "match stamped decided_by_draw")
	_check(str(m.get("winner_id", "")) == "f01", "winner is higher-ELO alpha")
	var B = load("res://scripts/TournamentBracket.gd").new()
	var card: PanelContainer = B.call("_make_match_card", m, 0, 0, false, false)
	var head := (card.get_child(0) as VBoxContainer).get_child(0) as Label
	_check(head.text.contains("DRAW-BREAK"), "card tagged DRAW-BREAK")
	B.free()


func _initialize() -> void:
	_setup()
	test_snake_draft()
	test_draw_break_stamp()
	test_schedule_and_ko()
	test_ko_tiebreak()
	test_final_fixed_order()
	test_event_chain()
	test_overview_render()
	test_prebuilt_overview()
	_cleanup()
	if failures == 0:
		print("ALL EVENT-GROUP TESTS PASSED")
	else:
		printerr("EVENT-GROUP TESTS: %d FAILURES" % failures)
	quit(failures)
