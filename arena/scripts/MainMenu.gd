extends Control
## Starting window: brain vault management + tournament setup/runner UI.
## All widgets built procedurally; heavy work (generate/train) runs in
## brain_engine/vault_cli.py via the TournamentDirector autoload.

const BracketView = preload("res://scripts/TournamentBracket.gd")

var brains: Array = []
var selected_brain: Dictionary = {}

var brain_list: ItemList
var detail_label: Label
var log_label: Label

var gen_name: LineEdit
var gen_variant: OptionButton
var gen_seed: SpinBox
var gen_lr: SpinBox
var gen_gain: SpinBox
var gen_evasion: SpinBox
var gen_experiment: OptionButton
var gen_map_checks: Array = []
var gen_episodes: SpinBox
var job_bar: ProgressBar
var job_label: Label

var tourney_size: OptionButton
var tourney_bestof: OptionButton
var tourney_lr: SpinBox
var tourney_round_time: SpinBox
var player_list: ItemList
var bracket_status: Label
var bracket_view: BracketView
var resume_button: Button
var quick_button: Button

var busy_overlay: ColorRect
var busy_label: Label
var busy_spinner: Label
var busy_frames: Array = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
var busy_tick: float = 0.0
var busy_frame: int = 0


func _ready() -> void:
	if OS.get_environment("FO_DIRECT") == "1":
		get_tree().change_scene_to_file.call_deferred("res://scenes/ArenaGlade.tscn")
		return
	_build_layout()
	_build_busy_overlay()
	TournamentDirector.vault_changed.connect(refresh_vault)
	TournamentDirector.job_progress.connect(_on_job_progress)
	TournamentDirector.job_failed.connect(_on_job_failed)
	TournamentDirector.async_done.connect(_on_async_done)
	if not TournamentDirector.python_ready:
		log_label.text = "Python not found: %s" % TournamentDirector.python_probe_error
	set_busy("Loading vault...")
	await get_tree().process_frame
	refresh_vault()
	clear_busy()
	_refresh_resume()


func _build_busy_overlay() -> void:
	# Modal working indicator: dims the menu and animates while a vault
	# operation (generate/list) runs. Blocks clicks until done.
	busy_overlay = ColorRect.new()
	busy_overlay.color = Color(0.02, 0.02, 0.05, 0.72)
	busy_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	busy_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	busy_overlay.visible = false
	add_child(busy_overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	busy_overlay.add_child(center)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)
	center.add_child(vbox)
	busy_spinner = Label.new()
	busy_spinner.add_theme_font_size_override("font_size", 64)
	busy_spinner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(busy_spinner)
	busy_label = Label.new()
	busy_label.add_theme_font_size_override("font_size", 20)
	busy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(busy_label)


func set_busy(text: String) -> void:
	busy_label.text = text
	busy_frame = 0
	busy_tick = 0.0
	busy_spinner.text = busy_frames[0]
	busy_overlay.visible = true


func clear_busy() -> void:
	busy_overlay.visible = false


func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "BATTLE FLY ARENA - BRAIN VAULT & TOURNAMENTS"
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(cols)
	cols.add_child(_build_vault_column())
	cols.add_child(_build_gen_column())
	cols.add_child(_build_tourney_column())

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 16)
	vbox.add_child(bottom)
	var free_btn := Button.new()
	free_btn.text = "FREE BATTLE (classic evolution)"
	free_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ArenaGlade.tscn"))
	bottom.add_child(free_btn)
	var quit_btn := Button.new()
	quit_btn.text = "QUIT"
	quit_btn.pressed.connect(func(): get_tree().quit())
	bottom.add_child(quit_btn)

	log_label = Label.new()
	log_label.add_theme_font_size_override("font_size", 13)
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(log_label)


func _col(title_text: String) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.add_theme_constant_override("separation", 6)
	var h := Label.new()
	h.text = title_text
	h.add_theme_font_size_override("font_size", 18)
	c.add_child(h)
	return c


func _build_vault_column() -> VBoxContainer:
	var c := _col("MY BRAINS")
	brain_list = ItemList.new()
	brain_list.custom_minimum_size = Vector2(280, 260)
	brain_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brain_list.item_selected.connect(_on_brain_selected)
	c.add_child(brain_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	c.add_child(row)
	for spec in [["Refresh", refresh_vault], ["Delete", _on_delete], ["Export", _on_export]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		row.add_child(b)
	var imp := Button.new()
	imp.text = "Import .npz"
	imp.pressed.connect(_on_import_dialog)
	row.add_child(imp)
	detail_label = Label.new()
	detail_label.add_theme_font_size_override("font_size", 13)
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.add_child(detail_label)
	return c


func _spin(label_text: String, parent: VBoxContainer, minv: float, maxv: float, step: float, value: float) -> SpinBox:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(150, 0)
	row.add_child(l)
	var s := SpinBox.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	parent.add_child(row)
	return s


func _build_gen_column() -> VBoxContainer:
	var c := _col("GENERATE / TRAIN")
	var nrow := HBoxContainer.new()
	var nl := Label.new()
	nl.text = "Name"
	nl.custom_minimum_size = Vector2(150, 0)
	nrow.add_child(nl)
	gen_name = LineEdit.new()
	gen_name.placeholder_text = "Viper"
	gen_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nrow.add_child(gen_name)
	c.add_child(nrow)
	gen_variant = OptionButton.new()
	for v in ["charger", "flanker", "custom"]:
		gen_variant.add_item(v)
	c.add_child(gen_variant)
	gen_seed = _spin("Seed", c, 0, 9999, 1, 11)
	gen_lr = _spin("Learning rate", c, 0.001, 0.05, 0.001, 0.008)
	gen_gain = _spin("Dist gain", c, 0.0, 1.0, 0.01, 0.15)
	gen_evasion = _spin("Evasion bias", c, 0.0, 1.0, 0.05, 0.2)
	var wirerow := HBoxContainer.new()
	var wirel := Label.new()
	wirel.text = "Wiring"
	wirel.custom_minimum_size = Vector2(150, 0)
	wirerow.add_child(wirel)
	gen_experiment = OptionButton.new()
	gen_experiment.add_item("base")
	gen_experiment.add_item("lplc2_contra_dn")
	gen_experiment.add_item("retina_wide")
	gen_experiment.add_item("spear_lunge")
	gen_experiment.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wirerow.add_child(gen_experiment)
	c.add_child(wirerow)
	# Neuro mapping: sensorimotor control schemes, orthogonal to wiring and
	# stackable - tick any combination (none ticked = base behavior).
	# muscles_up adds the flight-muscle readout; gyro_flow adds the JO gyro
	# input + VS/HS roll output; mbon adds the mushroom-body learned-will
	# readout (approach/avoid value); retina adds the panoramic 21-sector
	# eye (LC11 tracking + LC15/17/18 loom features, needs retina_wide
	# wiring for the downstream path).
	var maprow := HBoxContainer.new()
	var mapl := Label.new()
	mapl.text = "Neuro mapping"
	mapl.custom_minimum_size = Vector2(150, 0)
	maprow.add_child(mapl)
	var mapchecks := HBoxContainer.new()
	mapchecks.add_theme_constant_override("separation", 8)
	mapchecks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	maprow.add_child(mapchecks)
	gen_map_checks.clear()
	for scheme in ["muscles_up", "gyro_flow", "mbon", "retina"]:
		var cb := CheckButton.new()
		cb.text = scheme
		mapchecks.add_child(cb)
		gen_map_checks.append(cb)
	c.add_child(maprow)
	gen_episodes = _spin("Episodes", c, 1, 500, 1, 50)
	var grow := HBoxContainer.new()
	grow.add_theme_constant_override("separation", 6)
	c.add_child(grow)
	var gb := Button.new()
	gb.text = "GENERATE + TRAIN"
	gb.pressed.connect(_on_generate)
	grow.add_child(gb)
	var tb := Button.new()
	tb.text = "TRAIN SELECTED"
	tb.pressed.connect(_on_train)
	grow.add_child(tb)
	job_bar = ProgressBar.new()
	job_bar.min_value = 0
	job_bar.max_value = 100
	job_bar.custom_minimum_size = Vector2(0, 18)
	job_bar.show_percentage = true
	c.add_child(job_bar)
	job_label = Label.new()
	job_label.add_theme_font_size_override("font_size", 13)
	c.add_child(job_label)
	return c


func _build_tourney_column() -> VBoxContainer:
	var c := _col("TOURNAMENT (single elimination)")
	tourney_size = OptionButton.new()
	for s in TournamentDirector.size_options():
		tourney_size.add_item(str(s))
	tourney_size.selected = 1
	c.add_child(tourney_size)
	tourney_bestof = OptionButton.new()
	for b in TournamentDirector.best_of_options():
		tourney_bestof.add_item("Best of %d" % b)
	tourney_bestof.selected = 3
	c.add_child(tourney_bestof)
	tourney_lr = _spin("Tourney learn x", c, 0.0, 1.0, 0.1, 0.5)
	tourney_round_time = _spin("Battle time (s)", c, 10.0, 120.0, 5.0, 40.0)
	var pl := Label.new()
	pl.text = "Participants (Ctrl+click multi-select):"
	pl.add_theme_font_size_override("font_size", 13)
	c.add_child(pl)
	player_list = ItemList.new()
	player_list.custom_minimum_size = Vector2(280, 150)
	player_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	player_list.select_mode = ItemList.SELECT_MULTI
	player_list.allow_rmb_select = true
	c.add_child(player_list)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	c.add_child(srow)
	var start := Button.new()
	start.text = "START TOURNAMENT"
	start.pressed.connect(_on_start_tournament)
	srow.add_child(start)
	resume_button = Button.new()
	resume_button.text = "RESUME"
	resume_button.pressed.connect(_on_resume)
	srow.add_child(resume_button)
	quick_button = Button.new()
	quick_button.text = "QUICK BATTLE (pick 2)"
	quick_button.tooltip_text = "One exhibition battle between exactly 2 selected brains."
	quick_button.pressed.connect(_on_quick_battle)
	srow.add_child(quick_button)
	bracket_status = Label.new()
	bracket_status.add_theme_font_size_override("font_size", 13)
	bracket_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	c.add_child(bracket_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	c.add_child(scroll)
	bracket_view = BracketView.new()
	bracket_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bracket_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(bracket_view)
	return c


func _render_bracket() -> void:
	if bracket_view == null:
		return
	if TournamentDirector.tourney.is_empty():
		bracket_view.render_bracket({}, -1, -1)
	else:
		bracket_view.render_bracket(TournamentDirector.tourney,
			int(TournamentDirector.tourney.get("current_round", 0)),
			int(TournamentDirector.tourney.get("current_match", 0)))


# ── Vault ───────────────────────────────────────────────────────────

func refresh_vault() -> void:
	brains = TournamentDirector.list_brains()
	brain_list.clear()
	player_list.clear()
	for b in brains:
		var r: Dictionary = b.get("record", {})
		var line := "%s  (M%d W%d/L%d T%d)" % [str(b.get("name", "?")),
			int(r.get("matches", 0)), int(r.get("matches_won", 0)),
			int(r.get("matches_lost", 0)), int(r.get("tournaments_won", 0))]
		brain_list.add_item(line)
		player_list.add_item("%s" % str(b.get("name", "?")))
	if not brains.is_empty() and selected_brain.is_empty():
		brain_list.select(0)
		_on_brain_selected(0)
	_update_bracket_preview()


func _on_brain_selected(idx: int) -> void:
	if idx < 0 or idx >= brains.size():
		return
	selected_brain = brains[idx]
	var r: Dictionary = selected_brain.get("record", {})
	var t: Dictionary = selected_brain.get("training", {})
	var p: Dictionary = selected_brain.get("generator_params", {})
	# Brains predating the mapping key fight in the legacy regime;
	# anything carrying the key (even null) runs the current stack.
	var mv_text := "legacy (pre-mapping)"
	if p.has("mapping"):
		var mv = p.get("mapping", "base")
		mv_text = "+".join(mv) if mv is Array else str(mv)
	detail_label.text = ("{name}  [{id}]\nBattles {b} (W{l} L{lo} D{d}) | " + \
		"Matches {m} (W{mw} L{ml}) | Titles {t}\nEpisodes {e} in {s} sessions | " + \
		"variant {v} seed {sd} lr {lr} gain {g} ev {ev} exp {x} map {mp}\nlineage: {lin}").format({
		"name": str(selected_brain.get("name", "?")), "id": str(selected_brain.get("id", "?")),
		"b": int(r.get("battles", 0)), "l": int(r.get("wins", 0)),
		"lo": int(r.get("losses", 0)), "d": int(r.get("draws", 0)),
		"m": int(r.get("matches", 0)), "mw": int(r.get("matches_won", 0)),
		"ml": int(r.get("matches_lost", 0)), "t": int(r.get("tournaments_won", 0)),
		"e": int(t.get("episodes", 0)), "s": (t.get("sessions", []) as Array).size(),
		"v": str(p.get("variant", "?")), "sd": str(p.get("seed", "?")),
		"lr": str(p.get("learning_rate", "?")), "g": str(p.get("dist_gain", "?")),
		"ev": str(p.get("evasion", "?")), "x": str(p.get("experiment", "base")),
		"mp": mv_text,
		"lin": str(selected_brain.get("lineage", {}).get("source", "?"))})
	_prefill_train_widgets(p)


func _gen_params() -> Dictionary:
	var exp_idx := gen_experiment.selected
	var schemes: Array = []
	for cb in gen_map_checks:
		if (cb as CheckButton).button_pressed:
			schemes.append((cb as CheckButton).text)
	return {
		"variant": gen_variant.get_item_text(gen_variant.selected),
		"seed": int(gen_seed.value),
		"learning_rate": gen_lr.value,
		"dist_gain": gen_gain.value,
		"evasion": gen_evasion.value,
		"align_bonus": [0.5, 0.2, -0.3],
		"experiment": null if exp_idx == 0 else gen_experiment.get_item_text(exp_idx),
		"mapping": schemes if not schemes.is_empty() else null,
	}


func _on_generate() -> void:
	var brain_name := gen_name.text.strip_edges()
	if brain_name == "":
		log_label.text = "Give the brain a name first."
		return
	if not TournamentDirector.python_ready:
		log_label.text = "Generate failed: %s" % TournamentDirector.python_probe_error
		return
	set_busy("Generating '%s'... (loading connectome, up to ~1 min)" % brain_name)
	await get_tree().process_frame
	var res: Dictionary = TournamentDirector.generate_brain_async(brain_name, _gen_params())
	if not res.get("ok", false):
		clear_busy()
		log_label.text = "Generate failed: %s" % res.get("error", "?")
		return
	log_label.text = "Generating '%s' in background (pid %s)..." % [brain_name, str(res.get("pid", "?"))]
	# Busy overlay stays up, spinner alive; completion arrives via async_done.


func _on_async_done(op: String, result: Dictionary) -> void:
	clear_busy()
	if op == "generate":
		if not result.get("ok", false):
			log_label.text = "Generate failed: %s" % result.get("error", "?")
			return
		refresh_vault()
		var brain: Dictionary = result.get("brain", {})
		var brain_name := str(brain.get("name", "?"))
		var tres: Dictionary = TournamentDirector.start_training(
			str(brain.get("id", "")), int(gen_episodes.value), _gen_params())
		if tres.get("ok", false):
			job_label.text = "Training %s x%d ..." % [brain_name, int(gen_episodes.value)]
			job_bar.value = 0.0
			log_label.text = "Generated '%s' - training in background." % brain_name
		else:
			log_label.text = "Generated '%s' but train did not start: %s" % [brain_name, tres.get("error", "?")]


func _retrain_params() -> Dictionary:
	# Retraining uses the brain's own stored generator_params (wiring,
	# mapping, seed, rates), so an experiment brain can never be retrained
	# on the wrong arity via menu defaults. Only whitelisted trainer keys
	# are forwarded; episode count comes from the spinbox at call time.
	var stored: Dictionary = selected_brain.get("generator_params", {})
	var out := {}
	for k in ["variant", "seed", "learning_rate", "dist_gain", "evasion",
			"align_bonus", "experiment", "mapping"]:
		if stored.has(k):
			out[k] = stored[k]
	return out


func _prefill_train_widgets(p: Dictionary) -> void:
	# Selecting a brain shows the settings a retrain will actually use.
	# A missing mapping key means the legacy pre-mapping regime (all
	# mapping boxes stay unticked); a present key follows the current stack.
	var v := str(p.get("variant", "custom"))
	var v_idx := 2
	for i in range(gen_variant.item_count):
		if gen_variant.get_item_text(i) == v:
			v_idx = i
	gen_variant.selected = v_idx
	gen_seed.value = float(p.get("seed", gen_seed.value))
	gen_lr.value = float(p.get("learning_rate", gen_lr.value))
	gen_gain.value = float(p.get("dist_gain", gen_gain.value))
	gen_evasion.value = float(p.get("evasion", gen_evasion.value))
	var exp = p.get("experiment", null)
	if exp == null or str(exp).strip_edges().to_lower() in ["", "none", "base"]:
		gen_experiment.selected = 0
	else:
		for i in range(gen_experiment.item_count):
			if gen_experiment.get_item_text(i) == str(exp):
				gen_experiment.selected = i
	var mv = p.get("mapping", null)
	var active: Array = []
	if mv is Array:
		active = mv
	elif mv != null and str(mv).strip_edges().to_lower() not in ["", "none", "base"]:
		active = [str(mv)]
	for cb in gen_map_checks:
		(cb as CheckButton).button_pressed = active.has((cb as CheckButton).text)


func _on_train() -> void:
	if selected_brain.is_empty():
		log_label.text = "Select a brain first."
		return
	if not TournamentDirector.active_job.is_empty():
		job_label.text = "A training job is already running - wait or restart the menu."
		return
	var bid := str(selected_brain.get("id", ""))
	var res: Dictionary = TournamentDirector.start_training(bid, int(gen_episodes.value), _retrain_params())
	if res.get("ok", false):
		job_bar.value = 0.0
		job_label.text = "Training %s ..." % str(selected_brain.get("name", "?"))
	else:
		job_label.text = "Train failed: %s" % res.get("error", "?")


func _on_job_progress(episode: int, total: int) -> void:
	if total > 0:
		job_bar.value = 100.0 * episode / total
		_job_base = "Training... episode %d / %d" % [episode, total]
		job_label.text = _job_base
		if episode >= total:
			_job_base = ""
			refresh_vault()


func _on_job_failed(error: String) -> void:
	_job_base = ""
	job_label.text = "Train failed: %s" % error
	log_label.text = "Train failed: %s" % error


func _on_delete() -> void:
	if selected_brain.is_empty():
		return
	var res: Dictionary = TournamentDirector.delete_brain(str(selected_brain.get("id", "")))
	if res.get("ok", false):
		selected_brain = {}
		detail_label.text = ""
		refresh_vault()
	else:
		log_label.text = "Delete failed: %s" % res.get("error", "?")


func _on_export() -> void:
	if selected_brain.is_empty():
		return
	var out_path: String = TournamentDirector.project_root().path_join(
		"brains/exports/%s_%s.flybrain" % [str(selected_brain.get("name", "?")),
		str(selected_brain.get("id", "?"))])
	var res: Dictionary = TournamentDirector.export_brain(str(selected_brain.get("id", "")), out_path)
	log_label.text = ("Exported to %s" % out_path) if res.get("ok", false) else ("Export failed: %s" % res.get("error", "?"))


func _on_import_dialog() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.add_filter("*.npz", "Legacy weights")
	dlg.current_dir = TournamentDirector.project_root().path_join("checkpoints")
	dlg.file_selected.connect(_on_import_file)
	add_child(dlg)
	dlg.popup_centered(Vector2(700, 450))


func _on_import_file(path: String) -> void:
	var res: Dictionary = TournamentDirector.import_brain(path, path.get_file().get_basename())
	log_label.text = "Imported." if res.get("ok", false) else ("Import failed: %s" % res.get("error", "?"))
	if res.get("ok", false):
		refresh_vault()


# ── Tournament ──────────────────────────────────────────────────────

func _selected_player_ids() -> Array:
	var ids: Array = []
	for i in player_list.get_selected_items():
		if i >= 0 and i < brains.size():
			ids.append(str(brains[i].get("id", "")))
	return ids


func _update_bracket_preview() -> void:
	var n := _selected_player_ids().size()
	var size := int(TournamentDirector.size_options()[tourney_size.selected])
	var bestof := int(TournamentDirector.best_of_options()[tourney_bestof.selected])
	bracket_status.text = "Slots %d | picked %d | best-of-%d (first to %d). %s" % [
		size, n, bestof, bestof / 2 + 1,
		"Left/Right groups, single elimination." if n >= 2 else "Pick at least 2 brains."]


func _on_start_tournament() -> void:
	var size := int(TournamentDirector.size_options()[tourney_size.selected])
	var bestof := int(TournamentDirector.best_of_options()[tourney_bestof.selected])
	var ids := _selected_player_ids()
	if ids.size() < 2:
		bracket_status.text = "Pick at least 2 brains (Ctrl+click)."
		return
	var res: Dictionary = TournamentDirector.build_bracket(ids, size, bestof, tourney_lr.value, tourney_round_time.value)
	if not res.get("ok", false):
		bracket_status.text = "Cannot start: %s" % res.get("error", "?")
		return
	bracket_status.text = "Tournament %s ready." % str(res.get("tournament_id", ""))
	_render_bracket()
	await get_tree().create_timer(0.5).timeout
	get_tree().change_scene_to_file("res://scenes/ArenaGlade.tscn")


func _on_quick_battle() -> void:
	# One exhibition battle between exactly 2 selected brains. Uses the
	# tournament engine (best-of-1) so dopamine + records still apply.
	var ids := _selected_player_ids()
	if ids.size() != 2:
		bracket_status.text = "Quick battle needs exactly 2 selected brains (Ctrl+click)."
		return
	var res: Dictionary = TournamentDirector.start_quick_battle(str(ids[0]), str(ids[1]))
	if not res.get("ok", false):
		bracket_status.text = "Cannot start: %s" % res.get("error", "?")
		return
	bracket_status.text = "Quick battle ready."
	_render_bracket()
	await get_tree().create_timer(0.5).timeout
	get_tree().change_scene_to_file("res://scenes/ArenaGlade.tscn")


func _refresh_resume() -> void:
	if TournamentDirector.tournament_active():
		resume_button.text = "RESUME LIVE"
		bracket_status.text = "Tournament in progress."
		_render_bracket()
	else:
		resume_button.text = "RESUME FILE"
		bracket_status.text = "No live tournament."


func _on_resume() -> void:
	if TournamentDirector.tournament_active():
		get_tree().change_scene_to_file("res://scenes/ArenaGlade.tscn")
		return
	# File resume: latest running state under tournaments/.
	var dir := DirAccess.open(TournamentDirector.tournament_dir)
	if dir == null:
		return
	var latest := ""
	var latest_mtime := 0
	for f in dir.get_files():
		if f.ends_with(".json"):
			var p: String = TournamentDirector.tournament_dir.path_join(f)
			if FileAccess.get_modified_time(p) > latest_mtime:
				latest_mtime = FileAccess.get_modified_time(p)
				latest = p
	if latest != "" and TournamentDirector.load_state_file(latest):
		if TournamentDirector.tournament_active():
			get_tree().change_scene_to_file("res://scenes/ArenaGlade.tscn")
		else:
			bracket_status.text = "Loaded saved bracket."
			_render_bracket()


func _process(delta: float) -> void:
	if player_list == null:
		return
	if visible and player_list.get_selected_items().size() != _last_sel_count:
		_last_sel_count = player_list.get_selected_items().size()
		_update_bracket_preview()
	# Busy spinner: proves work is actively happening during generate/list.
	if busy_overlay != null and busy_overlay.visible:
		busy_tick += delta
		if busy_tick >= 0.1:
			busy_tick = 0.0
			busy_frame = (busy_frame + 1) % busy_frames.size()
			busy_spinner.text = busy_frames[busy_frame]
	# Training liveness dots between episode updates.
	if job_label != null and not TournamentDirector.active_job.is_empty() and _job_base != "":
		_job_tick += delta
		if _job_tick >= 0.5:
			_job_tick = 0.0
			_job_dots = (_job_dots + 1) % 4
			job_label.text = _job_base + ".".repeat(_job_dots)


var _last_sel_count: int = -1
var _job_base: String = ""
var _job_dots: int = 0
var _job_tick: float = 0.0
