class_name TournamentBracket
extends Control
## Visual single-elimination bracket: one column per round, match cards with
## per-player scores, connector elbows showing who advanced, eliminated
## players grayed out, live match gold-bordered, champion node at the end.
## Used by the vault menu and the arena overlay. Pure layout + _draw lines.

const CARD_W := 210.0
const CARD_H := 92.0
const GAP_X := 52.0
const ROW_GAP := 16.0
const TOP_PAD := 32.0
const SIDE_PAD := 12.0

const COL_LINE := Color(0.62, 0.62, 0.68, 0.85)
const COL_LIVE := Color(1.0, 0.82, 0.3, 1.0)
const COL_WIN := Color(0.5, 1.0, 0.55)
const COL_LOSE := Color(0.42, 0.42, 0.46)
const COL_TBD := Color(0.55, 0.55, 0.6)
const COL_CHAMP := Color(1.0, 0.85, 0.35)

var segments: Array = []


func render_bracket(tourney: Dictionary, cur_round: int = -1, cur_match: int = -1) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	segments.clear()
	var rounds: Array = tourney.get("rounds", [])
	if rounds.is_empty():
		var ph := Label.new()
		ph.text = "No tournament."
		ph.position = Vector2(SIDE_PAD, SIDE_PAD)
		add_child(ph)
		custom_minimum_size = Vector2(200, 60)
		size = custom_minimum_size
		queue_redraw()
		return
	var n_rounds: int = rounds.size()
	var cols: int = n_rounds + 1  # + champion column
	# Column x positions.
	var xs: Array = []
	for i in range(cols):
		xs.append(SIDE_PAD + i * (CARD_W + GAP_X))
	# Round header labels.
	for i in range(n_rounds):
		add_child(_make_header(str(xs[i]), _round_name(i, n_rounds, tourney)))
	add_child(_make_header(str(xs[n_rounds]), "CHAMPION"))
	# Card tops per round for feeder-centering.
	var tops: Array = []
	for r in range(n_rounds):
		var rtops: Array = []
		var rms: Array = rounds[r]
		if r == 0:
			for mi in range(rms.size()):
				rtops.append(TOP_PAD + mi * (CARD_H + ROW_GAP))
		else:
			var prev: Array = tops[r - 1]
			for mi in range(rms.size()):
				var f0: int = mi * 2
				var f1: int = mi * 2 + 1
				var y0: float = float(prev[f0]) if f0 < prev.size() else TOP_PAD + f0 * (CARD_H + ROW_GAP)
				var y1: float = float(prev[f1]) if f1 < prev.size() else y0 + CARD_H + ROW_GAP
				rtops.append((y0 + y1) * 0.5)
		tops.append(rtops)
	# Cards.
	for r in range(n_rounds):
		var rms2: Array = rounds[r]
		for mi in range(rms2.size()):
			var m: Dictionary = rms2[mi]
			var live: bool = (r == cur_round and mi == cur_match)
			var card := _make_match_card(m, r, mi, live)
			card.position = Vector2(float(xs[r]), float(tops[r][mi]))
			add_child(card)
	# Connectors from feeders into each later-round match.
	for r in range(1, n_rounds):
		var rms3: Array = rounds[r]
		var prev2: Array = tops[r - 1]
		for mi in range(rms3.size()):
			var live2: bool = (r == cur_round and mi == cur_match)
			var mx: float = float(xs[r])
			var mcy: float = float(tops[r][mi]) + CARD_H * 0.5
			var mid_x: float = float(xs[r - 1]) + CARD_W + GAP_X * 0.5
			for f in [mi * 2, mi * 2 + 1]:
				if f >= prev2.size():
					continue
				var fcy: float = float(prev2[f]) + CARD_H * 0.5
				var fx: float = float(xs[r - 1]) + CARD_W
				segments.append({"a": Vector2(fx, fcy), "b": Vector2(mid_x, fcy), "live": live2})
				segments.append({"a": Vector2(mid_x, fcy), "b": Vector2(mid_x, mcy), "live": live2})
				segments.append({"a": Vector2(mid_x, mcy), "b": Vector2(mx, mcy), "live": live2})
	# Champion node centered on the final.
	var champ_name := _champion_name(tourney)
	var final_tops: Array = tops[n_rounds - 1]
	var final_mid: float = float(final_tops[final_tops.size() - 1]) + CARD_H * 0.5
	var champ := _make_champ_card(champ_name, tourney)
	champ.position = Vector2(float(xs[n_rounds]), final_mid - CARD_H * 0.5)
	add_child(champ)
	var fx0: float = float(xs[n_rounds - 1]) + CARD_W
	segments.append({"a": Vector2(fx0, final_mid), "b": Vector2(float(xs[n_rounds]), final_mid), "live": false})
	# Size for scroll containers.
	var n0: Array = rounds[0]
	var height: float = TOP_PAD + n0.size() * (CARD_H + ROW_GAP) + SIDE_PAD
	custom_minimum_size = Vector2(float(xs[n_rounds]) + CARD_W + SIDE_PAD, height)
	size = custom_minimum_size
	queue_redraw()


func _draw() -> void:
	for s in segments:
		var col: Color = COL_LIVE if bool(s.get("live", false)) else COL_LINE
		draw_line(s["a"], s["b"], col, 2.0)


func _round_name(r: int, n_rounds: int, tourney: Dictionary) -> String:
	if bool(tourney.get("quick", false)):
		return "FINAL" if n_rounds == 1 else ("ROUND %d" % (r + 1))
	if r == n_rounds - 1 and n_rounds > 1:
		return "FINAL"
	if r == n_rounds - 2 and n_rounds > 2:
		return "SEMIFINAL"
	return "ROUND %d" % (r + 1)


func _champion_name(tourney: Dictionary) -> String:
	var cid := str(tourney.get("champion_id", ""))
	if cid == "":
		return "TBD"
	for p in tourney.get("players", []):
		if str(p.get("id", "")) == cid:
			return str(p.get("name", "?"))
	return "?"


func _make_header(x: String, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	l.position = Vector2(float(x), 6.0)
	l.custom_minimum_size = Vector2(CARD_W, 22.0)
	return l


func _card_panel(border: Color, border_w: int) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.11, 0.96)
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(CARD_W, CARD_H)
	pc.size = Vector2(CARD_W, CARD_H)
	return pc


func _make_match_card(m: Dictionary, r: int, mi: int, live: bool) -> PanelContainer:
	var decided: bool = str(m.get("winner_id", "")) != ""
	var bye: bool = bool(m.get("bye", false))
	var vacant: bool = bool(m.get("vacant", false))
	var border := Color(0.3, 0.3, 0.36)
	var bw := 1
	if live:
		border = COL_LIVE
		bw = 2
	elif decided:
		border = Color(0.35, 0.55, 0.38)
	var card := _card_panel(border, bw)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)
	var head := Label.new()
	var htxt := "R%d · M%d" % [r + 1, mi + 1]
	if live:
		htxt += "  •  LIVE"
	elif bye:
		htxt += "  •  BYE"
	elif vacant:
		htxt += "  •  VACANT"
	head.text = htxt
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", COL_LIVE if live else Color(0.6, 0.6, 0.65))
	vb.add_child(head)
	var wa: int = int(m.get("wins_a", 0))
	var wb: int = int(m.get("wins_b", 0))
	vb.add_child(_make_row(str(m.get("a_name", "TBD")), wa, m, "a", live, decided))
	vb.add_child(_make_row(str(m.get("b_name", "TBD")), wb, m, "b", live, decided))
	return card


func _make_row(pname: String, score: int, m: Dictionary, slot: String, live: bool, decided: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var nm := Label.new()
	var vacant: bool = bool(m.get("vacant", false))
	nm.text = "-" if vacant else (pname if pname != "" else "TBD")
	nm.clip_text = true
	nm.custom_minimum_size = Vector2(CARD_W - 60.0, 24.0)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.add_theme_font_size_override("font_size", 15)
	var col := Color(0.92, 0.92, 0.94)
	if vacant:
		col = Color(0.28, 0.28, 0.32)
	elif pname == "" or pname == "TBD":
		col = COL_TBD
	elif decided:
		var won: bool = str(m.get("winner_id", "")) == str(m.get("a_id" if slot == "a" else "b_id", ""))
		col = COL_WIN if won else COL_LOSE
	nm.add_theme_color_override("font_color", col)
	row.add_child(nm)
	var sc := Label.new()
	sc.text = str(score)
	sc.add_theme_font_size_override("font_size", 15)
	sc.add_theme_color_override("font_color", col)
	row.add_child(sc)
	return row


func _make_champ_card(champ_name: String, tourney: Dictionary) -> PanelContainer:
	var decided: bool = str(tourney.get("champion_id", "")) != ""
	var card := _card_panel(COL_CHAMP if decided else Color(0.3, 0.3, 0.36), 2 if decided else 1)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)
	var head := Label.new()
	head.text = "CHAMPION"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", COL_CHAMP if decided else Color(0.6, 0.6, 0.65))
	vb.add_child(head)
	var nm := Label.new()
	nm.text = champ_name
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.clip_text = true
	nm.add_theme_font_size_override("font_size", 19)
	nm.add_theme_color_override("font_color", COL_CHAMP if decided else COL_TBD)
	vb.add_child(nm)
	return card
