extends SceneTree
## Waiting-room showcase tests: training placeholders, bracket spotlight,
## and enriched gallery cards (stats + traits + inheritance).
## Run: godot --headless --path arena -s tests/test_nextgen_showcase.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _match(a_id: String, a_name: String, b_id: String, b_name: String) -> Dictionary:
	return {"a_id": a_id, "a_name": a_name, "b_id": b_id, "b_name": b_name,
		"bye": false, "vacant": false, "wins_a": 0, "wins_b": 0,
		"draws": 0, "winner_id": "", "battles": 0}


func _row_texts(card: PanelContainer) -> Array:
	# [head, name_a, score_a, name_b, score_b] label texts.
	var vb: VBoxContainer = card.get_child(0)
	var rows: Array = []
	for ch in vb.get_children():
		if ch is HBoxContainer:
			rows.append(ch)
	var out: Array = [(vb.get_child(0) as Label).text]
	for r in rows:
		out.append((r.get_child(0) as Label).text)
		out.append((r.get_child(1) as Label).text)
	return out


func _border(card: PanelContainer) -> Color:
	var sb := card.get_theme_stylebox("panel") as StyleBoxFlat
	return sb.border_color


func test_placeholder_row() -> void:
	var B = load("res://scripts/TournamentBracket.gd").new()
	var card: PanelContainer = B.call("_make_match_card",
		_match("abc12345", "Mottled_G4", "offspring:wild", "wild G15 (training)"),
		0, 0, false, false)
	var t := _row_texts(card)
	_check(t[1] == "Mottled_G4", "real fighter row untouched")
	_check(t[3] == "wild G15 (training) · TRAINING", "placeholder row tagged TRAINING")
	_check(t[4] == "…", "placeholder score is ellipsis, not 0-0")
	_check(t[2] == "0", "real fighter score still numeric")
	B.free()


func test_spotlight() -> void:
	var B = load("res://scripts/TournamentBracket.gd").new()
	var preview := {"players": [], "size": 4, "rounds": [[
		_match("abc12345", "Mottled_G4", "offspring:wild", "wild G15 (training)"),
		_match("def67890", "Wasp_G5", "offspring:clone", "G15-Kin (training)")]]}
	B.call("render_bracket", preview, -1, -1)
	_check(B.call("spotlight_applied") == "", "no spotlight after render")
	B.call("set_spotlight", "offspring:wild")
	_check(B.call("spotlight_applied") == "offspring:wild", "spotlight key stored")
	var wild_card: PanelContainer = B.get("_spot_cards")["offspring:wild"]
	_check(_border(wild_card) == Color(1.0, 0.82, 0.3, 1.0), "spotlit card gold-framed")
	# "def67890" rides the OTHER match card (a card holds both its
	# fighters), so the first card must restore when the spotlight
	# leaves it.
	B.call("set_spotlight", "def67890")
	_check(B.call("spotlight_applied") == "def67890", "spotlight moves")
	_check(_border(wild_card) != Color(1.0, 0.82, 0.3, 1.0), "previous card restored")
	B.call("set_spotlight", "nope")
	_check(B.call("spotlight_applied") == "", "unknown key clears")
	B.call("set_spotlight", "offspring:clone")
	B.call("clear_spotlight")
	_check(B.call("spotlight_applied") == "", "clear empties spotlight")
	B.free()


func _fixture_rec() -> Dictionary:
	return {"id": "kid12345", "name": "G15-Slate_Cicada-kin3",
		"record": {"elo": 1312.0, "battles": 12, "wins": 7, "losses": 4,
			"draws": 1, "matches": 4, "matches_won": 3, "matches_lost": 1,
			"tournaments_won": 1},
		"training": {"episodes": 150, "score": 412.3},
		"generator_params": {"evasion": 0.46, "dist_gain": 0.15,
			"learning_rate": 0.008, "yaw_bias": [0.5, -0.2],
			"explore_mode": "novelty", "genome_id": "gf66baac62c",
			"mapping": [1, 2, 3], "yaw_blend": 0.45, "pitch_blend": 0.8},
		"lineage": {"parent_ids": ["par67890"], "source": "clone:par67890",
			"trait_mutations": {"evasion": [0.4, 0.46]},
			"training": {"episodes_total": 55, "stage_split": 0.42,
				"noise": 0.034, "max_changes": 0}}}


func test_gallery_real_card() -> void:
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("nextgen_brains", {"kid12345": _fixture_rec(),
		"par67890": {"id": "par67890", "name": "Mottled_G4"}})
	var card: Dictionary = A.call("_gallery_card", "kid12345", "G15-Slate_Cicada-kin3")
	_check(str(card.get("key", "")) == "kid12345", "gallery card carries bracket key")
	_check(str(card.get("elo", "")) == "1312", "elo shown")
	var rows := str(card.get("rows", ""))
	_check(rows.contains("Titles 1") and rows.contains("Matches 4 (W3 L1)"),
		"fight record stats present")
	_check(rows.contains("Episodes 150") and rows.contains("Score 412.3"),
		"schooling stats present")
	_check(rows.contains("genome gf66baac62c") and rows.contains("3 rules"),
		"wiring makeup present")
	_check(rows.contains("evasion 0.46") and rows.contains("lr 0.01"),
		"trait makeup present")
	_check(rows.contains("clone of Mottled_G4"),
		"inheritance names the parent")
	_check(rows.contains("evasion 0.40→0.46"), "trait mutations shown")
	_check(rows.contains("reared 55ep"), "training recipe shown")
	_check(rows.contains("ctl") and rows.contains("yaw 0.45"),
		"evolved reflex authority shown")
	A.free()


func test_gallery_training_card() -> void:
	var A = load("res://scripts/ArenaManager.gd").new()
	A.set("nextgen_brains", {})
	var card: Dictionary = A.call("_gallery_card", "offspring:wild",
		"wild G15 (training)")
	_check(str(card.get("title", "")).begins_with("NEW WILD"),
		"wild placeholder announces NEW WILD")
	_check(str(card.get("elo", "")) == "--", "placeholder has no elo")
	_check(str(card.get("rows", "")).contains("training"),
		"placeholder shows training status")
	_check(str(card.get("key", "")) == "offspring:wild",
		"placeholder carries its bracket key")
	var card2: Dictionary = A.call("_gallery_card", "offspring:clone", "G15-Kin")
	_check(str(card2.get("title", "")).begins_with("NEW BREED"),
		"clone placeholder announces NEW BREED")
	A.free()


func _initialize() -> void:
	test_placeholder_row()
	test_spotlight()
	test_gallery_real_card()
	test_gallery_training_card()
	if failures == 0:
		print("ALL NEXTGEN-SHOWCASE TESTS PASSED")
	else:
		printerr("NEXTGEN-SHOWCASE TESTS: %d FAILURES" % failures)
	quit(failures)
