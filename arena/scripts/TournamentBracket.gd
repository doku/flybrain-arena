class_name TournamentBracket
extends Control
## Visual single-elimination bracket: one column per round, match cards with
## per-player scores, connector elbows showing who advanced, eliminated
## players grayed out, live match gold-bordered, champion node at the end.
## Used by the vault menu and the arena overlay. Pure layout + _draw lines.

# Layout metrics (vars, not consts): render_bracket picks the normal or
# compact set by bracket size, so small brackets stay readable while big
# ones fit without scrolling. Always edit via _apply_metrics().
var CARD_W := 210.0
var CARD_H := 92.0
var GAP_X := 52.0
var ROW_GAP := 16.0
var CARD_PAD := 6.0
var CARD_SEP := 2
var ROW_H := 24.0
const TOP_PAD := 32.0
const SIDE_PAD := 12.0
# Font sizes paired with the metrics above.
var FS_COL_HEAD := 15
var FS_CARD_HEAD := 12
var FS_ROW := 15
var FS_BIG_NAME := 19

const COL_LINE := Color(0.62, 0.62, 0.68, 0.85)
const COL_LIVE := Color(1.0, 0.82, 0.3, 1.0)
const COL_WIN := Color(0.5, 1.0, 0.55)
const COL_LOSE := Color(0.42, 0.42, 0.46)
const COL_TBD := Color(0.55, 0.55, 0.6)
const COL_CHAMP := Color(1.0, 0.85, 0.35)
const COL_LOSER := Color(1.0, 0.35, 0.3)
const COL_LOSER_DIM := Color(0.75, 0.3, 0.28, 0.85)

var segments: Array = []
# View-relative losers start for _round_name (0 in losers-focus mode).
var _lf_view := -1
# Gallery spotlight (waiting-room preview): bracket key (fighter id or
# "offspring:<kind>" placeholder) -> its round-0 card. Orthogonal to the
# live/decided borders; cleared on every re-render.
var spotlight_key := ""
var _spot_cards := {}
const SPOT_PREFIX := "offspring:"


## View modes: 0 = auto (focus-swap while live losers run, main
## bracket only at review - the appended losers rounds jumble the
## single-elim layout), 1 = main bracket only, 2 = losers bracket
## only (forced focus rendering, works at review time too), 3 = group
## fixture (round-robin rounds as plain columns: no TBD synthesis, no
## connectors, no champion node, plain ROUND headers).
func render_bracket(tourney: Dictionary, cur_round: int = -1, cur_match: int = -1, view: int = 0) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	segments.clear()
	_spot_cards.clear()
	spotlight_key = ""
	var rounds: Array = tourney.get("rounds", [])
	var losers_from := int(tourney.get("losers_start_round", -1))
	if rounds.is_empty() or (view == 2 and (losers_from < 0 or losers_from >= rounds.size())):
		var ph := Label.new()
		ph.text = "No losers bracket." if view == 2 else "No tournament."
		ph.position = Vector2(SIDE_PAD, SIDE_PAD)
		add_child(ph)
		custom_minimum_size = Vector2(200, 60)
		size = custom_minimum_size
		queue_redraw()
		return
	# Focus mode: while live losers rounds are playing (and the
	# tournament is still running), the losers bracket REPLACES the main
	# one - 2-3 narrow columns instead of 6+, so it fits on screen.
	# At review time (complete) the full bracket comes back (auto view).
	var focus := losers_from > 0 and cur_round >= losers_from \
		and str(tourney.get("status", "")) == "running"
	var shown: Array = rounds.duplicate()
	if view == 0 and str(tourney.get("status", "")) != "running":
		# Review time: auto view shows the winners' bracket only.
		view = 1
	if view == 1 and losers_from > 0:
		# Main page: losers live on their own view, never appended here
		# (and never focus-swapped in, even while consolation is live).
		shown = shown.slice(0, losers_from)
		losers_from = -1
		focus = false
	elif view == 2:
		# Losers page: force focus rendering at any status.
		focus = true
	if focus:
		shown = shown.slice(losers_from)
		cur_round = cur_round - losers_from
		losers_from = 0
	if shown.is_empty():
		var ph2 := Label.new()
		ph2.text = "No tournament."
		ph2.position = Vector2(SIDE_PAD, SIDE_PAD)
		add_child(ph2)
		custom_minimum_size = Vector2(200, 60)
		size = custom_minimum_size
		queue_redraw()
		return
	_lf_view = losers_from
	var group_mode := view == 3
	# TBA templates (display-only, never written back): synthesize future
	# main rounds from tournament size, and future losers rounds by
	# halving, so the whole bracket is visible before matches resolve.
	# Group fixtures are complete schedules: nothing is synthesized.
	if group_mode:
		pass
	elif focus:
		while (shown[shown.size() - 1] as Array).size() > 1:
			var _prev2: Array = shown[shown.size() - 1]
			shown.append(_tbd_round(maxi(1, int(ceil(float(_prev2.size()) / 2.0)))))
	else:
		var size_n := maxi(2, int(tourney.get("size", 4)))
		var main_expected := 0
		var _s := size_n
		while _s > 1:
			main_expected += 1
			_s = int(_s / 2)
		var main_have: int = losers_from if losers_from >= 0 else rounds.size()
		while shown.size() < main_expected:
			var _prev: Array = shown[shown.size() - 1]
			shown.append(_tbd_round(maxi(1, int(ceil(float(_prev.size()) / 2.0)))))
		if losers_from >= 0:
			while (shown[shown.size() - 1] as Array).size() > 1:
				var _prev3: Array = shown[shown.size() - 1]
				shown.append(_tbd_round(maxi(1, int(ceil(float(_prev3.size()) / 2.0)))))
	rounds = shown
	var n_rounds: int = rounds.size()
	var cols: int = n_rounds if group_mode else n_rounds + 1
	_apply_metrics(cols, (rounds[0] as Array).size(), group_mode)
	# Column x positions.
	var xs: Array = []
	for i in range(cols):
		xs.append(SIDE_PAD + i * (CARD_W + GAP_X))
	# Round header labels. Focus mode's final column is LAST PLACE.
	for i in range(n_rounds):
		add_child(_make_header(str(xs[i]), _round_name(i, n_rounds, tourney)))
	if not group_mode:
		add_child(_make_header(str(xs[n_rounds]), "LAST PLACE" if focus else "CHAMPION"))
	# Card tops per round for feeder-centering (group fixtures stack
	# every round straight: columns are fixtures, not progression).
	var tops: Array = []
	for r in range(n_rounds):
		var rtops: Array = []
		var rms: Array = rounds[r]
		if r == 0 or group_mode:
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
	# Cards. In losers rounds the loser advances (green = advances in
	# every column; the winner is out and greyed like any eliminated).
	for r in range(n_rounds):
		var rms2: Array = rounds[r]
		var loser_adv: bool = losers_from >= 0 and r >= losers_from
		for mi in range(rms2.size()):
			var m: Dictionary = rms2[mi]
			var live: bool = (r == cur_round and mi == cur_match)
			var card := _make_match_card(m, r, mi, live, loser_adv)
			card.position = Vector2(float(xs[r]), float(tops[r][mi]))
			add_child(card)
			if r == 0:
				_register_spot(m, "a", card)
				_register_spot(m, "b", card)
	# Connectors from feeders into each later-round match. Edges
	# landing in losers rounds draw muted red (distinct consolation).
	# Group fixtures imply no progression, so they draw none.
	for r in range(1, n_rounds):
		if group_mode:
			break
		var rms3: Array = rounds[r]
		var prev2: Array = tops[r - 1]
		var loser_edge := losers_from >= 0 and r >= losers_from
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
				segments.append({"a": Vector2(fx, fcy), "b": Vector2(mid_x, fcy), "live": live2, "loser": loser_edge})
				segments.append({"a": Vector2(mid_x, fcy), "b": Vector2(mid_x, mcy), "live": live2, "loser": loser_edge})
				segments.append({"a": Vector2(mid_x, mcy), "b": Vector2(mx, mcy), "live": live2, "loser": loser_edge})
	# Champion node centered on the main final; with consolation, a
	# LAST PLACE node hangs off the losers final in red. Focus mode
	# skips the champion (main bracket hidden) and the final column
	# carries LAST PLACE alone. Group fixtures crown nobody.
	if group_mode:
		pass
	elif focus:
		var f_tops: Array = tops[n_rounds - 1]
		var f_mid: float = float(f_tops[f_tops.size() - 1]) + CARD_H * 0.5
		var flast := _make_last_place_card(_last_place_name(tourney), tourney)
		flast.position = Vector2(float(xs[n_rounds]), f_mid - CARD_H * 0.5)
		add_child(flast)
		var fx0: float = float(xs[n_rounds - 1]) + CARD_W
		segments.append({"a": Vector2(fx0, f_mid), "b": Vector2(float(xs[n_rounds]), f_mid), "live": false, "loser": true})
	else:
		var champ_name := _champion_name(tourney)
		var champ_mid: float
		if losers_from > 0:
			var main_final: Array = tops[losers_from - 1]
			champ_mid = float(main_final[main_final.size() - 1]) + CARD_H * 0.5
		else:
			var final_tops: Array = tops[n_rounds - 1]
			champ_mid = float(final_tops[final_tops.size() - 1]) + CARD_H * 0.5
		var champ := _make_champ_card(champ_name, tourney)
		champ.position = Vector2(float(xs[n_rounds]), champ_mid - CARD_H * 0.5)
		add_child(champ)
		var cfx0: float
		if losers_from > 0:
			cfx0 = float(xs[losers_from - 1]) + CARD_W
		else:
			cfx0 = float(xs[n_rounds - 1]) + CARD_W
		segments.append({"a": Vector2(cfx0, champ_mid), "b": Vector2(float(xs[n_rounds]), champ_mid), "live": false})
		if losers_from > 0:
			var l_tops: Array = tops[n_rounds - 1]
			var l_mid: float = float(l_tops[l_tops.size() - 1]) + CARD_H * 0.5
			var last := _make_last_place_card(_last_place_name(tourney), tourney)
			last.position = Vector2(float(xs[n_rounds]), l_mid - CARD_H * 0.5)
			add_child(last)
			var lx0: float = float(xs[n_rounds - 1]) + CARD_W
			segments.append({"a": Vector2(lx0, l_mid), "b": Vector2(float(xs[n_rounds]), l_mid), "live": false, "loser": true})
	# Size for scroll containers.
	var n0: Array = rounds[0]
	var height: float = TOP_PAD + n0.size() * (CARD_H + ROW_GAP) + SIDE_PAD
	var last_x: float = float(xs[n_rounds - 1]) if group_mode else float(xs[n_rounds])
	custom_minimum_size = Vector2(last_x + CARD_W + SIDE_PAD, height)
	size = custom_minimum_size
	queue_redraw()


func _register_spot(m: Dictionary, slot: String, card: PanelContainer) -> void:
	# Round-0 slots register under fighter id or placeholder key so the
	# gallery can spotlight them later. TBD/vacant slots have no key.
	var key := str(m.get("a_id" if slot == "a" else "b_id", ""))
	var nm := str(m.get("a_name" if slot == "a" else "b_name", ""))
	if key == "" or nm == "" or nm == "TBD":
		return
	_spot_cards[key] = card


func set_spotlight(key: String) -> void:
	# Gold-frames one round-0 card (the gallery's showcased fighter);
	# no-op for unknown keys. Re-callers re-render first, which clears.
	if key == spotlight_key:
		return
	clear_spotlight()
	if key == "" or not _spot_cards.has(key):
		return
	spotlight_key = key
	_paint_card(_spot_cards[key], COL_LIVE, 3)


func clear_spotlight() -> void:
	if spotlight_key != "" and _spot_cards.has(spotlight_key):
		var card: PanelContainer = _spot_cards[spotlight_key]
		var base: Color = card.get_meta("base_border")
		_paint_card(card, base, int(card.get_meta("base_bw")))
	spotlight_key = ""


func spotlight_applied() -> String:
	return spotlight_key


func _paint_card(card: PanelContainer, border: Color, bw: int) -> void:
	# Mutates the card's own StyleBoxFlat (each card gets a fresh one
	# in _card_panel, so neighbors are untouched).
	var sb := card.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		return
	sb.border_color = border
	sb.set_border_width_all(bw)


func render_event_groups(data: Dictionary, current: String = "") -> void:
	# 2x2 event overview: A|B over C|D. Each quadrant shows its group
	# header, standings rows (W-L, KO, top-2 starred) and pairing rows
	# with battle scores. The live pairing is gold-framed, the current
	# group gold-bordered; finished groups dim. Display-only.
	for c in get_children():
		remove_child(c)
		c.queue_free()
	segments.clear()
	_spot_cards.clear()
	spotlight_key = ""
	_apply_metrics(4, 4)
	var groups: Array = data.get("groups", [])
	if groups.size() != 4:
		var ph := Label.new()
		ph.text = "No event."
		ph.position = Vector2(SIDE_PAD, SIDE_PAD)
		add_child(ph)
		custom_minimum_size = Vector2(200, 60)
		size = custom_minimum_size
		queue_redraw()
		return
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(grid)
	for r in range(2):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		grid.add_child(row)
		for k in range(2):
			row.add_child(_make_group_panel(groups[r * 2 + k], current))
	custom_minimum_size = Vector2(760, 560)
	size = custom_minimum_size
	queue_redraw()


func _make_group_panel(cell: Dictionary, current: String) -> PanelContainer:
	var letter := str(cell.get("letter", "?"))
	var is_current := letter == current
	var is_done := bool(cell.get("is_done", false))
	var border := Color(0.3, 0.3, 0.36)
	var bw := 1
	if is_current:
		border = COL_LIVE
		bw = 3
	var card := _card_panel(border, bw)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", CARD_SEP)
	card.add_child(vb)
	var head := Label.new()
	var htxt := "GROUP %s" % letter
	if is_current:
		htxt += "  •  LIVE"
	elif is_done:
		htxt += "  •  FINAL"
	head.text = htxt
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", FS_CARD_HEAD + 2)
	head.add_theme_color_override("font_color",
		COL_LIVE if is_current else (Color(0.55, 0.55, 0.6) if is_done else Color(0.75, 0.75, 0.8)))
	vb.add_child(head)
	var i := 0
	for srow in (cell.get("standings", []) as Array):
		i += 1
		var rd := srow as Dictionary
		var sl := Label.new()
		sl.text = "%s%d. %s  %dW-%d  KO%d" % [
			"★" if i <= 2 else "  ", i, str(rd.get("name", "?")),
			int(rd.get("wins", 0)),
			int(rd.get("matches", 0)) - int(rd.get("wins", 0)),
			int(rd.get("kos", 0))]
		sl.add_theme_font_size_override("font_size", FS_ROW)
		sl.clip_text = true
		sl.add_theme_color_override("font_color",
			Color(0.5, 0.5, 0.55) if (is_done and i > 2) else Color(0.92, 0.92, 0.94))
		vb.add_child(sl)
	# Fixture cards: the group's own rounds in group view mode (real
	# versus cards with live/result coloring, no finals, no champion).
	var mini := {"rounds": cell.get("rounds", []),
		"players": cell.get("players", []), "size": 4, "format": "groups",
		"status": "running", "quick": false}
	# Self-instantiation (class_name is unresolvable inside its own
	# script at compile time): load the script resource instead.
	var sub = load("res://scripts/TournamentBracket.gd").new()
	sub.render_bracket(mini, int(cell.get("cur_round", -1)),
		int(cell.get("cur_match", -1)), 3)
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(sub)
	return card


func _draw() -> void:
	for s in segments:
		var col: Color = COL_LIVE if bool(s.get("live", false)) else COL_LINE
		if bool(s.get("loser", false)) and not bool(s.get("live", false)):
			col = COL_LOSER_DIM
		draw_line(s["a"], s["b"], col, 2.0)


func _round_name(r: int, n_rounds: int, tourney: Dictionary) -> String:
	if str(tourney.get("format", "")) == "groups":
		return "ROUND %d" % (r + 1)
	var losers_from := _lf_view
	if losers_from >= 0 and r >= losers_from:
		if r == n_rounds - 1:
			return "LOSERS FINAL"
		return "LOSERS R%d" % (r - losers_from + 1)
	if bool(tourney.get("quick", false)):
		return "FINAL" if n_rounds == 1 else ("ROUND %d" % (r + 1))
	if r == n_rounds - 1 and n_rounds > 1:
		return "FINAL"
	if r == n_rounds - 2 and n_rounds > 2:
		return "SEMIFINAL"
	return "ROUND %d" % (r + 1)


func _last_place_name(tourney: Dictionary) -> String:
	var lid := str(tourney.get("last_place_id", ""))
	if lid == "":
		return "TBD"
	for p in tourney.get("players", []):
		if str(p.get("id", "")) == lid:
			return str(p.get("name", "?"))
	return "?"


func _make_last_place_card(last_name: String, tourney: Dictionary) -> PanelContainer:
	var decided: bool = str(tourney.get("last_place_id", "")) != ""
	var card := _card_panel(COL_LOSER if decided else Color(0.3, 0.3, 0.36), 2 if decided else 1)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)
	var head := Label.new()
	head.text = "LAST PLACE"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", FS_CARD_HEAD)
	head.add_theme_color_override("font_color", COL_LOSER if decided else Color(0.6, 0.6, 0.65))
	vb.add_child(head)
	var nm := Label.new()
	nm.text = last_name
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.clip_text = true
	nm.add_theme_font_size_override("font_size", FS_BIG_NAME)
	nm.add_theme_color_override("font_color", COL_LOSER if decided else COL_TBD)
	vb.add_child(nm)
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size = card.custom_minimum_size
	return card


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
	l.add_theme_font_size_override("font_size", FS_COL_HEAD)
	l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	l.position = Vector2(float(x), 6.0)
	l.custom_minimum_size = Vector2(CARD_W, 22.0)
	return l


func _card_panel(border: Color, border_w: int) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.11, 0.88)
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = CARD_PAD
	sb.content_margin_bottom = CARD_PAD
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(CARD_W, CARD_H)
	pc.size = Vector2(CARD_W, CARD_H)
	return pc


func _apply_metrics(cols: int, rows0: int, group_mode: bool = false) -> void:
	# Normal metrics up to 3 columns / 3 rows (size 4); compact beyond.
	# Group fixtures render 3 columns inside event-overview quadrants,
	# so they take the compact set to fit 2-up.
	# Compact CARD_H must clear the card content (~56px: 3+3 margins +
	# header + separation + two 18px rows) or text spills into the
	# neighbor card. Compact pitch is 70px/card, so a size-8 first
	# round (4 cards) fits in 324px without scrolling.
	if cols > 3 or rows0 > 3 or group_mode:
		CARD_W = 108.0
		CARD_H = 64.0
		GAP_X = 16.0
		ROW_GAP = 6.0
		CARD_PAD = 3.0
		CARD_SEP = 1
		ROW_H = 18.0
		FS_COL_HEAD = 12
		FS_CARD_HEAD = 10
		FS_ROW = 10
		FS_BIG_NAME = 14
	else:
		CARD_W = 190.0
		CARD_H = 88.0
		GAP_X = 40.0
		ROW_GAP = 16.0
		CARD_PAD = 5.0
		CARD_SEP = 2
		ROW_H = 24.0
		FS_COL_HEAD = 15
		FS_CARD_HEAD = 12
		FS_ROW = 15
		FS_BIG_NAME = 19


func _tbd_round(count: int) -> Array:
	# Placeholder future round: TBD cards (never vacant, so rows read
	# "TBD" and headers stay plain). Display-only; see render_bracket.
	var out: Array = []
	for i in range(count):
		out.append({"a_id": "", "b_id": "", "a_name": "TBD", "b_name": "TBD",
			"bye": false, "vacant": false, "wins_a": 0, "wins_b": 0,
			"draws": 0, "winner_id": "", "battles": 0, "tbd": true})
	return out


func _make_match_card(m: Dictionary, r: int, mi: int, live: bool, loser_adv: bool = false) -> PanelContainer:
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
	card.set_meta("base_border", border)
	card.set_meta("base_bw", bw)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", CARD_SEP)
	card.add_child(vb)
	var head := Label.new()
	var htxt := "R%d · M%d" % [r + 1, mi + 1]
	if live:
		htxt += "  •  LIVE"
	elif bye:
		htxt += "  •  BYE"
	elif vacant:
		htxt += "  •  VACANT"
	elif bool(m.get("skipped", false)):
		htxt += "  •  SKIP"
	elif loser_adv:
		htxt += "  •  LOSER ADV"
	head.text = htxt
	head.add_theme_font_size_override("font_size", FS_CARD_HEAD)
	head.add_theme_color_override("font_color", COL_LIVE if live else Color(0.6, 0.6, 0.65))
	vb.add_child(head)
	var wa: int = int(m.get("wins_a", 0))
	var wb: int = int(m.get("wins_b", 0))
	vb.add_child(_make_row(str(m.get("a_name", "TBD")), wa, m, "a", live, decided, loser_adv))
	vb.add_child(_make_row(str(m.get("b_name", "TBD")), wb, m, "b", live, decided, loser_adv))
	return card


func _make_row(pname: String, score: int, m: Dictionary, slot: String, live: bool, decided: bool, loser_adv: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var nm := Label.new()
	var vacant: bool = bool(m.get("vacant", false))
	# Unbred offspring ride synthetic "offspring:<kind>" ids (preview
	# only): dim TRAINING rows that can never read as banked fighters.
	var training: bool = str(m.get("a_id" if slot == "a" else "b_id", "")) \
		.begins_with(SPOT_PREFIX)
	var label := "-" if vacant else (pname if pname != "" else "TBD")
	if training and not vacant:
		label += " · TRAINING"
	nm.text = label
	nm.clip_text = true
	nm.custom_minimum_size = Vector2(CARD_W - 60.0, ROW_H)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.add_theme_font_size_override("font_size", FS_ROW)
	var col := Color(0.92, 0.92, 0.94)
	if vacant:
		col = Color(0.28, 0.28, 0.32)
	elif training:
		col = Color(0.78, 0.72, 0.55)
	elif pname == "" or pname == "TBD":
		col = COL_TBD
	elif decided:
		var won: bool = str(m.get("winner_id", "")) == str(m.get("a_id" if slot == "a" else "b_id", ""))
		if loser_adv:
			col = COL_LOSE if won else COL_WIN
		else:
			col = COL_WIN if won else COL_LOSE
	nm.add_theme_color_override("font_color", col)
	row.add_child(nm)
	var sc := Label.new()
	sc.text = "…" if training else str(score)
	sc.add_theme_font_size_override("font_size", FS_ROW)
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
	head.add_theme_font_size_override("font_size", FS_CARD_HEAD)
	head.add_theme_color_override("font_color", COL_CHAMP if decided else Color(0.6, 0.6, 0.65))
	vb.add_child(head)
	var nm := Label.new()
	nm.text = champ_name
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.clip_text = true
	nm.add_theme_font_size_override("font_size", FS_BIG_NAME)
	nm.add_theme_color_override("font_color", COL_CHAMP if decided else COL_TBD)
	vb.add_child(nm)
	return card
