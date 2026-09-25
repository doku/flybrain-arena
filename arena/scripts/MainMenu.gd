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
var archive_list_view: ItemList
var archive_entries: Array = []

var bv_enable: CheckButton
var bv_layer: OptionButton
var bv_detail: OptionButton
var bv_replay: CheckButton
var gen_yaw_bias: SpinBox
var gen_yaw_random: CheckButton
var gen_genome_check: CheckButton
var gen_genome_seed: SpinBox
var gen_genome_rules: SpinBox
var gen_derive_check: CheckButton
var gen_derived: Dictionary = {}
var gen_name: LineEdit
var gen_variant: OptionButton
var gen_seed: SpinBox
var gen_lr: SpinBox
var gen_gain: SpinBox
var gen_evasion: SpinBox
# Additive wiring selection (replaces the old single-choice dropdown):
# checked wiring names, e.g. ["retina_wide", "spear_lunge"]; empty = base.
var gen_wiring: Array = []
var gen_wire_checks: Array = []
var gen_map_checks: Array = []
var gen_config_summary: Label
var gen_config_dlg: Window
var gen_episodes: SpinBox
var train_school: CheckButton
var job_bar: ProgressBar
var job_label: Label
var queue_list: ItemList
var queue_label: Label

var tourney_size: OptionButton
var tourney_bestof: OptionButton
var tourney_random: CheckButton
var tourney_consolation: CheckButton
var evo_mutate_traits: CheckButton
var tourney_lr: SpinBox
var tourney_round_time: SpinBox
var player_list: ItemList
var bracket_status: Label
var bracket_view: BracketView
var bracket_main_btn: Button
var bracket_losers_btn: Button
var _bracket_losers := false
var _bracket_manual := false
var _bracket_tid := ""
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
	TournamentDirector.score_stamped.connect(_on_score_stamped)
	TournamentDirector.async_done.connect(_on_async_done)
	TournamentDirector.train_queue_changed.connect(_refresh_train_queue)
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
	vbox.add_child(_build_brainview_row())

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


func _build_brainview_row() -> HBoxContainer:
	# In-arena neural activation overlay settings (menu -> arena via the
	# TournamentDirector bus). Always-on capable; every heavy layer can
	# drop to bars-only or off.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var h := Label.new()
	h.text = "BRAIN VIEW"
	h.add_theme_font_size_override("font_size", 15)
	row.add_child(h)
	bv_enable = CheckButton.new()
	bv_enable.text = "show"
	bv_enable.button_pressed = true
	bv_enable.toggled.connect(_push_brainview_settings)
	row.add_child(bv_enable)
	var ll := Label.new()
	ll.text = "layer"
	row.add_child(ll)
	bv_layer = OptionButton.new()
	for layer in ["bars", "flow", "raster", "brain3d"]:
		bv_layer.add_item(layer)
	bv_layer.item_selected.connect(_push_brainview_settings)
	row.add_child(bv_layer)
	var dl := Label.new()
	dl.text = "detail"
	row.add_child(dl)
	bv_detail = OptionButton.new()
	for d in ["0 counts", "1 rates", "2 raster"]:
		bv_detail.add_item(d)
	bv_detail.selected = 1
	bv_detail.item_selected.connect(_push_brainview_settings)
	row.add_child(bv_detail)
	bv_replay = CheckButton.new()
	bv_replay.text = "record replay"
	bv_replay.toggled.connect(_push_brainview_settings)
	row.add_child(bv_replay)
	_push_brainview_settings()
	return row


func _push_brainview_settings(_arg = null) -> void:
	TournamentDirector.brainview_enabled = bv_enable.button_pressed
	TournamentDirector.brainview_layer = bv_layer.get_item_text(bv_layer.selected)
	TournamentDirector.brainview_detail = bv_detail.selected
	TournamentDirector.brainview_replay = bv_replay.button_pressed


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
	var arch_head := Label.new()
	arch_head.text = "HALL OF SHAME (archived losers)"
	arch_head.add_theme_font_size_override("font_size", 13)
	c.add_child(arch_head)
	archive_list_view = ItemList.new()
	archive_list_view.custom_minimum_size = Vector2(280, 90)
	archive_list_view.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	c.add_child(archive_list_view)
	var arch_row := HBoxContainer.new()
	arch_row.add_theme_constant_override("separation", 6)
	c.add_child(arch_row)
	var restore_b := Button.new()
	restore_b.text = "Bring back"
	restore_b.tooltip_text = "Restore the selected archived brain to the vault roster."
	restore_b.pressed.connect(_on_archive_restore)
	arch_row.add_child(restore_b)
	var del_b := Button.new()
	del_b.text = "Delete forever"
	del_b.tooltip_text = "Permanently delete the selected archived brain and free its disk space. Cannot be undone."
	del_b.pressed.connect(_on_archive_delete)
	arch_row.add_child(del_b)
	detail_label = Label.new()
	detail_label.add_theme_font_size_override("font_size", 13)
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.add_child(detail_label)
	return c


func _spin(label_text: String, parent: VBoxContainer, minv: float, maxv: float, step: float, value: float, tip: String = "") -> SpinBox:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(150, 0)
	if tip != "":
		l.tooltip_text = tip
	row.add_child(l)
	var s := SpinBox.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if tip != "":
		s.tooltip_text = tip
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
	# One summary row + configurator dialog (the column was getting
	# crowded): wiring is additive multi-select, mapping stackable, and
	# the training hyperparams live in the dialog too.
	var confrow := HBoxContainer.new()
	gen_config_summary = Label.new()
	gen_config_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gen_config_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	confrow.add_child(gen_config_summary)
	var confbtn := Button.new()
	confbtn.text = "Configure..."
	confbtn.pressed.connect(_open_config_dialog)
	confrow.add_child(confbtn)
	c.add_child(confrow)
	_build_config_dialog()
	_update_config_summary()
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
	var rb := Button.new()
	rb.text = "BREED REFERENCE"
	rb.tooltip_text = "Breed the canonical reference stock (pinned best-known wiring, fixed rates) as breeding material. Trains Episodes pre-train eps (+ Episodes school eps when Flight school is ticked). One stock only - refuses duplicates."
	rb.pressed.connect(_on_breed_reference)
	grow.add_child(rb)
	train_school = CheckButton.new()
	train_school.text = "Flight school"
	train_school.tooltip_text = "ON = retrain through flight-school scenarios (camp/mover/duel) with scores stamped. OFF = legacy encounters."
	train_school.button_pressed = false
	grow.add_child(train_school)
	job_bar = ProgressBar.new()
	job_bar.min_value = 0
	job_bar.max_value = 100
	job_bar.custom_minimum_size = Vector2(0, 18)
	job_bar.show_percentage = true
	c.add_child(job_bar)
	job_label = Label.new()
	job_label.add_theme_font_size_override("font_size", 13)
	c.add_child(job_label)
	# Training queue: what's running shows above (job bar/label);
	# everything waiting is listed here with remove/clear controls.
	queue_label = Label.new()
	queue_label.text = "TRAINING QUEUE (0)"
	queue_label.add_theme_font_size_override("font_size", 13)
	c.add_child(queue_label)
	queue_list = ItemList.new()
	queue_list.custom_minimum_size = Vector2(0, 84)
	queue_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(queue_list)
	var qrow := HBoxContainer.new()
	qrow.add_theme_constant_override("separation", 6)
	c.add_child(qrow)
	var qrm := Button.new()
	qrm.text = "REMOVE SELECTED"
	qrm.pressed.connect(_on_queue_remove)
	qrow.add_child(qrm)
	var qclr := Button.new()
	qclr.text = "CLEAR QUEUE"
	qclr.pressed.connect(_on_queue_clear)
	qrow.add_child(qclr)
	return c


# Brain configurator dialog: additive wiring multi-select, stackable
# mapping schemes, and training hyperparams in one place so the main
# column stays a slim Name / Variant / Config-summary / Episodes stack.
const WIRING_OPTIONS := [
	["lplc2_contra_dn", "Tree avoidance: LPLC2 loom steers AWAY via contralateral DNs."],
	["retina_wide", "Visual pursuit assist: LC feature pools drive same-side DNs."],
	["spear_lunge", "Spear attack: frontal LC volleys drive the mouth motor neurons."],
]
const MAPPING_OPTIONS := [
	["muscles_up", "Flight-muscle readout: MN thrust/steering votes."],
	["gyro_flow", "Antennal gyro input (JO) + VS/HS roll output."],
	["mbon", "Mushroom-body learned-will readout (approach/avoid value)."],
	["retina", "Panoramic 21-sector eye (pairs with retina_wide wiring)."],
	["flow_trans", "Translational flow: T4/T5 cruise control, drift trim, landing flare."],
]


func _build_config_dialog() -> void:
	gen_config_dlg = Window.new()
	gen_config_dlg.title = "Brain configuration"
	gen_config_dlg.size = Vector2i(620, 700)
	gen_config_dlg.min_size = Vector2i(480, 400)
	gen_config_dlg.visible = false
	add_child(gen_config_dlg)
	# Scrollable content: the wiring/mapping/training sections are taller
	# than any fixed window, so they scroll instead of getting cut off.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	gen_config_dlg.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	var wh := Label.new()
	wh.text = "WIRING (additive - tick any combination, empty = base)"
	wh.add_theme_font_size_override("font_size", 15)
	vb.add_child(wh)
	gen_wire_checks.clear()
	for opt in WIRING_OPTIONS:
		var cb := CheckButton.new()
		cb.text = opt[0]
		cb.toggled.connect(_sync_config_from_dialog)
		vb.add_child(cb)
		gen_wire_checks.append(cb)
		var d := Label.new()
		d.text = "      " + opt[1]
		d.add_theme_font_size_override("font_size", 12)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(d)
	var gh := Label.new()
	gh.text = "WIRING GENOME (random rules - overrides mixes above)"
	gh.add_theme_font_size_override("font_size", 15)
	vb.add_child(gh)
	gen_genome_check = CheckButton.new()
	gen_genome_check.text = "random genome"
	gen_genome_check.tooltip_text = "Sample a grammar-constrained wiring genome (sensory to motor/central pools). Overrides the mixes above; mapping derives from its efferents unless unchecked below."
	gen_genome_check.toggled.connect(_sync_config_from_dialog)
	vb.add_child(gen_genome_check)
	gen_genome_seed = _spin("Genome seed", vb, 0.0, 99999.0, 1.0, 42.0,
		"Same seed always builds the same genome (reproducible bloodlines).")
	gen_genome_seed.value_changed.connect(_on_genome_spin)
	gen_genome_rules = _spin("Genome rules", vb, 1.0, 8.0, 1.0, 3.0,
		"Projection rules sampled (1-8). More rules = wilder wiring.")
	gen_genome_rules.value_changed.connect(_on_genome_spin)
	gen_derive_check = CheckButton.new()
	gen_derive_check.text = "derive mapping from wiring"
	gen_derive_check.tooltip_text = "Resolve the mapping from the genome's efferents (retina/flow/muscles/mbon light up when driven). Untick to hand-pick below."
	gen_derive_check.button_pressed = true
	gen_derive_check.toggled.connect(_sync_config_from_dialog)
	vb.add_child(gen_derive_check)
	var mh := Label.new()
	mh.text = "NEURO MAPPING (stackable, empty = base)"
	mh.add_theme_font_size_override("font_size", 15)
	vb.add_child(mh)
	gen_map_checks.clear()
	for opt in MAPPING_OPTIONS:
		var cb := CheckButton.new()
		cb.text = opt[0]
		cb.toggled.connect(_sync_config_from_dialog)
		vb.add_child(cb)
		gen_map_checks.append(cb)
		var d := Label.new()
		d.text = "      " + opt[1]
		d.add_theme_font_size_override("font_size", 12)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(d)
	var th := Label.new()
	th.text = "TRAINING"
	th.add_theme_font_size_override("font_size", 15)
	vb.add_child(th)
	gen_seed = _spin("Seed", vb, 0, 9999, 1, 11)
	gen_lr = _spin("Learning rate", vb, 0.001, 0.05, 0.001, 0.008)
	gen_gain = _spin("Dist gain [*0.1-0.2]", vb, 0.0, 1.0, 0.01, 0.15,
		"Recommended 0.1-0.2 (especially full wiring mixes). 0.5 amplifies dopamine swings and collapses pools faster.")
	gen_evasion = _spin("Evasion bias", vb, 0.0, 1.0, 0.05, 0.2)
	gen_yaw_bias = _spin("Yaw bias [*9.0]", vb, 0.0, 25.0, 0.1, 9.0,
		"Intrinsic DN lateralization correction (measured ~9). Lower if the fly crawls left, raise if it crawls right.")
	gen_yaw_random = CheckButton.new()
	gen_yaw_random.text = "randomize yaw bias (6-12)"
	gen_yaw_random.tooltip_text = "Draws the bias uniform 6-12 at generate time for handedness variation; stamped into the record."
	vb.add_child(gen_yaw_random)
	var closerow := HBoxContainer.new()
	closerow.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(closerow)
	var closeb := Button.new()
	closeb.text = "Done"
	closeb.pressed.connect(func(): gen_config_dlg.visible = false)
	closerow.add_child(closeb)


func _open_config_dialog() -> void:
	_sync_dialog_from_state()
	gen_config_dlg.visible = true


func _sync_dialog_from_state() -> void:
	for cb in gen_wire_checks:
		(cb as CheckButton).set_pressed_no_signal(gen_wiring.has((cb as CheckButton).text))
	var active: Array = []
	for cb in gen_map_checks:
		if (cb as CheckButton).button_pressed:
			active.append((cb as CheckButton).text)
	_update_config_summary()


func _on_genome_spin(_v: float) -> void:
	_sync_config_from_dialog()


func _resolve_genome() -> void:
	# Resolves the genome seed/rules to mapping+id via the vault CLI
	# (pure rule-table lookup, no CSR - fast enough to run on clicks).
	gen_derived = {}
	if not is_instance_valid(gen_genome_check) or not gen_genome_check.button_pressed:
		return
	if not TournamentDirector.python_ready:
		gen_derived = {"ok": false, "error": "no python"}
		return
	gen_derived = TournamentDirector.derive_mapping(
		int(gen_genome_seed.value), int(gen_genome_rules.value))


func _sync_config_from_dialog(_on: bool = true) -> void:
	gen_wiring.clear()
	for cb in gen_wire_checks:
		if (cb as CheckButton).button_pressed:
			gen_wiring.append((cb as CheckButton).text)
	_resolve_genome()
	_update_config_summary()


func _update_config_summary() -> void:
	var schemes: Array = []
	for cb in gen_map_checks:
		if (cb as CheckButton).button_pressed:
			schemes.append((cb as CheckButton).text)
	var genome_on := is_instance_valid(gen_genome_check) and gen_genome_check.button_pressed
	if genome_on:
		var wtext := "genome"
		if bool(gen_derived.get("ok", false)):
			wtext = "Genome %s (%d rules)" % [str(gen_derived.get("genome_label", "?")),
				int(gen_derived.get("n_rules", 0))]
		elif not gen_derived.is_empty():
			wtext = "Genome (unresolved: %s)" % str(gen_derived.get("error", "?"))
		var mtext := "derived"
		if bool(gen_derived.get("ok", false)):
			var dm: Array = gen_derived.get("mapping", [])
			mtext = "derived (%s)" % ("base" if dm.is_empty() else ", ".join(dm))
		if not (is_instance_valid(gen_derive_check) and gen_derive_check.button_pressed):
			mtext = "base" if schemes.is_empty() else ", ".join(schemes)
		if is_instance_valid(gen_config_summary):
			gen_config_summary.text = "Wiring: %s\nMap: %s" % [wtext, mtext]
		return
	var wtext := "base" if gen_wiring.is_empty() else " + ".join(gen_wiring)
	var mtext := "base" if schemes.is_empty() else ", ".join(schemes)
	if is_instance_valid(gen_config_summary):
		gen_config_summary.text = "Wiring: %s\nMap: %s" % [wtext, mtext]


static func _mix_text(v) -> String:
	# Stored experiment values across eras: null, "base", a single name,
	# a plus-joined mix, or an Array of names.
	if v == null:
		return "base"
	if v is Array:
		return "base" if (v as Array).is_empty() else " + ".join(v)
	var s := str(v).strip_edges()
	if s.begins_with("__exp_"):
		s = s.trim_prefix("__exp_")
	if s.contains("__"):
		s = "+".join(s.split("__"))
	if s.to_lower() in ["", "none", "base"]:
		return "base"
	return s


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
	tourney_lr = _spin("Tourney learn x [*0.5]", c, 0.0, 1.0, 0.1, 0.5,
		"Default 0.5. Long formats 0.2-0.3 (selection over adaptation), short exhibition or sharpening a favorite 0.7-1.0, 0.0 = frozen bracket.")
	tourney_round_time = _spin("Battle time (s)", c, 10.0, 120.0, 5.0, 40.0)
	tourney_random = CheckButton.new()
	tourney_random.text = "Random draw"
	tourney_random.tooltip_text = "ON = shuffle entrants (byes fall luck-of-the-draw). OFF = ELO strength seeding: top seeds take byes, strongest meets weakest."
	tourney_random.button_pressed = false
	c.add_child(tourney_random)
	tourney_consolation = CheckButton.new()
	tourney_consolation.text = "Losers bracket (find last place)"
	tourney_consolation.tooltip_text = "After the final, round-0 losers play their own bracket (needs 2/4/8); the last two skip the final and go straight to archives."
	tourney_consolation.button_pressed = true
	c.add_child(tourney_consolation)
	var pl := Label.new()
	pl.text = "Participants (Ctrl+click multi-select):"
	pl.add_theme_font_size_override("font_size", 13)
	c.add_child(pl)
	player_list = ItemList.new()
	player_list.custom_minimum_size = Vector2(320, 150)
	player_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	player_list.select_mode = ItemList.SELECT_MULTI
	player_list.allow_rmb_select = true
	c.add_child(player_list)
	# Two rows of two: one four-button row (~690px) overflows its
	# ~416px column share and gets cut off at the window edge.
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	c.add_child(srow)
	var start := Button.new()
	start.text = "START TOURNAMENT"
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start.pressed.connect(_on_start_tournament)
	srow.add_child(start)
	resume_button = Button.new()
	resume_button.text = "RESUME"
	resume_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resume_button.pressed.connect(_on_resume)
	srow.add_child(resume_button)
	var srow2 := HBoxContainer.new()
	srow2.add_theme_constant_override("separation", 6)
	c.add_child(srow2)
	quick_button = Button.new()
	quick_button.text = "QUICK BATTLE (pick 2)"
	quick_button.tooltip_text = "One exhibition battle between exactly 2 selected brains."
	quick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick_button.pressed.connect(_on_quick_battle)
	srow2.add_child(quick_button)
	var evo_button := Button.new()
	evo_button.text = "START EVOLUTION"
	evo_button.tooltip_text = "Eternal loop: tournament, archive biggest loser, breed 1 winner-clone + 1 random (50 eps), next generation. STOP in the arena."
	evo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	evo_button.pressed.connect(_on_start_evolution)
	srow2.add_child(evo_button)
	evo_mutate_traits = CheckButton.new()
	evo_mutate_traits.text = "Mutate kin traits"
	evo_mutate_traits.tooltip_text = "ON = each generation's winner-clone re-rolls one random trait (learning rate, dist gain, evasion, yaw bias) alongside genome structural mutation. OFF = exact hyperparameter copy."
	evo_mutate_traits.button_pressed = true
	c.add_child(evo_mutate_traits)
	bracket_status = Label.new()
	bracket_status.add_theme_font_size_override("font_size", 13)
	bracket_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	c.add_child(bracket_status)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 6)
	c.add_child(brow)
	var bgroup := ButtonGroup.new()
	bracket_main_btn = Button.new()
	bracket_main_btn.text = "Main bracket"
	bracket_main_btn.toggle_mode = true
	bracket_main_btn.button_group = bgroup
	bracket_main_btn.tooltip_text = "Main single-elimination bracket (no consolation rounds)."
	bracket_main_btn.pressed.connect(_on_bracket_view.bind(false))
	brow.add_child(bracket_main_btn)
	bracket_losers_btn = Button.new()
	bracket_losers_btn.text = "Losers bracket"
	bracket_losers_btn.toggle_mode = true
	bracket_losers_btn.button_group = bgroup
	bracket_losers_btn.tooltip_text = "Consolation bracket on its own page."
	bracket_losers_btn.pressed.connect(_on_bracket_view.bind(true))
	brow.add_child(bracket_losers_btn)
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


func _on_bracket_view(losers: bool) -> void:
	_bracket_losers = losers
	_bracket_manual = true
	_render_bracket()


func _live_losers_running() -> bool:
	var t: Dictionary = TournamentDirector.tourney
	var lf := int(t.get("losers_start_round", -1))
	return lf > 0 and int(t.get("current_round", 0)) >= lf \
		and str(t.get("status", "")) == "running"


func _render_bracket() -> void:
	if bracket_view == null:
		return
	if TournamentDirector.tourney.is_empty():
		bracket_view.render_bracket({}, -1, -1)
		_sync_bracket_buttons()
		return
	# New tournament: drop the manual pick and auto-show the losers
	# page while consolation is live, main otherwise.
	var tid := str(TournamentDirector.tourney.get("id", ""))
	if tid != _bracket_tid:
		_bracket_tid = tid
		_bracket_manual = false
		_bracket_losers = _live_losers_running()
	if int(TournamentDirector.tourney.get("losers_start_round", -1)) < 0:
		_bracket_losers = false
	bracket_view.render_bracket(TournamentDirector.tourney,
		int(TournamentDirector.tourney.get("current_round", 0)),
		int(TournamentDirector.tourney.get("current_match", 0)),
		2 if _bracket_losers else 1)
	_sync_bracket_buttons()


func _sync_bracket_buttons() -> void:
	if bracket_main_btn == null or bracket_losers_btn == null:
		return
	var has_losers := int(TournamentDirector.tourney.get(
		"losers_start_round", -1)) > 0
	bracket_losers_btn.disabled = not has_losers
	bracket_main_btn.set_pressed_no_signal(not _bracket_losers)
	bracket_losers_btn.set_pressed_no_signal(_bracket_losers and has_losers)


# ── Vault ───────────────────────────────────────────────────────────

func refresh_vault() -> void:
	brains = TournamentDirector.list_brains()
	brain_list.clear()
	player_list.clear()
	for b in brains:
		var r: Dictionary = b.get("record", {})
		var t: Dictionary = b.get("training", {})
		var score: float = float(t.get("score", 0.0))
		var line := "%s  (M%d W%d/L%d T%d) [elo %d] [score %.0f]" % [str(b.get("name", "?")),
			int(r.get("matches", 0)), int(r.get("matches_won", 0)),
			int(r.get("matches_lost", 0)), int(r.get("tournaments_won", 0)),
			int(r.get("elo", 1200.0)), score]

		brain_list.add_item(line)
		var brec: Dictionary = b.get("record", {})
		player_list.add_item("%s  [elo %d]" % [str(b.get("name", "?")),
			int(brec.get("elo", 1200.0))])
	if not brains.is_empty() and selected_brain.is_empty():
		brain_list.select(0)
		_on_brain_selected(0)
	_refresh_archive()
	_update_bracket_preview()


func _archive_tooltip(e: Dictionary) -> String:
	# Hall-of-shame hover card: career stats + build, same vocabulary as
	# the vault detail readout (old log entries may lack record/params).
	var r: Dictionary = e.get("record", {})
	var p: Dictionary = e.get("generator_params", {})
	var reason := str(e.get("reason", ""))
	var when := str(e.get("archived_utc", "?"))
	var head := "%s  [%.1f MB]" % [str(e.get("name", "?")),
		float(e.get("size_mb", 0.0))]
	if not bool(e.get("present", true)):
		head += " (missing)"
	if reason != "":
		head += "\narchived %s: %s" % [when, reason]
	else:
		head += "\narchived %s" % when
	var gid := str(p.get("genome_id", ""))
	var wiring := "genome " + gid if gid != "" else str(p.get("experiment", "base"))
	return head + "\nBattles %d (W%d L%d D%d) | Matches %d (W%d L%d) | Titles %d | ELO %d" % [
		int(r.get("battles", 0)), int(r.get("wins", 0)),
		int(r.get("losses", 0)), int(r.get("draws", 0)),
		int(r.get("matches", 0)), int(r.get("matches_won", 0)),
		int(r.get("matches_lost", 0)), int(r.get("tournaments_won", 0)),
		int(r.get("elo", 1200.0))] + \
		"\nvariant %s seed %s lr %s gain %s ev %s yb %s wiring %s" % [
		str(p.get("variant", "?")), str(p.get("seed", "?")),
		str(p.get("learning_rate", "?")), str(p.get("dist_gain", "?")),
		str(p.get("evasion", "?")), str(p.get("yaw_bias", "?")), wiring]


func _refresh_archive() -> void:
	archive_entries = TournamentDirector.archive_list()
	if is_instance_valid(archive_list_view):
		archive_list_view.clear()
		var idx := 0
		for e in archive_entries:
			archive_list_view.add_item("%s  [%.1f MB]%s" % [
				str(e.get("name", "?")), float(e.get("size_mb", 0.0)),
				"" if bool(e.get("present", true)) else " (missing)"])
			archive_list_view.set_item_tooltip(idx, _archive_tooltip(e))
			idx += 1


func _on_archive_restore() -> void:
	var sel := archive_list_view.get_selected_items()
	if sel.is_empty() or int(sel[0]) < 0 or int(sel[0]) >= archive_entries.size():
		log_label.text = "Select an archived brain first."
		return
	var entry: Dictionary = archive_entries[int(sel[0])]
	var res: Dictionary = TournamentDirector.restore_archived(str(entry.get("id", "")))
	if not bool(res.get("ok", false)):
		log_label.text = "Restore failed: %s" % str(res.get("error", "?"))
		return
	log_label.text = "Brought back '%s'." % str(entry.get("name", "?"))
	refresh_vault()


func _on_archive_delete() -> void:
	var sel := archive_list_view.get_selected_items()
	if sel.is_empty() or int(sel[0]) < 0 or int(sel[0]) >= archive_entries.size():
		log_label.text = "Select an archived brain first."
		return
	var entry: Dictionary = archive_entries[int(sel[0])]
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete archived brain?"
	dlg.dialog_text = "Permanently delete '%s'?\nFrees %.1f MB. Cannot be undone." % [
		str(entry.get("name", "?")), float(entry.get("size_mb", 0.0))]
	dlg.ok_button_text = "Delete"
	dlg.canceled.connect(dlg.queue_free)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.confirmed.connect(_on_archive_delete_confirmed.bind(
		str(entry.get("id", "")), str(entry.get("name", "?"))))
	add_child(dlg)
	dlg.popup_centered()


func _on_archive_delete_confirmed(arch_id: String, arch_name: String) -> void:
	var res: Dictionary = TournamentDirector.delete_archived(arch_id)
	if not bool(res.get("ok", false)):
		log_label.text = "Delete failed: %s" % str(res.get("error", "?"))
	else:
		log_label.text = "Deleted '%s', freed %.1f MB." % [
			arch_name, float(res.get("freed_mb", 0.0))]
	refresh_vault()


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
	var gid := str(p.get("genome_id", ""))
	var gtext := "genome " + gid if gid != "" else _mix_text(p.get("experiment", "base"))
	var score: float = float(t.get("score", 0.0))
	var avg: float = float(t.get("avg_score", 0.0))
	detail_label.text = ("{name}  [{id}]\nBattles {b} (W{l} L{lo} D{d}) | " + \
		"Matches {m} (W{mw} L{ml}) | Titles {t} | ELO {elo}\nEpisodes {e} in {s} sessions | " + \
		"pre-train score {sc} (avg {asc}/ep)\n" + \
		"variant {v} seed {sd} lr {lr} gain {g} ev {ev} wiring {x} map {mp} yb {yb}\nlineage: {lin}").format({
		"name": str(selected_brain.get("name", "?")), "id": str(selected_brain.get("id", "?")),
		"b": int(r.get("battles", 0)), "l": int(r.get("wins", 0)),
		"lo": int(r.get("losses", 0)), "d": int(r.get("draws", 0)),
		"m": int(r.get("matches", 0)), "mw": int(r.get("matches_won", 0)),
		"ml": int(r.get("matches_lost", 0)), "t": int(r.get("tournaments_won", 0)),
		"elo": int(r.get("elo", 1200.0)),
		"e": int(t.get("episodes", 0)), "s": (t.get("sessions", []) as Array).size(),
		"sc": "%.0f" % score, "asc": "%.2f" % avg,
		"v": str(p.get("variant", "?")), "sd": str(p.get("seed", "?")),
		"lr": str(p.get("learning_rate", "?")), "g": str(p.get("dist_gain", "?")),
		"ev": str(p.get("evasion", "?")), "x": gtext,
		"yb": str(p.get("yaw_bias", 9.0)),
		"mp": mv_text,
		"lin": str(selected_brain.get("lineage", {}).get("source", "?"))})
	_prefill_train_widgets(p)


func _gen_params() -> Dictionary:
	var schemes: Array = []
	for cb in gen_map_checks:
		if (cb as CheckButton).button_pressed:
			schemes.append((cb as CheckButton).text)
	var genome_on := is_instance_valid(gen_genome_check) and gen_genome_check.button_pressed
	var mapping: Array = []
	if genome_on and is_instance_valid(gen_derive_check) and gen_derive_check.button_pressed \
			and bool(gen_derived.get("ok", false)):
		for m in gen_derived.get("mapping", []):
			mapping.append(str(m))
	else:
		mapping = schemes
	var out := {
		"variant": gen_variant.get_item_text(gen_variant.selected),
		"seed": int(gen_seed.value),
		"learning_rate": gen_lr.value,
		"dist_gain": gen_gain.value,
		"evasion": gen_evasion.value,
		"align_bonus": [0.5, 0.2, -0.3],
		"experiment": gen_wiring.duplicate() if not gen_wiring.is_empty() and not genome_on else null,
		"mapping": mapping if not mapping.is_empty() else null,
		"yaw_bias": snappedf(randf_range(6.0, 12.0), 0.1) if gen_yaw_random.button_pressed else float(gen_yaw_bias.value),
	}
	if genome_on:
		# Seeds rebuild the identical envelope Python-side at generate
		# and train time; the record stamps envelope + id on arrival.
		out["genome_seed"] = int(gen_genome_seed.value)
		out["genome_rules"] = int(gen_genome_rules.value)
	return out


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
		_start_or_queue(str(brain.get("id", "")),
			str(brain.get("name", "?")), int(gen_episodes.value),
			_gen_params(), "Generated '%s'")
		return
	if op == "breed_reference":
		if not result.get("ok", false):
			log_label.text = "Reference breed failed: %s" % str(result.get("error", "?"))
			return
		refresh_vault()
		var ref: Dictionary = result.get("brain", {})
		log_label.text = "Reference stock ready: '%s' - use it as crossover stock." % str(ref.get("name", "?"))


func _on_breed_reference() -> void:
	if not TournamentDirector.python_ready:
		log_label.text = "Breed failed: %s" % TournamentDirector.python_probe_error
		return
	var eps := int(gen_episodes.value)
	var school := is_instance_valid(train_school) and train_school.button_pressed
	var args := ["breed", "--strategy", "reference", "--name", "Reference",
		"--seed", str(int(gen_seed.value)), "--episodes", str(eps)]
	if school:
		var p2 := TournamentDirector.job_dir.path_join("reference_params2.json")
		var f := FileAccess.open(p2, FileAccess.WRITE)
		if f == null:
			log_label.text = "Breed failed: cannot write school params."
			return
		f.store_string('{"curriculum": {}}')
		f.close()
		args += ["--episodes2", str(eps), "--params2-file", p2]
	var result_file := TournamentDirector.job_dir.path_join("breed_reference_result.json")
	set_busy("Breeding reference stock...")
	await get_tree().process_frame
	var res: Dictionary = TournamentDirector.run_cli_async("breed_reference", args, result_file)
	if not res.get("ok", false):
		clear_busy()
		log_label.text = "Breed failed: %s" % str(res.get("error", "?"))
		return
	log_label.text = "Breeding reference stock in background (pid %s)..." % str(res.get("pid", "?"))


func _retrain_params() -> Dictionary:
	# Retraining uses the brain's own stored generator_params (wiring,
	# mapping, seed, rates), so an experiment brain can never be retrained
	# on the wrong arity via menu defaults. Only whitelisted trainer keys
	# are forwarded; episode count comes from the spinbox at call time.
	var stored: Dictionary = selected_brain.get("generator_params", {})
	var out := {}
	for k in ["variant", "seed", "learning_rate", "dist_gain", "evasion",
			"align_bonus", "experiment", "genome", "genome_id",
			"mapping", "yaw_bias"]:
		if stored.has(k):
			out[k] = stored[k]
	# Flight-school retrains run the school curriculum (scores stamped
	# like evo stage-2); unticked retrains keep legacy encounters.
	if is_instance_valid(train_school) and train_school.button_pressed:
		out["curriculum"] = {}
	return out


func _prefill_num(v, fallback: float) -> float:
	if v == null:
		return fallback
	if v is float or v is int:
		return float(v)
	return fallback


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
	# Explicit-null numerics (e.g. "yaw_bias": null on ungraduated
	# brains) must fall back like missing keys: float(null) crashes.
	gen_seed.value = _prefill_num(p.get("seed"), gen_seed.value)
	gen_lr.value = _prefill_num(p.get("learning_rate"), gen_lr.value)
	gen_gain.value = _prefill_num(p.get("dist_gain"), gen_gain.value)
	gen_evasion.value = _prefill_num(p.get("evasion"), gen_evasion.value)
	gen_yaw_bias.value = _prefill_num(p.get("yaw_bias"), 9.0)
	gen_yaw_random.button_pressed = false
	var exp = p.get("experiment", null)
	var raw: Array = []
	if exp is Array:
		raw = (exp as Array).duplicate()
	elif exp != null:
		var s := str(exp).strip_edges()
		if s.begins_with("__exp_"):
			s = s.trim_prefix("__exp_")
		if s.contains("__"):
			for part in s.split("__"):
				raw.append(part)
		elif s.contains("+"):
			for part in s.split("+"):
				raw.append(part)
		elif s.to_lower() not in ["", "none", "base"]:
			raw.append(s)
	var known: Array = []
	for opt in WIRING_OPTIONS:
		known.append(opt[0])
	gen_wiring.clear()
	for n in raw:
		var t := str(n).strip_edges()
		if known.has(t) and not gen_wiring.has(t):
			gen_wiring.append(t)
	for cb in gen_wire_checks:
		(cb as CheckButton).set_pressed_no_signal(gen_wiring.has((cb as CheckButton).text))
	_update_config_summary()
	var mv = p.get("mapping", null)
	var active: Array = []
	if mv is Array:
		active = mv
	elif mv != null and str(mv).strip_edges().to_lower() not in ["", "none", "base"]:
		active = [str(mv)]
	for cb in gen_map_checks:
		(cb as CheckButton).button_pressed = active.has((cb as CheckButton).text)


func _start_or_queue(bid: String, bname: String, eps: int,
		params: Dictionary, done_fmt: String) -> void:
	# Single choke point for starting training: runs now when the worker
	# slot is free and nothing waits, otherwise joins the FIFO queue
	# (the pump starts it automatically). done_fmt formats the log line
	# with the brain name, e.g. "Generated '%s'".
	if TournamentDirector.active_job.is_empty() \
			and TournamentDirector.train_queue.is_empty():
		var res: Dictionary = TournamentDirector.start_training(bid, eps, params)
		if res.get("ok", false):
			job_bar.value = 0.0
			job_label.text = "Training %s ..." % bname
			log_label.text = (done_fmt % bname) + " - training in background."
		else:
			job_label.text = "Train failed: %s" % res.get("error", "?")
		return
	var pos: int = TournamentDirector.enqueue_training(bid, bname, eps, params)
	TournamentDirector.pump_train_queue()
	log_label.text = (done_fmt % bname) + " - queued #%d." % pos


func _on_train() -> void:
	if selected_brain.is_empty():
		log_label.text = "Select a brain first."
		return
	var school := is_instance_valid(train_school) and train_school.button_pressed
	_start_or_queue(str(selected_brain.get("id", "")),
		str(selected_brain.get("name", "?")), int(gen_episodes.value),
		_retrain_params(),
		"Training '%s' (school)" if school else "Training '%s'")


func _on_queue_remove() -> void:
	var sel := queue_list.get_selected_items()
	if sel.is_empty():
		return
	TournamentDirector.cancel_queued(int(sel[0]))


func _on_queue_clear() -> void:
	TournamentDirector.clear_train_queue()


func _queue_suffix() -> String:
	var n := TournamentDirector.train_queue.size()
	return "" if n == 0 else " (+%d queued)" % n


func _refresh_train_queue() -> void:
	if not is_instance_valid(queue_list):
		return
	queue_list.clear()
	var q: Array = TournamentDirector.train_queue
	queue_label.text = "TRAINING QUEUE (%d)" % q.size()
	for i in range(q.size()):
		var item: Dictionary = q[i]
		queue_list.add_item("%d. %s - %d ep" % [i + 1,
			str(item.get("name", "?")), int(item.get("episodes", 0))])
	if is_instance_valid(job_label) and not _job_base.is_empty():
		job_label.text = _job_base + _queue_suffix()


func _on_job_progress(episode: int, total: int) -> void:
	if total > 0:
		job_bar.value = 100.0 * episode / total
		_job_base = "Training... episode %d / %d" % [episode, total]
		job_label.text = _job_base + _queue_suffix()
		if episode >= total:
			_job_base = ""
			refresh_vault()


func _on_job_failed(error: String) -> void:
	_job_base = ""
	job_label.text = "Train failed: %s" % error
	log_label.text = "Train failed: %s" % error


func _on_score_stamped(brain_id: String, score: float) -> void:
	log_label.text = "Probe banked +%.1f points for %s." % [score, brain_id]
	refresh_vault()


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
	var res: Dictionary = TournamentDirector.build_bracket(ids, size, bestof, tourney_lr.value, tourney_round_time.value, false, [], tourney_random.button_pressed, tourney_consolation.button_pressed)
	if not res.get("ok", false):
		bracket_status.text = "Cannot start: %s" % str(res.get("error", "?"))
		return
	bracket_status.text = "Tournament %s ready (%s%s)." % [str(res.get("tournament_id", "")),
		"random draw" if tourney_random.button_pressed else "strength seeded",
		" + losers" if tourney_consolation.button_pressed else ""]


func _on_start_evolution() -> void:
	# Eternal evolution loop: same setup as a tournament, then the arena
	# chains generations automatically (archive loser, breed clone +
	# random, next bracket) until EVO STOP. Offspring train 50 eps.
	var size := int(TournamentDirector.size_options()[tourney_size.selected])
	var bestof := int(TournamentDirector.best_of_options()[tourney_bestof.selected])
	var ids := _selected_player_ids()
	# Evolution demands a FULL roster: a short bracket yields 7 (or 3)
	# round-0 losers, consolation can never start (needs 2/4/8), and
	# the shortness self-perpetuates every generation after.
	if ids.size() != size:
		bracket_status.text = "Evolution needs a full %d-brain roster (picked %d) - Ctrl+click to fill it." % [size, ids.size()]
		return
	# Evo always runs the losers bracket: bottom-two elimination must
	# come through combat, never the ranking fallback.
	var res: Dictionary = TournamentDirector.build_bracket(ids, size, bestof, tourney_lr.value, tourney_round_time.value, false, [], tourney_random.button_pressed, true)
	if not res.get("ok", false):
		bracket_status.text = "Cannot start: %s" % str(res.get("error", "?"))
		return
	TournamentDirector.tourney["evo"] = {"active": true, "generation": 1,
		"episodes": 50,
		"mutate_traits": 1 if is_instance_valid(evo_mutate_traits)
			and evo_mutate_traits.button_pressed else 0}
	TournamentDirector.save_state()
	bracket_status.text = "EVOLUTION gen 1 ready (%s)." % str(res.get("tournament_id", ""))
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
	var res: Dictionary = TournamentDirector.start_quick_battle(str(ids[0]), str(ids[1]), tourney_random.button_pressed)
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
