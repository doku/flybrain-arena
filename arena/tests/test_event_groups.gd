extends SceneTree
## Group-stage event tests: snake draft, round-robin schedule, standings
## (wins -> KO -> ELO), fixed-order final, elimination order, pool bench.
## Run: godot --headless --path arena -s tests/test_event_groups.gd
## Exit code = failure count (0 = all green).

var failures := 0
var D = null
var _poll_emits: Array = []


func _on_test_job_progress(ep: int, total: int) -> void:
	_poll_emits.append([ep, total])


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
	# Expected showcase accent, read from the source (not duplicated).
	_showcase_col = load("res://scripts/TournamentBracket.gd").COL_SHOWCASE


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
	# Elimination order with rigged ELO: lowest first, min 3 CAREER
	# matches (veterans only — the gate reads vault records, not the
	# event's files).
	var live := {}
	for b in brains:
		live[str(b["id"])] = {"elo": float(b["record"]["elo"]),
			"train": 80, "matches": 20}
	live["f16"] = {"elo": 900.0, "train": 80, "matches": 20}
	live["f15"] = {"elo": 950.0, "train": 80, "matches": 20}
	var cands: Dictionary = D.call("event_eliminate_candidates", eid, 3, 0.0, live)
	_check(bool(cands.get("ok", false)), "candidates resolve")
	var order: Array = cands.get("candidates", [])
	_check(order[0] == "f16" and order[1] == "f15", "lowest ELO eliminated first")
	# Pool bench: cap trims lowest, qualified draw favors the green.
	var cards := {}
	for b in brains:
		cards[str(b["id"])] = {"elo": float(b["record"]["elo"]), "train": 80, "matches": 20}
	cards["f16"] = {"elo": 900.0, "train": 80, "matches": 30}
	cards["f15"] = {"elo": 950.0, "train": 80, "matches": 30}
	cards["f03"] = {"elo": 1980.0, "train": 10, "matches": 1}
	D.call("event_pool_add", eid, ["f16", "f15", "f01", "f02", "f03"], cards)
	var ev: Dictionary = D.call("event_load", eid)
	_check((ev.get("pool", []) as Array).size() == 4, "pool capped at 4")
	_check(not ("f16" in (ev.get("pool", []) as Array)), "cap trims lowest ELO")
	# Vault-wide draw: the whole schooled vault is the pool (bench no
	# longer gates); undertrained never draw. Fresh manifest so no
	# group players are excluded as participants.
	D.call("event_save", {"id": "EDRAW", "group_order": [], "groups": {},
		"pool": []})
	seed(7)
	var draw: Dictionary = D.call("event_draw_pool", "EDRAW", 2, 50, 0.0,
		cards, brains)
	var drawn: Array = draw.get("drawn", [])
	_check(drawn.size() == 2, "draw deals two")
	_check(not ("f03" in drawn), "undertrained never draws")
	for pid in drawn:
		_check(int((cards[str(pid)] as Dictionary).get("train", 0)) >= 50,
			"drawn are qualified")


func test_cutoff_and_weighted_draw() -> void:
	# Demotion cutoff filters the axe; empty shortlists fall back to
	# matches-only order. Draws favor low-match qualifiers over time.
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 11, brains)
	var eid := str(beg.get("event_id", ""))
	var groups: Dictionary = beg.get("groups", {})
	var gp: Array = []
	for pid in (((groups.get("A", {}) as Dictionary).get("players", [])) as Array):
		for b in brains:
			if str((b as Dictionary).get("id", "")) == str(pid):
				gp.append(b)
	D.call("build_group_bracket", gp, "A", eid, 1, 0.5, 40.0)
	for _i in range(6):
		D.call("on_battle_result", "alpha", {}, {}, {}, 1, 0)
		D.call("advance_after_match")
	D.call("event_record_group", eid, "A")
	# Group A players: rig cards (only they have ring time).
	var cards := {}
	var rigged := [850.0, 950.0, 1250.0, 1500.0]
	var k := 0
	for pid in (((groups.get("A", {}) as Dictionary).get("players", [])) as Array):
		cards[str(pid)] = {"elo": rigged[k], "train": 80, "matches": 10}
		k += 1
	# Cutoff 1000: exactly the two sub-1000 brains qualify, worst first.
	var cands: Dictionary = D.call("event_eliminate_candidates", eid, 3, 1000.0, cards)
	_check(bool(cands.get("ok", false)), "cutoff shortlist resolves")
	var order: Array = cands.get("candidates", [])
	_check(order.size() == 2, "cutoff yields exactly two")
	# Cutoff nobody meets: falls back to matches-only ELO order.
	var fb: Dictionary = D.call("event_eliminate_candidates", eid, 3, 100.0, cards)
	var forder: Array = fb.get("candidates", [])
	_check(forder.size() == 4, "fallback covers all experienced")
	# Weighted draw over the whole vault: the 2-match rookie laps the
	# 30-match veterans. Fresh manifest (no participants to exclude).
	D.call("event_save", {"id": "EDRAW2", "group_order": [], "groups": {},
		"pool": []})
	var pool_cards := {
		"vet_a": {"elo": 1500.0, "train": 80, "matches": 30},
		"vet_b": {"elo": 1400.0, "train": 80, "matches": 30},
		"rook": {"elo": 1250.0, "train": 60, "matches": 2}}
	var droster := [{"id": "vet_a"}, {"id": "vet_b"}, {"id": "rook"}]
	seed(11)
	var tallies := {"vet_a": 0, "vet_b": 0, "rook": 0}
	for _i in range(30):
		var one: Dictionary = D.call("event_draw_pool", "EDRAW2", 1, 50,
			0.0, pool_cards, droster)
		tallies[str((one.get("drawn", []) as Array)[0])] += 1
	_check(int(tallies["rook"]) > int(tallies["vet_a"]), "rookie outdraws veterans")
	_check(int(tallies["rook"]) > int(tallies["vet_b"]), "rookie outdraws veterans II")
	# Training floor + ELO floor gate the bench (qualification
	# still reads the bench; only the draw went vault-wide).
	D.call("event_pool_add", eid, ["vet_a", "vet_b", "rook"], pool_cards)
	var q: Dictionary = D.call("event_pool_qualified", eid, 50, 1450.0, pool_cards)
	_check((q.get("qualified", []) as Array) == ["vet_a"], "floors gate qualification")


func test_topup_pick() -> void:
	# Least-trained bench brain below target wins the schooling slot;
	# a graduated bench (or missing event) yields nothing to do.
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 13, brains)
	var eid := str(beg.get("event_id", ""))
	var cards := {
		"f01": {"elo": 1500.0, "train": 80, "matches": 10},
		"f02": {"elo": 1400.0, "train": 30, "matches": 5},
		"f03": {"elo": 1300.0, "train": 45, "matches": 5},
		"f04": {"elo": 1200.0, "train": 60, "matches": 5}}
	D.call("event_pool_add", eid, ["f01", "f02", "f03", "f04"], cards)
	var pick: Dictionary = D.call("event_topup_pick", eid, 50, cards)
	_check(bool(pick.get("ok", false)), "top-up pick resolves")
	_check(str(pick.get("id", "")) == "f02", "fewest-trained picked")
	_check(int(pick.get("deficit", 0)) == 20, "deficit to target")
	var grad: Dictionary = D.call("event_topup_pick", eid, 10, cards)
	_check(not bool(grad.get("ok", false)), "graduated bench picks nothing")
	var nope: Dictionary = D.call("event_topup_pick", "E404", 50, cards)
	_check(not bool(nope.get("ok", false)), "missing event errors")


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
	# Expanded standings: words not shorthand, leader tags present.
	var wins_word := false
	var ko_word := false
	var wins_tag := false
	var ko_tag := false
	for t in btexts:
		var s := str(t)
		if s.contains("Wins: 1"):
			wins_word = true
		if s.contains("Knockouts: 2"):
			ko_word = true
		if s.contains("WINS LEADER"):
			wins_tag = true
		if s.contains("KO LEADER"):
			ko_tag = true
	_check(wins_word, "expanded Wins label")
	_check(ko_word, "expanded Knockouts label")
	_check(wins_tag, "wins leader tagged")
	_check(ko_tag, "KO leader tagged")
	B.free()


func test_bracket_close_toggle() -> void:
	# The overlay CLOSE row sits under the menu bar (unreachable), so
	# the menu-bar button doubles as the close control: "Bracket
	# Close" while open, "BRACKET" while closed.
	var A = load("res://scripts/ArenaManager.gd").new()
	A.bracket_button = Button.new()
	A.bracket_overlay = Control.new()
	A.bracket_overlay.visible = false
	A.call("_sync_bracket_button")
	_check(A.bracket_button.text == "BRACKET", "closed reads BRACKET")
	A.bracket_overlay.visible = true
	A.call("_sync_bracket_button")
	_check(A.bracket_button.text == "Bracket Close", "open reads Bracket Close")
	A.bracket_overlay.visible = false
	A.call("_hide_arena_bracket")
	_check(A.bracket_button.text == "BRACKET", "hide restores BRACKET")
	A.bracket_button.free()
	A.bracket_overlay.free()
	A.free()


func test_slowmo_safety() -> void:
	# Finish pacing constants sane; the timescale restore (quit/stop/
	# load safety net) always lands back at real time.
	var AM = load("res://scripts/ArenaManager.gd")
	_check(AM.CALLOUT_TITLE_FS >= 40 and AM.CALLOUT_TITLE_FS <= 72,
		"callout title readable, not full-screen")
	_check(AM.SLOWMO_SCALE > 0.0 and AM.SLOWMO_SCALE < 1.0,
		"slow-mo actually slows")
	_check(AM.SLOWMO_SECS > 0.0 and AM.WINNER_BEAT_SECS > 0.0,
		"positive finish beats")
	var A = AM.new()
	Engine.time_scale = AM.SLOWMO_SCALE
	A.set("_slowmo_active", true)
	A.call("_restore_timescale")
	_check(Engine.time_scale == 1.0, "timescale restores to real time")
	_check(bool(A.get("_slowmo_active")) == false, "slow-mo flag clears")
	A.free()


func test_next_group_sequence() -> void:
	# Gallery preview target: first unfinished group after the given
	# one ("" from the top); "" once everything is done (the final).
	var brains := _brains(16, 2000)
	var ids: Array = []
	for b in brains:
		ids.append(str(b["id"]))
	var beg: Dictionary = D.call("event_begin", ids,
		{"best_of": 1, "lr_scale": 0.5, "round_time": 40.0}, 15, brains)
	var eid := str(beg.get("event_id", ""))
	_check(str(D.call("event_next_group", eid, "")) == "A", "starts at A")
	_check(str(D.call("event_next_group", eid, "A")) == "B", "A previews B")
	_check(str(D.call("event_next_group", eid, "C")) == "D", "C previews D")
	_check(str(D.call("event_next_group", eid, "D")) == "", "D previews nothing")
	_check(str(D.call("event_next_group", "E404", "A")) == "", "missing event is empty")


func test_gallery_cache_key() -> void:
	# Cache keys namespace by event: same group letter in consecutive
	# generations must never share a gallery cache entry.
	var A = load("res://scripts/ArenaManager.gd").new()
	var k1: String = A.call("_gallery_cache_key", "E1", "B")
	var k2: String = A.call("_gallery_cache_key", "E2", "B")
	var k3: String = A.call("_gallery_cache_key", "E1", "ALL")
	_check(k1 != k2, "group key differs across events")
	_check(k1 != k3, "ALL key differs from group key")
	_check(k1 == "E1:B", "key format is event:target")
	A.free()


func test_soften_worker_noop() -> void:
	# Worker deprioritization never raises: dead/invalid pids on any
	# host are silently ignored (fire-and-forget by design).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.call("_soften_worker", -1)
	D.call("_soften_worker", 0)
	D.call("_soften_worker", 999999999)
	_check(true, "soften invalid pids without error")
	D.free()


func test_pip_slot_defaults() -> void:
	# Stats view is the default slot; the stat card renders full-word
	# record, traits, pedigree and live numbers (zeros headless, never
	# a crash).
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(str(A.get("pip_slot_mode")) == "STATS", "stats on by default")
	var txt: String = A.call("_pip_stats_text", "alpha")
	_check(txt.contains("Battles:") and txt.contains("Evasion:"),
		"card has record + traits")
	_check(txt.contains("Knockouts:") and txt.contains("Pedigree:"),
		"card has fight numbers + pedigree")
	A.free()


func test_pip_slot_cycle() -> void:
	# PiP slot rotation: EYES -> BRAIN -> STATS -> MOTORS -> EYES;
	# junk resets.
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(A.call("pip_slot_next", "EYES") == "BRAIN", "eyes to brain")
	_check(A.call("pip_slot_next", "BRAIN") == "STATS", "brain to stats")
	_check(A.call("pip_slot_next", "STATS") == "MOTORS", "stats to motors")
	_check(A.call("pip_slot_next", "MOTORS") == "EYES", "motors wraps to eyes")
	_check(A.call("pip_slot_next", "junk") == "EYES", "unknown resets")
	A.free()


func test_roster_cache() -> void:
	# Hot-path roster serves cache without shelling; stale falls back
	# to cache on backend hiccups; invalidate drops it.
	var D = load("res://scripts/TournamentDirector.gd").new()
	var sample := [{"id": "x", "name": "X"}]
	D.set("brains_cache", sample)
	D.set("brains_cache_msec", Time.get_ticks_msec())
	_check(D.call("list_brains_cached", 60000) == sample, "fresh cache served")
	D.set("brains_cache_msec", 0)
	_check(D.call("list_brains_cached", 60000) == sample, "stale serves cache on backend miss")
	D.call("invalidate_brains_cache")
	_check((D.get("brains_cache") as Array).is_empty(), "invalidate clears")
	_check((D.call("list_brains_cached", 60000) as Array).is_empty(), "empty cache shells to empty")
	D.free()


func test_spawn_hold() -> void:
	# Queue pumps refuse while held (mid-battle) and keep the head;
	# released, they attempt launch (no python headless: fails kept).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.set("hold_spawns", true)
	D.call("enqueue_training", "b1", "B1", 5, {})
	_check(not bool(D.call("pump_train_queue")), "held pump refuses")
	_check((D.get("train_queue") as Array).size() == 1, "held pump keeps head")
	D.call("enqueue_score", "b1", "B1")
	_check(not bool(D.call("pump_score_queue")), "held score pump refuses")
	D.set("hold_spawns", false)
	_check(not bool(D.call("pump_train_queue")), "failed launch keeps head")
	_check((D.get("train_queue") as Array).size() == 1, "queue intact after failed launch")
	D.free()


func test_worker_affinity_mask() -> void:
	# Workers stay off the game's cores: CPU 0 reserved on small
	# machines, CPUs 0-1 on roomy ones, nothing reserved when tiny.
	var D = load("res://scripts/TournamentDirector.gd").new()
	_check(int(D.call("_worker_affinity_mask_for", 1)) == 1, "1 cpu: full mask")
	_check(int(D.call("_worker_affinity_mask_for", 2)) == 3, "2 cpu: full mask")
	_check(int(D.call("_worker_affinity_mask_for", 4)) == 14, "4 cpu: reserve cpu0")
	_check(int(D.call("_worker_affinity_mask_for", 8)) == 252, "8 cpu: reserve cpu0-1")
	var m8 := int(D.call("_worker_affinity_mask_for", 8))
	_check(m8 & 3 == 0 and m8 & 4 != 0, "8 cpu: game cores clear, worker cores kept")
	D.free()


func test_live_cards_use_cache() -> void:
	# Pool math must never shell mid-battle: with a seeded cache and
	# no python (headless), live cards still resolve from memory.
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.set("brains_cache", [{"id": "c1",
		"record": {"elo": 1500.0, "matches": 12},
		"training": {"episodes": 60}}])
	D.set("brains_cache_msec", Time.get_ticks_msec())
	var cards: Dictionary = D.call("_event_live_cards", {})
	_check((cards.get("c1", {}) as Dictionary).get("elo", 0.0) == 1500.0,
		"live cards served from cache")
	_check(int((cards.get("c1", {}) as Dictionary).get("train", 0)) == 60,
		"live cards carry cached schooling")
	D.free()


func test_event_manifest_cache() -> void:
	# Tick paths must not re-parse the manifest every poll: served from
	# memory when unchanged, fresh on change, write-through on save.
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_event_groups"
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")
	var ev := {"id": "ECACHE1", "pool": [], "groups": {}}
	_check(bool(D.call("event_save", ev)), "event save ok")
	var first: Dictionary = D.call("event_load_cached", "ECACHE1")
	_check(str(first.get("id", "")) == "ECACHE1", "manifest cached after save")
	var mtime := int(D.event_cache_mtime)
	# Same file: served from memory (mtime matches).
	var again: Dictionary = D.call("event_load_cached", "ECACHE1")
	_check(int(D.event_cache_mtime) == mtime, "unchanged file serves memory")
	# Writer writes through: the cache tracks the new content.
	ev["phase"] = "final"
	D.call("event_save", ev)
	var thru: Dictionary = D.call("event_load_cached", "ECACHE1")
	_check(str(thru.get("phase", "")) == "final", "save writes through")
	# External edit (no write-through): fresh parse on mtime change.
	# FAT/exFAT mtime granularity is ~2 s, so a real gap is needed for
	# the stamp to move (only the director writes event files in play,
	# and writers write through - this is the staleness bound anyway).
	OS.delay_msec(2100)
	var f := FileAccess.open("user://test_event_groups/ECACHE1.json",
		FileAccess.WRITE)
	f.store_string(JSON.stringify({"id": "ECACHE1", "pool": [],
		"groups": {}, "phase": "external"}))
	f.close()
	var ext: Dictionary = D.call("event_load_cached", "ECACHE1")
	_check(str(ext.get("phase", "")) == "external", "external edit re-parses")
	D.call("event_save", {"id": "ECACHE2"})
	D.free()
	if DirAccess.dir_exists_absolute("user://test_event_groups"):
		for f2 in DirAccess.get_files_at("user://test_event_groups"):
			DirAccess.remove_absolute("user://test_event_groups".path_join(f2))
		DirAccess.remove_absolute("user://test_event_groups")


func test_battle_invalidate_primitive() -> void:
	# The arena invalidates the roster on every battle bank (server
	# writes are invisible to the cache): invalidate must clear so the
	# next gap tick/load refreshes instead of serving stale ELO.
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.set("brains_cache", [{"id": "x"}])
	D.set("brains_cache_msec", Time.get_ticks_msec())
	D.call("invalidate_brains_cache")
	_check((D.get("brains_cache") as Array).is_empty(),
		"battle invalidate clears roster cache")
	D.free()


func test_poll_emit_no_flicker() -> void:
	# Skip-parse must reuse the last parsed dict: two polls on
	# unchanged progress text emit once with the true episode, never
	# a spurious (0, total) flicker in between.
	var DD = load("res://scripts/TournamentDirector.gd").new()
	var pf := "user://test_poll_progress.json"
	var f := FileAccess.open(pf, FileAccess.WRITE)
	f.store_string(JSON.stringify({"episode": 3, "total": 50, "pct": 6.0}))
	f.close()
	DD.set("active_job", {"pid": 0, "progress_path": pf,
		"result_file": "", "brain_id": "t", "episodes": 50,
		"school": false})
	_poll_emits = []
	DD.job_progress.connect(_on_test_job_progress)
	DD.call("poll_job")
	DD.call("poll_job")
	DD.call("poll_job")
	_check(_poll_emits == [[3, 50]], "unchanged progress emits once, no zero flicker")
	DD.free()
	if FileAccess.file_exists(pf):
		DirAccess.remove_absolute(pf)


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
	# Finals/single-elim keep the decisive ELO tiebreak (groups split
	# instead): three draws resolve by start-of-match ELO, stamped and
	# tagged, so the green winner never looks wrong.
	var ps := _brains(2, 1500)
	D.call("build_bracket", ["f01", "f02"], 2, 3, 0.5, 40.0, false, ps, false, false)
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


func test_prior_wins_and_split() -> void:
	# Sudden death in groups: prior match-wins upset battle count
	# (best-of-1 pairings); tied priors split 0.5/0.5.
	var ps := _brains(4, 1500)
	D.call("build_group_bracket", ps, "A", "E0", 1, 0.5, 40.0)
	# p1 takes R1M1 + R2M1 (2 priors); p2 takes R2M2 (1 prior); the
	# R3M1 pairing (p1 v p2) goes to 3 draws -> p1 on merit.
	for p in ["alpha", "beta", "alpha", "beta"]:
		var br: Dictionary = D.call("on_battle_result", p, {}, {}, {})
		_check(str(br.get("action", "")) == "match_over", "pairing decides")
		D.call("advance_after_match")
	var adv := {}
	for i in range(3):
		adv = D.call("on_battle_result", "draw", {}, {}, {})
	_check(str(adv.get("action", "")) == "match_over", "third draw ends match")
	_check(str(adv.get("match_winner", "")) == "alpha", "prior match-wins decide")
	# Fresh file: tied priors split.
	var ps2 := _brains(4, 1500)
	D.call("build_group_bracket", ps2, "A", "E0", 1, 0.5, 40.0)
	for i in range(3):
		adv = D.call("on_battle_result", "draw", {}, {}, {})
	_check(str(adv.get("action", "")) == "match_over", "tie still ends match")
	_check(str(adv.get("match_winner", "")) == "draw", "tied priors split the point")
	_check(bool((((D.tourney.get("rounds", []) as Array)[0] as Array)[0] as Dictionary).get("drawn", false)),
		"match stamped drawn")
	var st: Array = D.call("group_standings")
	_check(absf(float(st[0]["wins"]) - 0.5) < 0.001 and absf(float(st[1]["wins"]) - 0.5) < 0.001,
		"both sides hold 0.5 wins")
	_check(str(D.call("bracket_text")).contains("DRAW SPLIT"), "record prints the split")
	_check(str(D.call("_fmt_wins", 2.5)) == "2.5", "fractional wins print trimmed")
	_check(str(D.call("_fmt_wins", 3.0)) == "3", "whole wins print as ints")


func test_booster_rule() -> void:
	# Booster = DNF (>=1 drawn battle) in EVERY played match.
	# Schedule [[0,3],[1,2],[0,2],[3,1],[0,1],[2,3]]: M1 decisive,
	# M2-M6 each open with a draw, so f2/f3 DNF everywhere while
	# f1/f4 go clean in M1.
	var ps := _brains(4, 1500)
	D.call("build_group_bracket", ps, "A", "EBOOST", 1, 0.5, 40.0)
	var br: Dictionary = D.call("on_battle_result", "alpha", {}, {}, {})
	_check(str(br.get("action", "")) == "match_over", "M1 decisive")
	D.call("advance_after_match")
	for i in range(5):
		br = D.call("on_battle_result", "draw", {}, {}, {})
		_check(str(br.get("action", "")) == "replay", "draw replays")
		br = D.call("on_battle_result", "alpha", {}, {}, {})
		_check(str(br.get("action", "")) == "match_over", "replay decides")
		D.call("advance_after_match")
	var st: Array = D.call("group_standings")
	var dnf := {}
	for row in st:
		dnf[str((row as Dictionary).get("id", ""))] = \
			int((row as Dictionary).get("dnf", -1))
	_check(int(dnf.get("f01", -1)) == 2, "f1 DNF 2 (M3, M5)")
	_check(int(dnf.get("f04", -1)) == 2, "f4 DNF 2 (M4, M6)")
	_check(int(dnf.get("f02", -1)) == 3, "f2 DNF 3 (every match)")
	_check(int(dnf.get("f03", -1)) == 3, "f3 DNF 3 (every match)")
	var boosters: Array = D.call("event_booster_set")
	boosters.sort()
	_check(boosters == ["f02", "f03"], "only all-DNF flies marked")
	# Manifest banking: per-group list + accumulated top-level list,
	# idempotent across repeat records.
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")
	D.call("event_save", {"id": "EBOOST", "groups": {"A": {}}})
	var rec: Dictionary = D.call("event_record_group", "EBOOST", "A")
	_check(bool(rec.get("ok", false)), "group record ok")
	_check((rec.get("booster", []) as Array).size() == 2, "record returns set")
	D.call("event_record_group", "EBOOST", "A")
	var ev: Dictionary = D.call("event_load", "EBOOST")
	var accum: Array = ev.get("booster", [])
	accum.sort()
	_check(accum == ["f02", "f03"], "top-level booster accumulates, no dupes")
	_check((((ev.get("groups", {}) as Dictionary).get("A", {}) as Dictionary).get("booster", []) as Array).size() == 2,
		"per-group booster banked")


func test_booster_queue() -> void:
	# Post-event queueing: marked brains get +50 school-curriculum
	# trains with [BOOSTER] names; ghosts skipped; ids already queued
	# never double-enqueue (enqueue appends blindly).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_event_groups"
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")
	D.set("brains_cache", [
		{"id": "q1", "name": "Q1",
			"generator_params": {"variant": "custom", "seed": 3},
			"record": {"elo": 1500.0}, "training": {"episodes": 60}},
		{"id": "q2", "name": "Q2",
			"generator_params": {"variant": "custom", "seed": 4},
			"record": {"elo": 1400.0}, "training": {"episodes": 10}}])
	D.set("brains_cache_msec", Time.get_ticks_msec())
	D.call("event_save", {"id": "EQ", "groups": {},
		"booster": ["q1", "q2", "ghost"]})
	var res: Dictionary = D.call("event_booster_queue", "EQ")
	_check(bool(res.get("ok", false)), "booster queue ok")
	var queued: Array = res.get("queued", [])
	queued.sort()
	_check(queued == ["q1", "q2"], "vault brains queued, ghost skipped")
	var items: Array = D.get("train_queue")
	_check(items.size() == 2, "two queue entries")
	for item in items:
		var it := item as Dictionary
		_check(int(it.get("episodes", 0)) == 50, "flat +50 additional")
		_check((it.get("params", {}) as Dictionary).has("curriculum"),
			"school curriculum included")
		_check(bool((it.get("params", {}) as Dictionary).has("booster")),
			"booster marker tagged")
		_check(str(it.get("name", "")).ends_with("[BOOSTER]"),
			"queue name tagged")
	# Second pass: everything already queued -> no-ops.
	var res2: Dictionary = D.call("event_booster_queue", "EQ")
	_check((res2.get("queued", []) as Array).is_empty(), "dedupe no-ops")
	_check((D.get("train_queue") as Array).size() == 2, "queue intact")
	D.free()


func test_train_hud_parts() -> void:
	# Training half of the EVO status line: pure helper, handler
	# storage, and the completion ring (cap 5, newest last).
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(A.call("_train_queue_parts", [], {}, [], -1, -1).is_empty(),
		"train parts empty")
	var p1: Array = A.call("_train_queue_parts",
		[], {"brain_id": "id9", "name": "Brisk-kin-12-extra"}, [], 22, 50)
	_check(p1 == ["TRAIN Brisk-kin-12-e 22/50"], "train active part")
	var p1w: Array = A.call("_train_queue_parts",
		[], {"brain_id": "id9", "name": "Kestrel"}, [], -1, -1)
	_check(p1w == ["TRAIN Kestrel warming up"], "train warming up")
	var q := [{"id": "a", "name": "Alpha-brain-long-name"},
		{"id": "b", "name": "Beta"}, {"id": "c", "name": "Gamma"}]
	var p2: Array = A.call("_train_queue_parts", q, {}, [], -1, -1)
	_check(p2 == ["QUEUED Alpha-brain-lo +2"], "train queue part")
	var dn := [{"name": "Old", "episodes": 10},
		{"name": "Fresh-brain-long", "episodes": 50}]
	var p3: Array = A.call("_train_queue_parts", [], {}, dn, -1, -1)
	_check(p3 == ["DONE Fresh-brain-lo +50ep"], "train done part")
	A.call("_on_train_progress", 22, 50)
	_check(int(A.get("_train_prog_ep")) == 22, "handler stores ep")
	_check(int(A.get("_train_prog_total")) == 50, "handler stores total")
	A.free()
	var DD = load("res://scripts/TournamentDirector.gd").new()
	for i in range(7):
		DD.call("_record_train_done", "B%d" % i, 50)
	var ring: Array = DD.get("completed_trains")
	_check(ring.size() == 5, "done ring caps")
	_check(str((ring[4] as Dictionary).get("name", "")) == "B6",
		"done ring newest last")
	DD.free()


func test_countdown_gates() -> void:
	# Bracket countdowns must never run a live round: every wait view
	# closes the round the moment it goes up (the scene default
	# is_round_active=true fought behind boot tip-offs/resumes and
	# phantom-timed-out a battle on the first tick). Official start
	# stays brains_loaded -> _reset_round. Countdown times pinned:
	# 30 s tip-off, 60 s between groups, 120 s before the final.
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("is_round_active", true)
	A.call("_close_round_for_wait")
	_check(not bool(A.get("is_round_active")), "wait helper closes a live round")
	A.call("_close_round_for_wait")
	_check(not bool(A.get("is_round_active")), "wait helper stays closed")
	_check(absf(A.EVENT_PREVIEW_SECS - 30.0) < 0.01, "tip-off counts down 30 s")
	_check(absf(A.EVENT_INTERMISSION_SECS - 60.0) < 0.01,
		"group intermission counts down 60 s")
	_check(absf(A.EVENT_FINAL_SECS - 120.0) < 0.01,
		"final counts down 120 s")
	A.free()


func test_handoff_prebuild_all_groups() -> void:
	# Event handoff contract (the wiring _event_start_next relies on):
	# the new event starts with ALL FOUR group brackets built + noted -
	# a single-A build left B/C/D lazy and the overview showed
	# unpopulated groups. Drive the exact handoff prebuild at the
	# director level (brains_override: no vault needed).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_prebuild"
	DirAccess.make_dir_recursive_absolute("user://test_prebuild")
	var brains: Array = []
	var ids: Array = []
	for i in range(16):
		brains.append({"id": "pb%02d" % i, "name": "P%d" % (i + 1),
			"record": {"elo": 1500.0 - i}})
		ids.append("pb%02d" % i)
	var beg: Dictionary = D.call("event_begin", ids, {"best_of": 3}, 2, brains)
	_check(bool(beg.get("ok", false)), "event begins with 16")
	var eid := str(beg.get("event_id", ""))
	for letter in ["A", "B", "C", "D"]:
		var g: Dictionary = (beg.get("groups", {}) as Dictionary).get(letter, {})
		var dicts: Array = []
		for b in brains:
			if ids.has(str(b.get("id", ""))) and (g.get("players", []) as Array).has(str(b.get("id", ""))):
				dicts.append(b)
		var res: Dictionary = D.call("build_group_bracket", dicts,
			str(letter), eid, 3, 0.5, 40.0)
		_check(bool(res.get("ok", false)), "group %s bracket built" % str(letter))
		D.call("event_note_bracket", eid, str(letter),
			str((res as Dictionary).get("tournament_id", "")))
	var ev: Dictionary = D.call("event_load", eid)
	_check(not ev.is_empty(), "event loads back")
	for letter in ["A", "B", "C", "D"]:
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(letter, {})
		var bid := str(gd.get("bracket_id", ""))
		_check(bid != "", "group %s noted" % letter)
		_check(FileAccess.file_exists(D.tournament_dir.path_join(bid + ".json")),
			"group %s file exists" % letter)
	_check(((ev.get("groups", {}) as Dictionary).get("A", {})
		as Dictionary).get("players", []).size() == 4, "group A fully drawn")
	D.free()
	if DirAccess.dir_exists_absolute("user://test_prebuild"):
		for f in DirAccess.get_files_at("user://test_prebuild"):
			DirAccess.remove_absolute("user://test_prebuild".path_join(f))
		DirAccess.remove_absolute("user://test_prebuild")


func test_preload_and_peek() -> void:
	# Preload plumbing: director peek (same-round known, cross-round
	# unknown, vacant/bye walked past, roster-served paths), arena echo
	# validation (stale brains_loaded dropped), bare preload no-op.
	var D = load("res://scripts/TournamentDirector.gd").new()
	var roster: Array = []
	for b in ["a", "b", "c", "d"]:
		roster.append({"id": b, "filename": b + ".flybrain"})
	D.set("tourney", {"id": "T1", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0, "rounds": [[
			{"a_id": "a", "b_id": "b", "a_name": "A", "b_name": "B"},
			{"a_id": "c", "b_id": "d", "a_name": "C", "b_name": "D"}]]})
	_check(D.call("next_match_params").is_empty(), "peek needs a roster")
	D.set("brains_cache", roster)
	D.set("brains_cache_msec", Time.get_ticks_msec())
	var p: Dictionary = D.call("next_match_params")
	_check(str(p.get("match", "")) == "R1M2",
		"peek sees the same-round next match")
	_check(str(p.get("alpha_path", "")).ends_with("c.flybrain"),
		"peek resolves alpha path")
	_check(str(p.get("beta_path", "")).ends_with("d.flybrain"),
		"peek resolves beta path")
	_check(str(p.get("tournament_id", "")) == "T1", "peek echoes the tournament")
	D.set("tourney", {"id": "T1", "lr_scale": 0.5,
		"current_round": 0, "current_match": 1, "rounds": [[
			{"a_id": "a", "b_id": "b", "a_name": "A", "b_name": "B"},
			{"a_id": "c", "b_id": "d", "a_name": "C", "b_name": "D"}]]})
	_check(D.call("next_match_params").is_empty(), "cross-round peek unknown")
	D.set("tourney", {"id": "T1", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0, "rounds": [[
			{"a_id": "a", "b_id": "b", "a_name": "A", "b_name": "B",
				"winner_id": "a"},
			{"vacant": true},
			{"a_id": "c", "b_id": "d", "a_name": "C", "b_name": "D"}]]})
	var p2: Dictionary = D.call("next_match_params")
	_check(str(p2.get("match", "")) == "R1M3", "peek walks past bye/vacant")
	D.free()
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("tournament_active", true)
	A.set("tourney_awaiting_load", true)
	A.set("_seq_context", "load")
	A.set("_seq_last_load", {"tournament_id": "T1", "match": "R1M1"})
	A.call("_on_brains_loaded", {}, {}, "T2", "R1M2")
	_check(bool(A.get("tourney_awaiting_load")),
		"stale brains_loaded dropped (latch holds)")
	# (Matching-echo acceptance runs on the real scene in test_combat_fx:
	# the accept path proceeds into _reset_round, which needs real flies.)
	A.call("_preload_next_match")
	_check((A.get("_preload_params") as Dictionary).is_empty(),
		"bare preload no-ops (no director)")
	A.free()


func test_match_batch_flow() -> void:
	# Batched match reporting: battles cache locally (id, draw flags,
	# verdict, stats, sens/ctrl context) with no server send; nothing
	# arms a battle await. The match report send is a real-scene path
	# (test_combat_fx: watchdogs touch live nodes).
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("tournament_active", true)
	_check((A.get("_match_battle_cache") as Array).is_empty(),
		"cache starts empty")
	A.call("_battle_done_local", false, false)
	var cache: Array = A.get("_match_battle_cache")
	_check(cache.size() == 1, "battle cached, no server send")
	var b: Dictionary = cache[0]
	_check(b.has("battle_id") and b.has("draw") and b.has("draw_penalty"),
		"cache carries id + draw flags")
	_check((b.get("verdict", {}) as Dictionary).has("winner_slot"),
		"cache carries verdict")
	_check((b.get("stats_a", {}) as Dictionary).has("kills"),
		"cache carries stats")
	_check(b.has("sens_a") and b.has("sens_b")
		and b.has("ctrl_a") and b.has("ctrl_b"),
		"cache carries sens/ctrl context")
	A.call("_battle_done_local", true, false)
	_check((A.get("_match_battle_cache") as Array).size() == 2,
		"draw caches too")
	_check(not bool(A.get("_tourney_awaiting_battle")),
		"no battle await armed")
	_check(str(A.get("_seq_context")) == "", "no battle watchdog armed")
	_check(not bool(A.call("_forgivable_roundbank", "RND-1")),
		"empty round forgive map")
	# Bare instance has no director, so its tournament id is "" - the
	# forgive map matches on the same empty id plus the owed nonce.
	A.set("_seq_forgive_roundbank", {"tournament_id": "", "match": "R1M1",
		"battle": "RND-1"})
	_check(bool(A.call("_forgivable_roundbank", "RND-1")),
		"owed round nonce forgives")
	_check(not bool(A.call("_forgivable_roundbank", "RND-2")),
		"other nonce does not forgive")
	A.free()


func test_motor_debug() -> void:
	# MOTORS PiP debug: text formatting, silence streak counting,
	# trace ring cap, bar value mapping + clamping. (The 4-mode cycle
	# itself is pinned in test_pip_slot_cycle.)
	var A = load("res://scripts/ArenaManager.gd").new()
	var t: String = A.call("_motor_debug_text",
		{"thrust": 0.62, "yaw_torque": 0.31, "pitch_torque": -0.12,
			"roll_torque": 0.05, "spear_thrust": 0.0, "ram_drive": 0.0,
			"emergency_evade": false}, 142.0, 0)
	_check(t == "THR 0.62   SPK 142/s\nYAW +0.31R\nPITCH -0.12\nROLL +0.05\nSPEAR 0.00 RAM 0.0 -\nY+:right P+:climb R+:bankR",
		"motor text formats")
	var t9: String = A.call("_motor_debug_text", {}, 0.0, 9)
	_check(not t9.contains("SILENT"), "no badge below threshold")
	var t10: String = A.call("_motor_debug_text", {}, 0.0, 10)
	_check(t10.contains("SILENT (reflex only)"), "badge at threshold")
	var tc: String = A.call("_motor_debug_text",
		{"thrust": 0.2, "yaw_torque": 0.0}, 0.0, 0)
	_check(tc.contains("YAW +0.00\n"), "centered yaw carries no letter")
	for i in range(10):
		A.call("_push_motor_sample", "alpha", {}, {"spikes": 0})
	_check(int(A.get("_motor_silent_alpha")) == 10, "silence streak counts")
	A.call("_push_motor_sample", "alpha", {}, {"spikes": 5})
	_check(int(A.get("_motor_silent_alpha")) == 0, "spikes reset the streak")
	for i in range(130):
		A.call("_push_motor_sample", "beta", {"thrust": 0.5}, {"spikes": 3})
	_check((A.get("_motor_trace_beta") as Array).size() == 120,
		"trace ring caps")
	var bars: Array = []
	for i in range(4):
		var b := ProgressBar.new()
		b.min_value = 0.0 if i == 0 else -1.0
		b.max_value = 1.0
		bars.append(b)
	A.call("_set_motor_bars", bars,
		{"thrust": 2.0, "yaw_torque": -2.0, "pitch_torque": 0.5,
			"roll_torque": -0.25})
	_check(float((bars[0] as ProgressBar).value) == 1.0, "thrust clamps high")
	_check(float((bars[1] as ProgressBar).value) == -1.0, "yaw clamps low")
	_check(absf(float((bars[2] as ProgressBar).value) - 0.5) < 0.001,
		"pitch passes")
	_check(absf(float((bars[3] as ProgressBar).value) + 0.25) < 0.001,
		"roll passes")
	A.call("_set_motor_bars", [], {})
	_check(true, "empty bars no-op")
	for b in bars:
		(b as ProgressBar).free()
	A.free()


func test_eliminate_green_roster() -> void:
	# Green roster (nobody with 10 career matches): elimination has no
	# one to demote - the rule fails LOUD with the contract string the
	# handoff matches to waive elimination (instead of stalling).
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_elim"
	DirAccess.make_dir_recursive_absolute("user://test_elim")
	var roster: Array = []
	for i in range(4):
		roster.append({"id": "g%02d" % i, "name": "G%d" % (i + 1),
			"record": {"elo": 1500.0 - i * 10, "matches": 3}})
	D.set("brains_cache", roster)
	D.set("brains_cache_msec", Time.get_ticks_msec())
	var tour := {"id": "TELIM", "rounds": [[
		{"a_id": "g00", "b_id": "g01", "winner_id": "g00"},
		{"a_id": "g02", "b_id": "g03", "winner_id": "g02"}]]}
	var bf := FileAccess.open("user://test_elim/TELIM.json", FileAccess.WRITE)
	bf.store_string(JSON.stringify(tour))
	bf.close()
	D.call("event_save", {"id": "EELIM", "group_order": ["A"],
		"groups": {"A": {"players": ["g00", "g01", "g02", "g03"],
			"bracket_id": "TELIM", "standings": [], "done": false}}})
	var cands: Dictionary = D.call("event_eliminate_candidates",
		"EELIM", 10, 0.0)
	_check(((cands.get("candidates", []) as Array)).size() < 2,
		"green roster yields no candidates")
	var elim: Dictionary = D.call("event_eliminate", "EELIM", 10, 0.0)
	_check(not bool(elim.get("ok", false)), "green elimination fails loud")
	_check(str(elim.get("error", "")) == "fewer than 2 eligible brains",
		"failure carries the waive contract string")
	D.free()
	if DirAccess.dir_exists_absolute("user://test_elim"):
		for f in DirAccess.get_files_at("user://test_elim"):
			DirAccess.remove_absolute("user://test_elim".path_join(f))
		DirAccess.remove_absolute("user://test_elim")


func test_arena_session_log() -> void:
	# Persistent client-side session log: wedge/recovery events survive
	# the game window (stdout dies with it). Appends with a timestamp;
	# recovery + error paths write identifiable lines.
	var A = load("res://scripts/ArenaManager.gd").new()
	if DirAccess.dir_exists_absolute("user://"):
		for f in ["arena_log.txt"]:
			DirAccess.remove_absolute("user://".path_join(f))
	A.call("_arena_log", "unit test marker")
	var f := FileAccess.open("user://arena_log.txt", FileAccess.READ)
	_check(f != null, "session log created")
	if f != null:
		var text := f.get_as_text()
		f.close()
		_check(text.contains("unit test marker"),
			"session log carries the event")
		_check(text.length() > 24, "session log stamps the line")
		DirAccess.remove_absolute("user://arena_log.txt")
	A.free()


func test_draw_title_dnf() -> void:
	# Timeout-ties are called DNF, numbered by banked draws.
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(A.call("_draw_title") == "DNF", "first tie titled DNF")
	A.free()


func test_eliminate_career_gate() -> void:
	# Demotion is veterans-only: career matches >= min_matches AND
	# below the ELO line. A green brain with the WORST live ELO is
	# protected; low-match flies are never eaten to fill the shortlist.
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")
	var rounds := [[
		{"a_id": "v1", "b_id": "g1", "winner_id": "v1"},
		{"a_id": "v2", "b_id": "g2", "winner_id": "v2"}]]
	var bf := FileAccess.open("user://test_event_groups/TCG.json",
		FileAccess.WRITE)
	bf.store_string(JSON.stringify({"rounds": rounds}))
	bf.close()
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_event_groups"
	D.call("event_save", {"id": "ECG", "group_order": ["A"],
		"groups": {"A": {"bracket_id": "TCG"}}})
	# g1 is the worst ELO by far but green (2 career matches).
	var cards := {
		"v1": {"elo": 1500.0, "train": 80, "matches": 30},
		"v2": {"elo": 1400.0, "train": 80, "matches": 25},
		"g1": {"elo": 800.0, "train": 80, "matches": 2},
		"g2": {"elo": 1300.0, "train": 80, "matches": 1}}
	var cands: Dictionary = D.call("event_eliminate_candidates",
		"ECG", 10, 0.0, cards)
	_check(bool(cands.get("ok", false)), "career gate resolves")
	var order: Array = cands.get("candidates", [])
	_check(order == ["v2", "v1"], "veterans worst-first, green protected")
	# A cutoff only one veteran meets falls through to the full
	# experienced list (existing behavior, cutoff ignored when short).
	var cut: Dictionary = D.call("event_eliminate_candidates",
		"ECG", 10, 1450.0, cards)
	var corder: Array = cut.get("candidates", [])
	_check(corder == ["v2", "v1"], "short cut falls back to experienced")
	D.free()


func test_vault_draw_excludes_participants() -> void:
	# Promotion draws from the whole vault: qualified outsiders are
	# drawable, current-event players never (own advancement path),
	# undertrained never, ghosts never.
	DirAccess.make_dir_recursive_absolute("user://test_event_groups")
	var D = load("res://scripts/TournamentDirector.gd").new()
	D.tournament_dir = "user://test_event_groups"
	D.call("event_save", {"id": "EDRAW3", "group_order": ["A"],
		"groups": {"A": {"players": ["star"]}}, "pool": []})
	var roster := [{"id": "star"}, {"id": "out1"}, {"id": "out2"},
		{"id": "green"}]
	var cards := {
		"star": {"elo": 2000.0, "train": 80, "matches": 30},
		"out1": {"elo": 1200.0, "train": 60, "matches": 0},
		"out2": {"elo": 1200.0, "train": 60, "matches": 5},
		"green": {"elo": 1200.0, "train": 10, "matches": 0}}
	var q: Dictionary = D.call("event_draw_candidates", "EDRAW3", 50,
		0.0, cards, roster)
	var qual: Array = q.get("qualified", [])
	qual.sort()
	_check(qual == ["out1", "out2"], "only qualified outsiders qualify")
	seed(3)
	var draw: Dictionary = D.call("event_draw_pool", "EDRAW3", 2, 50,
		0.0, cards, roster)
	var drawn: Array = draw.get("drawn", [])
	drawn.sort()
	_check(drawn == ["out1", "out2"], "both outsiders promoted")
	D.free()


var _showcase_col := Color(0.35, 0.85, 1.0)


func _cyan_labels(node: Node) -> Array:
	var out: Array = []
	if node is Label:
		var c: Color = (node as Label).get_theme_color("font_color")
		if c == _showcase_col:
			out.append((node as Label).text)
	for ch in node.get_children():
		out += _cyan_labels(ch)
	return out


func test_showcase_sync() -> void:
	# Gallery sync: the showcased fighter's every bracket name paints
	# cyan (same color as the gallery title); clear restores base.
	var ps := _brains(4, 1500)
	D.call("build_bracket", ["f01", "f02", "f03", "f04"], 4, 1, 0.5,
		40.0, false, ps, false, false, false)
	var BB = load("res://scripts/TournamentBracket.gd").new()
	BB.call("render_bracket", D.tourney, -1, -1)
	_check(_cyan_labels(BB).is_empty(), "no showcase before set")
	BB.set_showcase("f01")
	_check(BB.showcase_applied() == "f01", "showcase key stored")
	var lit := _cyan_labels(BB)
	_check(not lit.is_empty(), "showcased name paints cyan")
	var hit := false
	for t in lit:
		if str(t).contains("F1"):
			hit = true
	_check(hit, "the right fighter lights up")
	BB.clear_showcase()
	_check(BB.showcase_applied() == "", "clear drops the key")
	_check(_cyan_labels(BB).is_empty(), "clear restores base colors")
	_check(BB.get("_show_rows").size() >= 2, "registry covers rows")
	BB.free()


func test_showcase_overview() -> void:
	# Overview quadrants (the intermission view): quadrant tables and
	# nested fixture rows join the sync, unknown keys no-op.
	var brains := _brains(4, 1500)
	D.call("build_group_bracket", brains, "A", "ESHOW", 1, 0.5, 40.0)
	D.call("on_battle_result", "alpha", {}, {}, {}, 1, 0)
	D.call("advance_after_match")
	var BB = load("res://scripts/TournamentBracket.gd").new()
	var st: Array = D.call("group_standings")
	var cell := {"letter": "A", "players": brains,
		"rounds": D.tourney.get("rounds", []), "standings": st,
		"is_current": true, "is_done": false, "bracket_id": "x",
		"cur_round": 0, "cur_match": 0}
	BB.call("render_event_groups",
		{"groups": [cell, cell, cell, cell], "current": "A"}, "A")
	BB.set_showcase("f02")
	var lit := _cyan_labels(BB)
	var hit := false
	for t in lit:
		if str(t).contains("F2"):
			hit = true
	_check(hit, "quadrant + fixtures light up")
	BB.set_showcase("nobody")
	_check(BB.showcase_applied() == "", "unknown key clears")
	BB.free()


func _fighter_rows_a(A) -> PackedStringArray:
	var rec := {"elo": 1350.0, "battles": 12, "wins": 7, "losses": 4,
		"draws": 1, "ko": 3, "wander": 2, "matches": 4,
		"matches_won": 3, "tournaments_won": 1}
	var gp := {"evasion": 0.2, "learning_rate": 0.008,
		"experiment": "retina_wide"}
	var lin := {"parent_ids": ["p1"], "source": "clone:x",
		"kin": 3, "jr": 0}
	var tr := {"episodes": 150}
	return A._format_fighter_rows(rec, gp, lin, tr, {"p1": "Kestrel"},
		{"spd": 4.2, "thr": 0.4, "hp": 82.0, "drift": 5.2},
		{"kills": 1}, 0)


func test_fighter_rows() -> void:
	# PiP stat rows: full words (no shorthand), identical order both
	# flies, pedigree/DNF/KO lines present.
	var A = load("res://scripts/ArenaManager.gd").new()
	var rows: PackedStringArray = _fighter_rows_a(A)
	var text := "\n".join(rows)
	for want in ["ELO 1350", "Battles: 12 (Wins 7, Losses 4)",
			"Did not finish: 1", "Knockouts: 3 (1 this match)",
			"Matches: 4 (Won 3), Titles: 1", "Schooling: 150 episodes",
			"Pedigree: clone of Kestrel (kin 3)",
			"Evasion: 0.20, Learning rate: 0.0080, Wiring: retina_wide",
			"Speed: 4.2, Thrust: 0.40, Health: 82",
			"Wandered: 2", "Beyond arena: 5.2 m"]:
		_check(text.contains(want), "row present: " + want)
	for gone in ["BTL", "MTCH", "EVA ", "THR ", "SPD ", " HP ", "MN ",
			"VS ", "LPLC2", "DN "]:
		_check(not text.contains(gone), "no shorthand: " + gone.strip_edges())
	# Both sides share shape: same row count, same label order.
	var rows_b: PackedStringArray = A._format_fighter_rows(
		{"elo": 1200.0, "battles": 1, "wins": 0, "losses": 1,
			"draws": 0, "ko": 0, "matches": 1, "matches_won": 0,
			"tournaments_won": 0},
		{"evasion": 0.1, "learning_rate": 0.005}, {"source": "evo-random"},
		{"episodes": 60}, {}, {"spd": 1.0, "thr": 0.2, "hp": 100.0},
		{"kills": 0}, 0)
	_check(rows.size() == rows_b.size(), "both flies same row count")
	var heads := []
	var heads_b := []
	for r in rows:
		heads.append(str(r).split(":")[0].split(" ")[0])
	for r in rows_b:
		heads_b.append(str(r).split(":")[0].split(" ")[0])
	_check(heads == heads_b, "both flies same row order")
	var text_b := "\n".join(rows_b)
	_check(text_b.contains("Pedigree: wild"), "wild pedigree reads clean")
	A.free()


func test_fighter_rows_pedigrees() -> void:
	# Pedigree line across sources: junior, crossover, reference,
	# generated, and unknown.
	var A = load("res://scripts/ArenaManager.gd").new()
	var cases := [
		[{"source": "clone:x", "parent_ids": ["p1"], "kin": 0, "jr": 2},
			{"p1": "Base"}, "junior of Base (junior 2)"],
		[{"source": "crossover:axb", "parent_ids": ["a", "b"], "jr": 1},
			{"a": "Al", "b": "Be"}, "crossover Al x Be (junior 1)"],
		[{"source": "reference", "parent_ids": []},
			{}, "reference stock"],
		[{"source": "generated", "parent_ids": []},
			{}, "generated"],
		[{}, {}, "generated"]]
	for c in cases:
		var rows: PackedStringArray = A._format_fighter_rows(
			{"elo": 1200.0}, {}, c[0], {"episodes": 0}, c[1],
			{"spd": 0.0, "thr": 0.0, "hp": 100.0}, {"kills": 0}, 0)
		var found := false
		for r in rows:
			if str(r) == "Pedigree: " + str(c[2]):
				found = true
		_check(found, "pedigree reads: " + str(c[2]))
	A.free()


func test_wander_dock() -> void:
	# Overtime dock: 4 HP per drift meter, cap 50, floor zero.
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(A._wander_dock(0.0) == 0.0, "no drift docks nothing")
	_check(absf(A._wander_dock(2.5) - 10.0) < 0.001, "2.5 m docks 10 HP")
	_check(absf(A._wander_dock(10.0) - 40.0) < 0.001, "10 m docks 40 HP")
	_check(absf(A._wander_dock(12.5) - 50.0) < 0.001, "12.5 m hits the cap")
	_check(absf(A._wander_dock(25.0) - 50.0) < 0.001, "cap holds past leash")
	_check(absf(A._wander_dock(-3.0) - 0.0) < 0.001, "negative clamps zero")
	# Chase exemption: engaged flies read zero even outside the ring;
	# separated flies keep their own overshoot; unknown reads exempt.
	var g1: Array = A.call("_gate_drift", 12.0, 9.0, 5.0)
	_check(float(g1[0]) == 0.0 and float(g1[1]) == 0.0, "chase out together docks nothing")
	var g2: Array = A.call("_gate_drift", 12.0, 0.0, 40.0)
	_check(float(g2[0]) == 12.0 and float(g2[1]) == 0.0, "lone runner keeps drift")
	var g3: Array = A.call("_gate_drift", 12.0, 9.0, 8.0)
	_check(float(g3[0]) == 0.0 and float(g3[1]) == 0.0, "boundary still engaged")
	var g4: Array = A.call("_gate_drift", 12.0, 9.0, -1.0)
	_check(float(g4[0]) == 12.0 and float(g4[1]) == 9.0, "unknown separation keeps drift")
	_check(float(A.call("_flat_separation")) < 0.0, "bare flies read unknown")
	A.free()


func test_timeout_winner() -> void:
	# Timeout decided by remaining health: most health wins no matter
	# what dented the loser (tree rams included); within half a point
	# is a tie for the overtime ladder. No server verdict needed.
	var A = load("res://scripts/ArenaManager.gd").new()
	_check(A._timeout_winner(100.0, 100.0) == "draw", "untouched is a tie")
	_check(A._timeout_winner(80.0, 80.0) == "draw", "equal damage is a tie")
	_check(A._timeout_winner(80.0, 79.6) == "draw", "sub-point gap is a tie")
	_check(A._timeout_winner(80.0, 79.5) == "alpha", "half point decides")
	_check(A._timeout_winner(30.0, 90.0) == "beta", "most health wins")
	A.free()


func _momentum_pair() -> Array:
	# Two flies with opposing momenta; returns [a, b] instances.
	var a = load("res://scripts/FlyPhysics.gd").new()
	var b = load("res://scripts/FlyPhysics.gd").new()
	a.velocity = Vector3(8.0, 0, 0)
	b.velocity = Vector3(-4.0, 0, 0)
	return [a, b]


func test_clash_momentum_exchange() -> void:
	var pair := _momentum_pair()
	var a: Node3D = pair[0]
	var b: Node3D = pair[1]
	var p_before: Vector3 = a.velocity + b.velocity
	a.call("_exchange_momentum", a, b, Vector3(1.0, 0, 0), 0.4)
	var p_after: Vector3 = a.velocity + b.velocity
	_check(absf(p_before.x - p_after.x) < 0.001, "pair momentum conserved")
	_check(a.velocity.x < 8.0, "attacker loses axial momentum")
	_check(b.velocity.x > -4.0, "braced side gains axial momentum")


func _initialize() -> void:
	_setup()
	test_snake_draft()
	test_draw_break_stamp()
	test_prior_wins_and_split()
	test_clash_momentum_exchange()
	test_schedule_and_ko()
	test_ko_tiebreak()
	test_final_fixed_order()
	test_event_chain()
	test_overview_render()
	test_prebuilt_overview()
	test_cutoff_and_weighted_draw()
	test_topup_pick()
	test_bracket_close_toggle()
	test_next_group_sequence()
	test_slowmo_safety()
	test_gallery_cache_key()
	test_soften_worker_noop()
	test_pip_slot_defaults()
	test_pip_slot_cycle()
	test_roster_cache()
	test_spawn_hold()
	test_worker_affinity_mask()
	test_live_cards_use_cache()
	test_event_manifest_cache()
	test_battle_invalidate_primitive()
	test_poll_emit_no_flicker()
	test_booster_rule()
	test_booster_queue()
	test_draw_title_dnf()
	test_train_hud_parts()
	test_countdown_gates()
	test_handoff_prebuild_all_groups()
	test_eliminate_green_roster()
	test_preload_and_peek()
	test_match_batch_flow()
	test_motor_debug()
	test_arena_session_log()
	test_eliminate_career_gate()
	test_vault_draw_excludes_participants()
	test_showcase_sync()
	test_showcase_overview()
	test_fighter_rows()
	test_fighter_rows_pedigrees()
	test_wander_dock()
	test_timeout_winner()
	_cleanup()
	if failures == 0:
		print("ALL EVENT-GROUP TESTS PASSED")
	else:
		printerr("EVENT-GROUP TESTS: %d FAILURES" % failures)
	quit(failures)
