extends Node3D

const BrainClientScript = preload("res://scripts/BrainClient.gd")
const FlyPhysicsScript = preload("res://scripts/FlyPhysics.gd")
const BracketView = preload("res://scripts/TournamentBracket.gd")

@export var round_time_limit: float = 40.0
var current_round_time: float = 0.0
var current_generation: int = 1
var is_round_active: bool = true

var stats_alpha := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
var stats_beta  := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }

# Session win tally (natural + restarted rounds, server-judged)
var wins_alpha: int = 0
var wins_beta: int = 0

# Health / wing / hit-feedback HUD (built procedurally, no scene edits)
var alpha_health_bar: ProgressBar
var beta_health_bar: ProgressBar
var alpha_wing_l: Label
var alpha_wing_r: Label
var beta_wing_l: Label
var beta_wing_r: Label
var alpha_row_name: Label
var beta_row_name: Label
var alpha_hit_flash: ColorRect
var beta_hit_flash: ColorRect

# Dynamic tree fade: trees sitting on the camera->fly line go translucent so
# the fight stays visible; everything else stays solid. Rebuilt per frame.
const TREE_FADE_ALPHA: float = 0.30
const TREE_FADE_SMOOTH: float = 10.0
var tree_sight_entries: Array = []

# Round-end winner overlay: big name + next-round countdown (procedural)
var winner_overlay: Control
var winner_label: Label
var countdown_label: Label

# Tournament mode (driven by the TournamentDirector autoload; off = classic
# free battle with generational evolution).
var tournament_active: bool = false
var tourney_a_name: String = "ALPHA"
var tourney_b_name: String = "BETA"
var tourney_match_label: String = ""
var tourney_awaiting_load: bool = false
var bracket_overlay: Control
var arena_bracket: BracketView
var bracket_title: Label
var bracket_button: Button

# Sequencing watchdog: every tournament server round-trip arms a deadline.
# Load/reset/battle retry the pending request once, then fail loudly
# (overlay + status + server_log.txt pointer). Battle retries are safe:
# the server answers a resent round_over (same tournament/match/battle
# id) from its persisted verdict instead of banking twice. A late reply
# arriving after a fail-loud timeout is dropped, never applied twice.
var _seq_context: String = "" # "" | "load" | "reset" | "battle"
var _seq_deadline_msec: int = 0
var _seq_retried: bool = false
var _seq_last_load: Dictionary = {}
var _seq_last_round: Dictionary = {}
const SEQ_TIMEOUT_MSEC: int = 30000
const SEQ_BATTLE_TIMEOUT_MSEC: int = 30000
# Id for the in-flight battle (match + battle number). Echoed by the
# server for log correlation AND the idempotency key for safe retries.
var _seq_battle_id: String = ""
# True between sending round_over and applying tournament_battle. Guards
# late/duplicate replies after a fail-loud timeout.
var _tourney_awaiting_battle: bool = false
# Title handshake: set when the server acks tournament_closed (champion
# file written). The arena only quits to menu after this, so vault stats
# shown there always include the fresh title.
var _tourney_close_ack: bool = false

@onready var brain_client: Node = $BrainClient
@onready var fly_alpha: CharacterBody3D = $FlyAlpha
@onready var fly_beta: CharacterBody3D = $FlyBeta
@onready var arena_camera: Camera3D = $ArenaCamera

# UI Labels
@onready var gen_label: Label = $HUD/Margin/VBox/GenLabel
@onready var timer_label: Label = $HUD/Margin/VBox/TimerLabel
@onready var status_label: Label = $HUD/Margin/VBox/StatusLabel
@onready var brain_alpha_label: Label = $HUD/Margin/VBox/BrainAlphaLabel
@onready var brain_beta_label: Label = $HUD/Margin/VBox/BrainBetaLabel
@onready var merge_button: Button = $HUD/Margin/VBox/MergeButton
@onready var restart_button: Button = $HUD/Margin/VBox/RestartButton
@onready var win_label: Label = $HUD/Margin/VBox/WinLabel
@onready var pip_alpha_cam: Camera3D = $HUD/PiPAlpha/PiPAlphaView/PiPCamAlpha
@onready var pip_beta_cam: Camera3D = $HUD/PiPBeta/PiPBetaView/PiPCamBeta
@onready var pip_alpha_feat: Label = $HUD/PiPAlphaFeat
@onready var pip_beta_feat: Label = $HUD/PiPBetaFeat
@onready var pip_alpha_label: Label = $HUD/PiPAlphaLabel
@onready var pip_beta_label: Label = $HUD/PiPBetaLabel

# Display name for a slot: the assigned brain name in tournament/quick
# battles, plain ALPHA/BETA in free battle (no vault identities there).
func _slot_name(slot: String) -> String:
	if tournament_active:
		return tourney_a_name if slot == "alpha" else tourney_b_name
	return slot.to_upper()

func refresh_slot_names() -> void:
	# Pushes current display names into every static battle-UI label.
	# Called whenever a new match's brains are known.
	var na := _slot_name("alpha")
	var nb := _slot_name("beta")
	if is_instance_valid(alpha_row_name):
		alpha_row_name.text = na
	if is_instance_valid(beta_row_name):
		beta_row_name.text = nb
	if is_instance_valid(pip_alpha_label):
		pip_alpha_label.text = na + " EYES - raw (pre-brain)"
	if is_instance_valid(pip_beta_label):
		pip_beta_label.text = nb + " EYES - raw (pre-brain)"
	_update_win_label()

var brain_tick_timer: float = 0.0
const BRAIN_TICK_DT: float = 0.05 # 50 ms (20 Hz)

const FOREST_TREE_COUNT: int = 16
const FOREST_HALF_EXTENT: float = 38.0
const FOREST_MIN_SPACING: float = 7.0
const FOREST_SPAWN_CLEAR: float = 8.0
const FOREST_CENTER_CLEAR: float = 10.0
# Horizon dressing: visual-only trees out to rendering range (no collision,
# the soft boundary keeps fights well inside). Cheap shared meshes.
const HORIZON_TREE_COUNT: int = 220
const HORIZON_RING_MIN: float = 45.0
const HORIZON_RING_MAX: float = 180.0

func _ready() -> void:
	fly_alpha.fly_id = "alpha"
	fly_beta.fly_id = "beta"
	fly_alpha.set_team_color(Color(1.0, 0.35, 0.1))
	fly_beta.set_team_color(Color(0.15, 0.6, 1.0))
	if is_instance_valid(brain_alpha_label):
		brain_alpha_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.3))
	if is_instance_valid(brain_beta_label):
		brain_beta_label.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	_update_win_label()
	fly_alpha.rival = fly_beta
	fly_beta.rival = fly_alpha

	fly_alpha.knocked_out.connect(func(): _on_fly_knocked_out("alpha"))
	fly_beta.knocked_out.connect(func(): _on_fly_knocked_out("beta"))

	fly_alpha.landed_strike.connect(func(part): _on_strike_landed("alpha", part))
	fly_beta.landed_strike.connect(func(part): _on_strike_landed("beta", part))

	fly_alpha.wing_torn.connect(func(side): _on_wing_torn("alpha", side))
	fly_beta.wing_torn.connect(func(side): _on_wing_torn("beta", side))

	brain_client.motor_controls_received.connect(_on_motor_controls)
	brain_client.generation_advanced.connect(_on_generation_advanced)
	brain_client.merged.connect(_on_merged)
	brain_client.restarted.connect(_on_restarted)
	brain_client.tournament_battle_received.connect(_on_tournament_battle)
	brain_client.brains_loaded.connect(_on_brains_loaded)
	brain_client.match_ready_received.connect(_on_match_ready)
	brain_client.server_error_received.connect(_on_server_error)
	# Title ack: the server replies tournament_closed AFTER the champion's
	# file is written. The arena waits for it before leaving, so the menu
	# can never display a stale (pre-title) vault.
	brain_client.tournament_closed_received.connect(func(): _tourney_close_ack = true)
	if is_instance_valid(merge_button):
		merge_button.pressed.connect(_on_merge_pressed)
	if is_instance_valid(restart_button):
		restart_button.pressed.connect(_on_restart_pressed)

	_build_health_hud()
	_build_hit_flash()
	_build_winner_overlay()
	_generate_forest()
	_setup_dynamic_tree_opacity()
	# Tournament battles are sequenced by the director (brains load first);
	# free battle starts immediately as before.
	var director := _director()
	if director != null and director.tournament_active():
		_enter_tournament_mode()
	else:
		# Classic free battle: make sure the server left any tournament /
		# quick brains behind and restored the boot variants.
		_build_menu_bar(false)
		brain_client.request_free_mode()
		_reset_round()

func _director() -> Node:
	return get_node_or_null("/root/TournamentDirector")

func _enter_tournament_mode() -> void:
	tournament_active = true
	var director := _director()
	director.arena = self
	_build_bracket_overlay()
	_build_menu_bar(true)
	_request_current_battle_load()


# Compact bottom-center menu bar: keeps Quit/Restart/Bracket/Merge out of
# the left info column (and the fight view). The in-column scene buttons
# are hidden; the bar buttons drive the same handlers.
func _build_menu_bar(tournament: bool) -> void:
	var hud: CanvasLayer = $HUD
	var bar := HBoxContainer.new()
	bar.name = "MenuBar"
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -46.0
	bar.offset_bottom = -10.0
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 10)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(bar)
	if tournament:
		if is_instance_valid(merge_button):
			merge_button.visible = false
		if is_instance_valid(restart_button):
			restart_button.visible = false
		var quit_b := _menu_bar_button("QUIT TO MENU", "Leave to the vault menu.")
		quit_b.pressed.connect(_on_quit_to_menu)
		bar.add_child(quit_b)
		bracket_button = _menu_bar_button("BRACKET", "Show/hide the tournament bracket.")
		bracket_button.pressed.connect(_on_bracket_toggle)
		bar.add_child(bracket_button)
	else:
		if is_instance_valid(merge_button):
			merge_button.visible = false
		if is_instance_valid(restart_button):
			restart_button.visible = false
		var merge_b := _menu_bar_button("MERGE", "Merge brains (Alpha x Beta -> Beta).")
		merge_b.pressed.connect(_on_merge_pressed)
		bar.add_child(merge_b)
		var restart_b := _menu_bar_button("RESTART", "Restart the round (banks rewards).")
		restart_b.pressed.connect(_on_restart_pressed)
		bar.add_child(restart_b)


func _menu_bar_button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(130, 30)
	b.add_theme_font_size_override("font_size", 13)
	b.modulate = Color(1, 1, 1, 0.85)
	return b

func _build_bracket_overlay() -> void:
	# Full-screen bracket graph: title + scrollable TournamentBracket +
	# close. Hidden by default; auto-shown when a match completes.
	var hud: CanvasLayer = $HUD
	bracket_overlay = Control.new()
	bracket_overlay.name = "BracketOverlay"
	bracket_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	bracket_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_overlay.visible = false
	hud.add_child(bracket_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.05, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(880, 600)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.09, 0.98)
	sb.border_color = Color(0.4, 0.4, 0.46)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)
	bracket_title = Label.new()
	bracket_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bracket_title.add_theme_font_size_override("font_size", 22)
	vb.add_child(bracket_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vb.add_child(scroll)
	arena_bracket = BracketView.new()
	arena_bracket.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arena_bracket.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(arena_bracket)
	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.pressed.connect(_hide_arena_bracket)
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_child(close_btn)
	vb.add_child(hbox)

func _show_arena_bracket(title_text: String) -> void:
	var director := _director()
	if director == null or arena_bracket == null:
		return
	bracket_title.text = title_text
	arena_bracket.render_bracket(director.tourney,
		int(director.tourney.get("current_round", 0)),
		int(director.tourney.get("current_match", 0)))
	bracket_overlay.visible = true

func _hide_arena_bracket() -> void:
	if bracket_overlay != null:
		bracket_overlay.visible = false

func _on_bracket_toggle() -> void:
	if bracket_overlay != null and bracket_overlay.visible:
		_hide_arena_bracket()
	elif tournament_active:
		_show_arena_bracket("%s  %s vs %s" % [tourney_match_label, tourney_a_name, tourney_b_name])

func _on_quit_to_menu() -> void:
	var director := _director()
	if director != null:
		director.quit_to_menu()

func _request_current_battle_load() -> void:
	var director := _director()
	if director == null:
		return
	# Walk past resolved byes / walkovers first (round-0 leading byes and
	# legacy unresolved-bye states), so we never request a load with an
	# empty brain path and stall waiting for brains that never come.
	var skip: Dictionary = director.skip_unplayable()
	if str(skip.get("action", "")) == "tournament_end":
		_handle_advance_result(skip)
		return
	if str(skip.get("action", "")) != "next_match":
		if is_instance_valid(status_label):
			status_label.text = "BRACKET STALLED - QUIT TO MENU AND RESUME"
		return
	var p: Dictionary = director.get_load_params()
	if str(p.get("alpha_path", "")) == "" or str(p.get("beta_path", "")) == "":
		if is_instance_valid(status_label):
			status_label.text = "CANNOT LOAD %s - brain file missing, QUIT TO MENU" % tourney_match_label
		return
	print("[Arena] Requesting tournament load: %s (%s vs %s)" % [
		str(p.get("match", "?")), str(p.get("a_name", "?")), str(p.get("b_name", "?"))])
	tourney_a_name = str(p.get("a_name", "ALPHA"))
	tourney_b_name = str(p.get("b_name", "BETA"))
	tourney_match_label = str(p.get("match", ""))
	tourney_awaiting_load = true
	_hide_arena_bracket()
	refresh_slot_names()
	# Freeze the arena while the server swaps brains: no steps go out, so
	# the flies can never fight a round on stale/boot brains ("only
	# charges" first-battle bug). A persistent loading callout proves the
	# game is working, not frozen.
	is_round_active = false
	_show_loading("LOADING %s" % tourney_match_label,
		"%s vs %s - brains loading..." % [tourney_a_name, tourney_b_name])
	if is_instance_valid(status_label):
		status_label.text = "LOADING %s vs %s ..." % [tourney_a_name, tourney_b_name]
	brain_client.request_tournament_load(
		str(p.get("alpha_path", "")), str(p.get("beta_path", "")),
		str(p.get("tournament_id", "")), tourney_match_label,
		float(p.get("lr_scale", 0.5)))
	_seq_last_load = {
		"alpha_path": str(p.get("alpha_path", "")),
		"beta_path": str(p.get("beta_path", "")),
		"tournament_id": str(p.get("tournament_id", "")),
		"match": tourney_match_label,
		"lr_scale": float(p.get("lr_scale", 0.5))}
	_arm_seq("load")

func _on_brains_loaded(_alpha_info: Dictionary, _beta_info: Dictionary) -> void:
	if not tournament_active:
		return
	if not tourney_awaiting_load and _seq_context != "load":
		return
	_clear_seq()
	tourney_awaiting_load = false
	_hide_loading()
	_update_tourney_status("READY")
	_reset_round()

func _on_match_ready() -> void:
	if not tournament_active:
		return
	if _seq_context != "reset":
		return
	_clear_seq()
	_hide_loading()
	_reset_round()

func _on_server_error(error: String) -> void:
	# An explicit server error explains any stall. If it hit an in-flight
	# battle report, retry once with the SAME battle id (the server answers
	# repeats from its stored verdict, so this cannot double-count).
	# Anything else stands the watchdog down so retry text never overwrites
	# the real reason; a late battle reply is dropped, never applied twice.
	if _seq_context == "battle" and _tourney_awaiting_battle \
			and not _seq_retried and not _seq_last_round.is_empty():
		_seq_retried = true
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("battle")
		var q := _seq_last_round
		print("[Arena] Battle report errored (%s); retrying same id=" % error,
			_seq_battle_id)
		_show_loading("BATTLE REPORT ERRORED - RETRYING",
			"Server error: %s. Re-sending the SAME report id %s " % [error, _seq_battle_id]
			+ "(the server answers repeats from its stored verdict, no double count)...")
		if is_instance_valid(status_label):
			status_label.text = "BATTLE ERROR - RETRYING %s ..." % _seq_battle_id
		brain_client.send_round_over(q.get("stats_a", {}), q.get("stats_b", {}),
			bool(q.get("draw", false)), _seq_battle_id,
			str(q.get("tournament_id", "")), str(q.get("match", "")))
		return
	_tourney_awaiting_battle = false
	_clear_seq()
	_show_loading("SERVER ERROR",
		"SERVER ERROR: %s. " % error
		+ "See server_log.txt, then QUIT TO MENU + RESUME.")
	if is_instance_valid(status_label):
		status_label.text = "SERVER ERROR: " + error

func _update_tourney_status(prefix: String) -> void:
	var director := _director()
	var score := ""
	if director != null:
		var m: Dictionary = director.current_match()
		if not m.is_empty():
			score = "  [%d - %d]" % [int(m.get("wins_a", 0)), int(m.get("wins_b", 0))]
	if is_instance_valid(status_label):
		status_label.text = "%s %s: %s vs %s%s" % [tourney_match_label, prefix,
			tourney_a_name, tourney_b_name, score]
	if is_instance_valid(gen_label) and director != null:
		if director.is_quick():
			gen_label.text = "QUICK BATTLE"
		else:
			gen_label.text = "TOURNEY %s" % str(director.tourney.get("id", ""))

func _generate_forest() -> void:
	# Procedural forest ring: deterministic seed so every run (and every
	# training-matched experiment) uses the same obstacle layout. Trunks get
	# real collision (group "obstacle") so crashes hurt; canopies are visual.
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	# Decoration RNG: drives ALL visual variance (lean, blobs, hue, bushes)
	# so the layout stream above stays bit-identical to previous builds.
	var decor := RandomNumberGenerator.new()
	decor.seed = 778
	var forest_root = $TreePerimeter

	var forest_body := StaticBody3D.new()
	forest_body.name = "ForestBody"
	forest_body.add_to_group("obstacle")
	forest_root.add_child(forest_body)

	# The 4 hand-placed arena trees get the rich build too (visual only,
	# exactly like before: no collision was ever attached to them). Each
	# gets its own material pair so the fade system treats them separately.
	for hand in forest_root.get_children():
		if hand is StaticBody3D or not (hand is Node3D):
			continue
		if not str(hand.name).begins_with("Tree"):
			continue
		for old in (hand as Node3D).get_children():
			(hand as Node3D).remove_child(old)
			old.queue_free()
		var htmat := StandardMaterial3D.new()
		htmat.albedo_color = Color(
			decor.randf_range(0.30, 0.38), decor.randf_range(0.19, 0.24), decor.randf_range(0.10, 0.13))
		htmat.roughness = 0.9
		htmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var hcmat := StandardMaterial3D.new()
		hcmat.albedo_color = Color(
			decor.randf_range(0.15, 0.23), decor.randf_range(0.36, 0.46), decor.randf_range(0.11, 0.17))
		hcmat.roughness = 0.85
		hcmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_build_tree_visuals(hand, decor, htmat, hcmat, true)
		hand.set_meta("fades", true)
	print("[Arena] Hand-placed trees rebuilt: 4.")

	var placed: Array[Vector2] = []
	var spawn_a := Vector2(-14, 0)
	var spawn_b := Vector2(14, 0)
	var made := 0
	var tries := 0
	while made < FOREST_TREE_COUNT and tries < FOREST_TREE_COUNT * 60:
		tries += 1
		var p := Vector2(
			rng.randf_range(-FOREST_HALF_EXTENT, FOREST_HALF_EXTENT),
			rng.randf_range(-FOREST_HALF_EXTENT, FOREST_HALF_EXTENT))
		# Keep spawn pads and the opening-joust center clean; trees rule
		# everywhere else. Wide spacing keeps every trunk dodgeable.
		if p.distance_to(spawn_a) < FOREST_SPAWN_CLEAR:
			continue
		if p.distance_to(spawn_b) < FOREST_SPAWN_CLEAR:
			continue
		if p.length() < FOREST_CENTER_CLEAR:
			continue
		var crowded := false
		for q in placed:
			if p.distance_to(q) < FOREST_MIN_SPACING:
				crowded = true
				break
		if crowded:
			continue
		placed.append(p)
		made += 1
		var s = rng.randf_range(0.8, 1.4)
		var tree := Node3D.new()
		tree.position = Vector3(p.x, 0, p.y)
		tree.rotation.y = rng.randf_range(0.0, TAU)
		tree.scale = Vector3(s, s, s)
		forest_root.add_child(tree)
		# Per-tree opaque materials (alpha driven by the fade system) with
		# slight hue variation so the forest doesn't look stamped.
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(
			decor.randf_range(0.30, 0.38), decor.randf_range(0.19, 0.24), decor.randf_range(0.10, 0.13))
		tmat.roughness = 0.9
		tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color(
			decor.randf_range(0.15, 0.23), decor.randf_range(0.36, 0.46), decor.randf_range(0.11, 0.17))
		cmat.roughness = 0.85
		cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_build_tree_visuals(tree, decor, tmat, cmat, true)
		tree.set_meta("fades", true)
		var col := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.8 * s
		shape.height = 16.0 * s
		col.shape = shape
		# NOTE: shape node must live under the StaticBody; offset it to the
		# tree position since it can't be a child of the visual Node3D.
		col.position = Vector3(p.x, 8.0 * s, p.y)
		forest_body.add_child(col)
	print("[Arena] Procedural forest: ", made, " trees + 4 hand-placed.")

	# Horizon ring: sparse giants to the rendering horizon, visuals only.
	var bark_opaque := StandardMaterial3D.new()
	bark_opaque.albedo_color = Color(0.32, 0.20, 0.11)
	bark_opaque.roughness = 0.9
	var canopy_opaque_a := StandardMaterial3D.new()
	canopy_opaque_a.albedo_color = Color(0.16, 0.38, 0.13)
	canopy_opaque_a.roughness = 0.85
	var canopy_opaque_b := StandardMaterial3D.new()
	canopy_opaque_b.albedo_color = Color(0.22, 0.44, 0.15)
	canopy_opaque_b.roughness = 0.85
	var h_made := 0
	var h_tries := 0
	while h_made < HORIZON_TREE_COUNT and h_tries < HORIZON_TREE_COUNT * 20:
		h_tries += 1
		var hang = rng.randf_range(0.0, TAU)
		var hrad = HORIZON_RING_MIN + (HORIZON_RING_MAX - HORIZON_RING_MIN) * sqrt(rng.randf())
		var hp := Vector2(cos(hang) * hrad, sin(hang) * hrad)
		var hs = rng.randf_range(1.0, 2.2)
		var htree := Node3D.new()
		htree.position = Vector3(hp.x, 0, hp.y)
		htree.rotation.y = rng.randf_range(0.0, TAU)
		htree.scale = Vector3(hs, hs, hs)
		forest_root.add_child(htree)
		_build_tree_visuals(htree, decor, bark_opaque,
			canopy_opaque_a if h_made % 2 == 0 else canopy_opaque_b, false)
		h_made += 1
	print("[Arena] Horizon forest: ", h_made, " distant trees.")
	_build_underbrush(forest_root, decor, placed, spawn_a, spawn_b)


# Shared procedural tree/dressing meshes, built once and reused by every
# tree so the forest stays cheap despite the richer geometry.
var _tree_mesh_cache := {}

func _tree_mesh(key: String) -> Mesh:
	if _tree_mesh_cache.has(key):
		return _tree_mesh_cache[key]
	var m: Mesh = null
	match key:
		"trunk_low":
			var c := CylinderMesh.new()
			c.top_radius = 0.55
			c.bottom_radius = 0.85
			c.height = 8.0
			c.radial_segments = 9
			m = c
		"trunk_top":
			var c := CylinderMesh.new()
			c.top_radius = 0.35
			c.bottom_radius = 0.55
			c.height = 8.0
			c.radial_segments = 9
			m = c
		"flare":
			var c := CylinderMesh.new()
			c.top_radius = 0.85
			c.bottom_radius = 1.50
			c.height = 1.8
			c.radial_segments = 9
			m = c
		"blob":
			var s := SphereMesh.new()
			s.radius = 2.4
			s.height = 4.4
			s.radial_segments = 9
			s.rings = 6
			m = s
		"blob_small":
			var s := SphereMesh.new()
			s.radius = 1.6
			s.height = 3.0
			s.radial_segments = 8
			s.rings = 5
			m = s
		"bush":
			var s := SphereMesh.new()
			s.radius = 1.15
			s.height = 1.70
			s.radial_segments = 8
			s.rings = 5
			m = s
		"rock":
			var s := SphereMesh.new()
			s.radius = 0.80
			s.height = 1.10
			s.radial_segments = 7
			s.rings = 4
			m = s
		"grass":
			var c := CylinderMesh.new()
			c.top_radius = 0.02
			c.bottom_radius = 0.11
			c.height = 1.1
			c.radial_segments = 5
			m = c
	_tree_mesh_cache[key] = m
	return m


func _add_tree_part(parent: Node3D, pname: String, mesh: Mesh, pos: Vector3, mat: Material, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = pname
	mi.mesh = mesh
	mi.position = pos
	mi.scale = scl
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _build_tree_visuals(parent: Node3D, decor: RandomNumberGenerator, tmat: Material, cmat: Material, full: bool) -> void:
	# Every section provably overlaps the one below: the upper trunk pivots
	# about its own base (fixed inside the lower trunk), and each canopy
	# blob center sits well within (main + side radii - margin) of its
	# parent blob. Mesh names feed the dynamic-fade system.
	_add_tree_part(parent, "Roots", _tree_mesh("flare"), Vector3(0, 0.9, 0), tmat)
	_add_tree_part(parent, "Trunk", _tree_mesh("trunk_low"), Vector3(0, 4.6, 0), tmat)
	var tilt_ang := decor.randf_range(0.0, 0.07)
	var tilt_az := decor.randf_range(0.0, TAU)
	var tilt_dir := Vector3(cos(tilt_az), 0.0, sin(tilt_az))
	var axis := Vector3.UP.cross(tilt_dir)
	if axis.length() < 0.01:
		axis = Vector3.RIGHT
	var top_basis := Basis(axis.normalized(), tilt_ang)
	var top_base := Vector3(0, 7.4, 0)
	var top_part := _add_tree_part(parent, "TrunkTop", _tree_mesh("trunk_top"), top_base, tmat)
	top_part.position = top_base + top_basis * Vector3(0, 4.0, 0)
	top_part.basis = top_basis
	var top_pos: Vector3 = top_base + top_basis * Vector3(0, 8.0, 0)
	var canopy_main := top_pos + Vector3(0, 1.2, 0)
	_add_tree_part(parent, "Canopy", _tree_mesh("blob"), canopy_main, cmat,
		Vector3(1.15, 0.90, 1.15))
	var a2 := decor.randf_range(0.0, TAU)
	var side_dir := Vector3(cos(a2), 0.0, sin(a2))
	_add_tree_part(parent, "Canopy2", _tree_mesh("blob"),
		canopy_main + side_dir * 1.8 + Vector3(0, -1.0, 0), cmat,
		Vector3(0.72, 0.58, 0.72))
	if full:
		_add_tree_part(parent, "Canopy3", _tree_mesh("blob_small"),
			canopy_main + tilt_dir * 0.2 + Vector3(0, 2.4, 0), cmat,
			Vector3(1.0, 0.90, 1.0))


func _build_underbrush(forest_root: Node3D, decor: RandomNumberGenerator, placed: Array, spawn_a: Vector2, spawn_b: Vector2) -> void:
	# Bushes, rocks and grass tufts: visual-only dressing that fills the
	# glade floor. Positions use the decor stream; the tree layout above
	# is untouched.
	var under := Node3D.new()
	under.name = "Underbrush"
	forest_root.add_child(under)
	var bush_mat_a := StandardMaterial3D.new()
	bush_mat_a.albedo_color = Color(0.13, 0.30, 0.11)
	bush_mat_a.roughness = 0.9
	var bush_mat_b := StandardMaterial3D.new()
	bush_mat_b.albedo_color = Color(0.18, 0.36, 0.13)
	bush_mat_b.roughness = 0.9
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.45, 0.44, 0.42)
	rock_mat.roughness = 0.95
	var grass_mat := StandardMaterial3D.new()
	grass_mat.albedo_color = Color(0.24, 0.47, 0.17)
	grass_mat.roughness = 0.9
	var spots: Array[Vector2] = []
	var made_bush := 0
	var tries := 0
	while made_bush < 26 and tries < 800:
		tries += 1
		var bp := Vector2(decor.randf_range(-36.0, 36.0), decor.randf_range(-36.0, 36.0))
		if bp.distance_to(spawn_a) < 6.0 or bp.distance_to(spawn_b) < 6.0 or bp.length() < 5.0:
			continue
		var clear := true
		for q in placed:
			if bp.distance_to(q) < 3.5:
				clear = false
				break
		if not clear:
			continue
		spots.append(bp)
		made_bush += 1
		var bush := MeshInstance3D.new()
		bush.mesh = _tree_mesh("bush")
		bush.position = Vector3(bp.x, 0.55, bp.y)
		bush.rotation.y = decor.randf_range(0.0, TAU)
		var bs := decor.randf_range(0.7, 1.5)
		bush.scale = Vector3(bs, bs * decor.randf_range(0.60, 0.80), bs)
		bush.material_override = bush_mat_a if made_bush % 2 == 0 else bush_mat_b
		under.add_child(bush)
	var made_rock := 0
	tries = 0
	while made_rock < 12 and tries < 400:
		tries += 1
		var rp := Vector2(decor.randf_range(-36.0, 36.0), decor.randf_range(-36.0, 36.0))
		if rp.distance_to(spawn_a) < 5.0 or rp.distance_to(spawn_b) < 5.0 or rp.length() < 4.0:
			continue
		var clear := true
		for q in placed:
			if rp.distance_to(q) < 2.5:
				clear = false
				break
		if not clear:
			continue
		made_rock += 1
		var rock := MeshInstance3D.new()
		rock.mesh = _tree_mesh("rock")
		rock.position = Vector3(rp.x, 0.25, rp.y)
		rock.rotation = Vector3(decor.randf_range(-0.2, 0.2), decor.randf_range(0.0, TAU), decor.randf_range(-0.2, 0.2))
		rock.scale = Vector3(decor.randf_range(0.8, 1.8), decor.randf_range(0.5, 0.8), decor.randf_range(0.8, 1.6))
		rock.material_override = rock_mat
		under.add_child(rock)
	var made_grass := 0
	for i in range(70):
		var gp := Vector2(decor.randf_range(-38.0, 38.0), decor.randf_range(-38.0, 38.0))
		if gp.distance_to(spawn_a) < 3.0 or gp.distance_to(spawn_b) < 3.0:
			continue
		made_grass += 1
		for b in range(3):
			var blade := MeshInstance3D.new()
			blade.mesh = _tree_mesh("grass")
			blade.position = Vector3(gp.x + decor.randf_range(-0.4, 0.4), 0.45, gp.y + decor.randf_range(-0.4, 0.4))
			blade.rotation = Vector3(decor.randf_range(-0.15, 0.15), decor.randf_range(0.0, TAU), decor.randf_range(-0.15, 0.15))
			var gs := decor.randf_range(0.7, 1.3)
			blade.scale = Vector3(gs, gs, gs)
			blade.material_override = grass_mat
			under.add_child(blade)
	print("[Arena] Underbrush: ", made_bush, " bushes, ", made_rock, " rocks, ", made_grass, " grass tufts.")

func _seq_timeout_for(context: String) -> int:
	if context == "battle":
		return SEQ_BATTLE_TIMEOUT_MSEC
	return SEQ_TIMEOUT_MSEC

func _arm_seq(context: String) -> void:
	_seq_context = context
	_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for(context)
	_seq_retried = false

func _clear_seq() -> void:
	_seq_context = ""
	_seq_battle_id = ""
	_seq_last_round = {}

func _check_seq_watchdog() -> void:
	if _seq_context == "":
		return
	if Time.get_ticks_msec() < _seq_deadline_msec:
		return
	if not tournament_active:
		_clear_seq()
		return
	print("[Arena] Sequencing watchdog fired (context=", _seq_context,
		" retry_sent=", _seq_retried, " battle_id=", _seq_battle_id, ")")
	if _seq_context == "battle":
		# Safe retry: the server answers a resent round_over with the SAME
		# battle id from its persisted verdict instead of banking twice,
		# so retrying cannot double-count. Only the second expiry fails
		# loud; a late reply after that is dropped, never applied twice.
		if not _seq_retried and not _seq_last_round.is_empty():
			_seq_retried = true
			_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("battle")
			var q := _seq_last_round
			print("[Arena] Retrying battle report id=", _seq_battle_id,
				" (same id, idempotent)")
			_show_loading("STALLED - RETRYING BATTLE REPORT",
				"No confirmation for battle %s yet. Re-sending the SAME report id " % _seq_battle_id
				+ "(the server answers repeats from its stored verdict, no double count)...")
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING BATTLE %s ..." % _seq_battle_id
			brain_client.send_round_over(q.get("stats_a", {}), q.get("stats_b", {}),
				bool(q.get("draw", false)), _seq_battle_id,
				str(q.get("tournament_id", "")), str(q.get("match", "")))
			return
		_tourney_awaiting_battle = false
		_clear_seq()
		_show_loading("SERVER SILENT - BATTLE NOT CONFIRMED",
			"Battle %s was sent twice but the server never confirmed. " % tourney_match_label
			+ "Nothing further will be re-sent. See server_log.txt, then QUIT TO MENU + RESUME.")
		if is_instance_valid(status_label):
			status_label.text = "SERVER SILENT - see server_log.txt - QUIT TO MENU + RESUME"
		return
	if not _seq_retried:
		_seq_retried = true
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for(_seq_context)
		if _seq_context == "load" and not _seq_last_load.is_empty():
			var p := _seq_last_load
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING LOAD %s vs %s ..." % [tourney_a_name, tourney_b_name]
			brain_client.request_tournament_load(
				str(p.get("alpha_path", "")), str(p.get("beta_path", "")),
				str(p.get("tournament_id", "")), str(p.get("match", "")),
				float(p.get("lr_scale", 0.5)))
		else:
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING RESET ..."
			brain_client.request_match_reset(tourney_match_label)
		return
	# Second expiry: stay loud, stop touching the server.
	_clear_seq()
	_show_loading("STALLED - NO SERVER REPLY",
		"See server_log.txt - QUIT TO MENU + RESUME. Nothing was re-sent.")
	if is_instance_valid(status_label):
		status_label.text = "STALLED - see server_log.txt - QUIT TO MENU + RESUME"

func _reset_round() -> void:
	current_round_time = round_time_limit
	if tournament_active:
		var director := _director()
		if director != null:
			current_round_time = float(director.tourney.get("round_time", round_time_limit))
	is_round_active = true
	stats_alpha = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
	stats_beta  = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }

	# Head-on joust spawn: forward is -Z, so yaw -90 faces +X (toward beta)
	# and yaw +90 faces -X (toward alpha). Previously swapped (back-to-back).
	fly_alpha.reset_fly(Vector3(-14.0, 7.0, 0.0), deg_to_rad(-90.0))
	fly_beta.reset_fly(Vector3(14.0, 7.0, 0.0), deg_to_rad(90.0))

	if is_instance_valid(status_label):
		status_label.text = "AERIAL JOUST IN PROGRESS"

func _physics_process(delta: float) -> void:
	# Watchdog runs even between rounds: that limbo is exactly where a
	# lost server reply would wedge the game.
	_check_seq_watchdog()
	if not is_round_active:
		return

	current_round_time -= delta
	if is_instance_valid(timer_label):
		timer_label.text = "ROUND TIME: %04.1f s" % maxf(current_round_time, 0.0)

	_update_health_hud()

	var sens_a = fly_alpha.get_sensory_data(delta)
	var sens_b = fly_beta.get_sensory_data(delta)
	if sens_a.get("visual_target_visible", false):
		stats_alpha["tracking_time_s"] += delta
	if sens_b.get("visual_target_visible", false):
		stats_beta["tracking_time_s"] += delta
	# Rear-aspect chase: on the victim's tail and facing it. This is the
	# battle-level "who is winning the chase" score; evolution caps it so it
	# can only decide equal-kill bouts, never outscore a kill.
	if float(sens_a.get("tail_chase", 0.0)) > 0.5:
		stats_alpha["tail_time_s"] += delta
	if float(sens_b.get("tail_chase", 0.0)) > 0.5:
		stats_beta["tail_time_s"] += delta

	brain_tick_timer += delta
	if brain_tick_timer >= BRAIN_TICK_DT:
		brain_tick_timer = 0.0
		brain_client.send_sensory_step(sens_a, sens_b)

	if is_instance_valid(arena_camera):
		var midpoint = (fly_alpha.global_position + fly_beta.global_position) * 0.5
		var cam_dist = clampf((fly_alpha.global_position - fly_beta.global_position).length() * 0.9, 16.0, 38.0)
		var target_cam_pos = midpoint + Vector3(0, cam_dist * 0.45, cam_dist)
		arena_camera.global_position = arena_camera.global_position.lerp(target_cam_pos, delta * 3.0)
		arena_camera.look_at(midpoint + Vector3(0, 1.5, 0), Vector3.UP)

	_update_pip_view(pip_alpha_cam, fly_alpha, sens_a, pip_alpha_feat)
	_update_pip_view(pip_beta_cam, fly_beta, sens_b, pip_beta_feat)

	if current_round_time <= 0.0:
		# Stalemate verdict: time expired AND neither fly lost a point of
		# health (catches strikes, wing tears via prior KO, and tree-clip
		# damage). Free battle: a clean draw rematches the SAME brains with
		# no champion and no evolution advance. Tournament: the draw is
		# reported to the server (recorded, no dopamine) and replayed -
		# unless sudden death is armed, when fitness must pick a winner.
		var clean: bool = fly_alpha.health >= 99.99 and fly_beta.health >= 99.99
		var director := _director()
		var sudden: bool = tournament_active and director != null and director.sudden_death_armed
		if clean and not sudden:
			_handle_draw()
		else:
			_end_round()

func _update_pip_view(cam: Camera3D, fly: CharacterBody3D, sens: Dictionary, feat: Label) -> void:
	# Park the PiP camera on the fly's head, looking where it looks.
	if is_instance_valid(cam) and is_instance_valid(fly):
		var basis = fly.global_transform.basis
		var head_pos = fly.global_position + Vector3(0, 0.5, 0) + (-basis.z) * 0.6
		cam.global_transform = Transform3D(basis, head_pos)
	# Feature readout: the exact pre-brain values about to be sent north.
	if is_instance_valid(feat):
		var vis = "Y" if sens.get("visual_target_visible", false) else "-"
		feat.text = "AZ %+.0f EL %+.0f RIV %.2f TR %.2f (L%.2f R%.2f) VIS %s PH L%.2f R%.2f TAIL %.0f" % [
			float(sens.get("visual_target_azimuth", 0.0)),
			float(sens.get("visual_target_elevation", 0.0)),
			float(sens.get("visual_rival_looming", 0.0)),
			float(sens.get("visual_tree_looming", 0.0)),
			float(sens.get("visual_tree_left_looming", 0.0)),
			float(sens.get("visual_tree_right_looming", 0.0)),
			vis,
			float(sens.get("pheromone_conc_left", 0.0)),
			float(sens.get("pheromone_conc_right", 0.0)),
			float(sens.get("tail_chase", 0.0))]

func _build_health_hud() -> void:
	# Top-center panel: one row per fly with name, health bar, and L/R wing
	# state. Built at runtime so the scene file stays untouched.
	var hud: CanvasLayer = $HUD
	var vbox := VBoxContainer.new()
	vbox.name = "HealthPanel"
	vbox.set_anchors_preset(Control.PRESET_TOP_WIDE)
	vbox.offset_top = 8.0
	vbox.add_theme_constant_override("separation", 6)
	hud.add_child(vbox)

	alpha_health_bar = _make_health_bar(Color(1.0, 0.45, 0.15))
	beta_health_bar = _make_health_bar(Color(0.15, 0.6, 1.0))
	alpha_wing_l = _make_wing_label("LW")
	alpha_wing_r = _make_wing_label("RW")
	beta_wing_l = _make_wing_label("LW")
	beta_wing_r = _make_wing_label("RW")

	vbox.add_child(_make_fly_row("ALPHA", Color(1.0, 0.55, 0.3), alpha_health_bar, alpha_wing_l, alpha_wing_r))
	alpha_row_name = (vbox.get_child(vbox.get_child_count() - 1) as HBoxContainer).get_child(0) as Label
	vbox.add_child(_make_fly_row("BETA", Color(0.4, 0.75, 1.0), beta_health_bar, beta_wing_l, beta_wing_r))
	beta_row_name = (vbox.get_child(vbox.get_child_count() - 1) as HBoxContainer).get_child(0) as Label

func _make_fly_row(fly_name: String, name_color: Color, bar: ProgressBar, wing_l: Label, wing_r: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var name_l := Label.new()
	name_l.text = fly_name
	name_l.add_theme_font_size_override("font_size", 16)
	name_l.add_theme_color_override("font_color", name_color)
	name_l.custom_minimum_size = Vector2(110, 0)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_l.clip_text = true
	row.add_child(name_l)
	row.add_child(bar)
	row.add_child(wing_l)
	row.add_child(wing_r)
	return row

func _make_health_bar(fill: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(300, 20)
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.show_percentage = false
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = fill
	fill_sb.corner_radius_top_left = 6
	fill_sb.corner_radius_top_right = 6
	fill_sb.corner_radius_bottom_left = 6
	fill_sb.corner_radius_bottom_right = 6
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	bg_sb.corner_radius_top_left = 6
	bg_sb.corner_radius_top_right = 6
	bg_sb.corner_radius_bottom_left = 6
	bg_sb.corner_radius_bottom_right = 6
	bar.add_theme_stylebox_override("fill", fill_sb)
	bar.add_theme_stylebox_override("background", bg_sb)
	return bar

func _make_wing_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.custom_minimum_size = Vector2(40, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _update_health_hud() -> void:
	if alpha_health_bar == null:
		return
	alpha_health_bar.value = fly_alpha.health
	beta_health_bar.value = fly_beta.health
	_update_wing_label(alpha_wing_l, fly_alpha.left_wing_intact)
	_update_wing_label(alpha_wing_r, fly_alpha.right_wing_intact)
	_update_wing_label(beta_wing_l, fly_beta.left_wing_intact)
	_update_wing_label(beta_wing_r, fly_beta.right_wing_intact)

func _update_wing_label(label: Label, intact: bool) -> void:
	if label == null:
		return
	label.modulate = Color(0.45, 1.0, 0.45) if intact else Color(1.0, 0.25, 0.25)

func _build_hit_flash() -> void:
	# Full-height left/right low-alpha overlays for instant hit feedback.
	var hud: CanvasLayer = $HUD
	alpha_hit_flash = ColorRect.new()
	alpha_hit_flash.name = "AlphaHitFlash"
	alpha_hit_flash.color = Color(1.0, 0.2, 0.15, 0.0)
	alpha_hit_flash.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	alpha_hit_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(alpha_hit_flash)

	beta_hit_flash = ColorRect.new()
	beta_hit_flash.name = "BetaHitFlash"
	beta_hit_flash.color = Color(1.0, 0.2, 0.15, 0.0)
	beta_hit_flash.anchor_left = 0.5
	beta_hit_flash.anchor_right = 1.0
	beta_hit_flash.anchor_top = 0.0
	beta_hit_flash.anchor_bottom = 1.0
	beta_hit_flash.offset_right = 0.0
	beta_hit_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(beta_hit_flash)

func _hit_feedback(attacker_id: String, victim_id: String, part: String) -> void:
	_flash_victim(victim_id, 0.5)
	_flash_attacker(attacker_id, 0.22)
	# Don't clobber the KO/win message if the wing-loss already ended the round.
	if is_instance_valid(status_label) and is_round_active:
		if part == "spike_clash":
			status_label.text = "SPIKE CLASH! " + _slot_name(attacker_id) + " AND " \
				+ _slot_name(victim_id) + " spike each other!"
		else:
			status_label.text = _slot_name(attacker_id) + " STRIKES " + _slot_name(victim_id) + " (" + part + ")!"

func _flash_victim(victim_id: String, strength: float) -> void:
	var rect := alpha_hit_flash if victim_id == "alpha" else beta_hit_flash
	if rect != null:
		_flash_rect(rect, Color(1.0, 0.2, 0.15), strength)
	_flash_body(fly_alpha if victim_id == "alpha" else fly_beta, Color(1.0, 0.3, 0.2))

func _flash_attacker(attacker_id: String, strength: float) -> void:
	var rect := alpha_hit_flash if attacker_id == "alpha" else beta_hit_flash
	if rect != null:
		_flash_rect(rect, Color(1.0, 1.0, 0.8), strength)
	_flash_body(fly_alpha if attacker_id == "alpha" else fly_beta, Color(1.0, 0.9, 0.6))

func _flash_rect(rect: ColorRect, color: Color, strength: float) -> void:
	rect.color = Color(color.r, color.g, color.b, strength)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, 0.4)

func _flash_body(fly: CharacterBody3D, color: Color) -> void:
	if not is_instance_valid(fly):
		return
	var mesh := fly.get_node_or_null("VisualModel/BodyMesh") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.get_active_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	var tw := create_tween()
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.45)
	tw.tween_callback(func(): mat.emission_enabled = false)

func _build_winner_overlay() -> void:
	# Full-screen dim + big centered winner callout + countdown. Hidden by
	# default; _show_winner_and_countdown drives the round-end sequence.
	var hud: CanvasLayer = $HUD

	winner_overlay = Control.new()
	winner_overlay.name = "WinnerOverlay"
	winner_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	winner_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	winner_overlay.visible = false
	hud.add_child(winner_overlay)

	var bg := ColorRect.new()
	bg.name = "WinnerBackdrop"
	bg.color = Color(0.02, 0.02, 0.05, 0.62)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	winner_overlay.add_child(bg)

	var center := CenterContainer.new()
	center.name = "WinnerCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	winner_overlay.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)

	winner_label = Label.new()
	winner_label.name = "WinnerLabel"
	winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	winner_label.custom_minimum_size = Vector2(900, 0)
	winner_label.add_theme_font_size_override("font_size", 88)
	winner_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	winner_label.add_theme_constant_override("outline_size", 10)
	vbox.add_child(winner_label)

	countdown_label = Label.new()
	countdown_label.name = "CountdownLabel"
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	countdown_label.custom_minimum_size = Vector2(900, 0)
	countdown_label.add_theme_font_size_override("font_size", 34)
	countdown_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	countdown_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	countdown_label.add_theme_constant_override("outline_size", 5)
	vbox.add_child(countdown_label)

func _current_battle_id() -> String:
	# Correlation-only id, echoed by the server for log matching.
	return "%s-B%d" % [tourney_match_label, _battle_count() + 1]

func _show_loading(title: String, sub: String) -> void:
	# Persistent overlay (no countdown): proves the game is waiting on the
	# server, not frozen. Hidden by _hide_loading on the matching reply.
	# Smaller fonts than the winner callout so multi-line status text
	# wraps on-screen instead of running off the edges.
	if is_instance_valid(winner_label):
		winner_label.text = title
		winner_label.add_theme_font_size_override("font_size", 44)
		winner_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	if is_instance_valid(countdown_label):
		countdown_label.text = sub
		countdown_label.add_theme_font_size_override("font_size", 24)
	if winner_overlay != null:
		winner_overlay.visible = true
		winner_overlay.modulate.a = 1.0

func _hide_loading() -> void:
	# Hides the persistent LOADING/REPORTING overlay. Timed winner
	# callouts hide themselves when their countdown finishes.
	if winner_overlay != null:
		winner_overlay.visible = false

func _show_winner_and_countdown(title: String, title_color: Color, sub: String, countdown_prefix: String) -> void:
	_show_callout(title, title_color, sub, countdown_prefix, true)

func _show_callout(title: String, title_color: Color, sub: String, countdown_prefix: String, auto_reset: bool) -> void:
	# Centered callout (win, draw, restart) with a 3-2-1 countdown. When
	# auto_reset is false the caller sequences the next step itself
	# (tournament battles wait for the server's match_reset instead).
	# Restore winner-callout sizes (loading states shrink them).
	if is_instance_valid(winner_label):
		winner_label.text = title
		winner_label.add_theme_font_size_override("font_size", 88)
		winner_label.add_theme_color_override("font_color", title_color)
	if is_instance_valid(countdown_label):
		countdown_label.text = sub
		countdown_label.add_theme_font_size_override("font_size", 34)
	winner_overlay.visible = true
	winner_overlay.modulate.a = 0.0
	var tw := winner_overlay.create_tween()
	tw.tween_property(winner_overlay, "modulate:a", 1.0, 0.35)

	# Let the callout land before the countdown starts.
	await get_tree().create_timer(1.2).timeout

	for i in range(3, 0, -1):
		if is_instance_valid(countdown_label):
			countdown_label.text = "%s IN %d..." % [countdown_prefix, i]
		await get_tree().create_timer(1.0).timeout

	if is_instance_valid(countdown_label):
		countdown_label.text = "FIGHT!"
	await get_tree().create_timer(0.8).timeout

	winner_overlay.visible = false
	if auto_reset:
		_reset_round()

func _tourney_id() -> String:
	var director := _director()
	if director == null:
		return ""
	return str(director.tourney.get("id", ""))

func _report_battle(draw: bool) -> void:
	# Single choke point for tournament battle reports: stamps the same
	# (tournament, match, battle) id used as the server's idempotency key,
	# keeps a copy for one safe retry, and arms the battle watchdog.
	_seq_battle_id = _current_battle_id()
	_tourney_awaiting_battle = true
	_seq_last_round = {
		"stats_a": stats_alpha.duplicate(), "stats_b": stats_beta.duplicate(),
		"draw": draw, "tournament_id": _tourney_id(), "match": tourney_match_label}
	brain_client.send_round_over(stats_alpha, stats_beta, draw, _seq_battle_id,
		_tourney_id(), tourney_match_label)
	_arm_seq("battle")
	var kind := "DRAW - " if draw else ""
	_show_loading("%s %sREPORTING" % [tourney_match_label, kind],
		"Battle %s sent, waiting for server..." % _seq_battle_id)
	if is_instance_valid(status_label):
		status_label.text = "%s %sREPORTING" % [tourney_match_label, kind]

func _handle_draw() -> void:
	print("[Arena] Stalemate! Time expired with zero damage - DRAW, rematch same brains.")
	is_round_active = false
	if tournament_active:
		# Server records the draw (no dopamine) and replies tournament_battle
		# "draw"; sequencing continues in _on_tournament_battle.
		_report_battle(true)
		return
	_show_winner_and_countdown(
		"DRAW",
		Color(0.78, 0.78, 0.82),
		"TIME UP - NOBODY BLED - REMATCH",
		"REMATCH")

# ── Dynamic tree fade ───────────────────────────────────────────────
# Every combat-area tree gets its own StandardMaterial3D (so alpha can
# be set per-tree). Each frame the camera->fly ray is tested against
# each tree's XZ position; occluding trees go translucent instantly,
# then smoothly fade back solid once the flies move on.

func _setup_dynamic_tree_opacity() -> void:
	for child in $TreePerimeter.get_children():
		if child is StaticBody3D or not (child is Node3D):
			continue
		var node := child as Node3D
		# Only flagged trees fade (40 combat + 4 hand-placed). The horizon
		# ring (45-180 m) never carries the flag and stays fully opaque.
		# (A position cut-off can't work: corner combat trees stand past
		# 42 m, inside the horizon ring's inner radius.)
		if not node.has_meta("fades"):
			continue
		var p := Vector2(node.position.x, node.position.z)
		var s := maxf(node.scale.x, 0.4)
		var trunk_mats: Array = []
		var canopy_mats: Array = []
		for sub in node.get_children():
			var mi := sub as MeshInstance3D
			if mi == null:
				continue
			var n := str(mi.name)
			var mat := mi.material_override as StandardMaterial3D
			if mat == null:
				continue
			if n == "Trunk" or n == "TrunkTop" or n == "Roots":
				if not trunk_mats.has(mat):
					trunk_mats.append(mat)
			elif n.begins_with("Canopy"):
				if not canopy_mats.has(mat):
					canopy_mats.append(mat)
		if trunk_mats.is_empty() or canopy_mats.is_empty():
			continue
		tree_sight_entries.append({
			"pos": p,
			"scale": s,
			"trunk_mats": trunk_mats,
			"canopy_mats": canopy_mats,
		})

func _process(delta: float) -> void:
	# Update tree transparency every rendered frame.
	if tree_sight_entries.is_empty():
		return
	var cam_xz := Vector2(arena_camera.global_position.x,
						  arena_camera.global_position.z)
	var fly_positions: Array = [
		Vector2(fly_alpha.global_position.x, fly_alpha.global_position.z),
		Vector2(fly_beta.global_position.x,  fly_beta.global_position.z),
	]
	for entry in tree_sight_entries:
		var tree_xz: Vector2 = entry["pos"]
		var occ_radius: float = 3.2 * float(entry["scale"])
		var target: float = 1.0
		for f in fly_positions:
			var ray: Vector2 = f - cam_xz
			var denom: float = ray.length_squared()
			if denom < 1e-6:
				continue
			# Projection of tree center onto the cam->fly segment (0=cam, 1=fly).
			var t := clampf((tree_xz - cam_xz).dot(ray) / denom, 0.0, 1.0)
			# Skip trees exactly at the endpoints (the camera / the fly).
			if t <= 0.03 or t >= 0.97:
				continue
			var closest: Vector2 = cam_xz + ray * t
			if (tree_xz - closest).length() < occ_radius:
				target = TREE_FADE_ALPHA
				break
		var k: float = clampf(TREE_FADE_SMOOTH * delta, 0.0, 1.0)
		for tm in entry["trunk_mats"]:
			(tm as StandardMaterial3D).albedo_color.a = lerpf((tm as StandardMaterial3D).albedo_color.a, target, k)
		for cm in entry["canopy_mats"]:
			(cm as StandardMaterial3D).albedo_color.a = lerpf((cm as StandardMaterial3D).albedo_color.a, target, k)

# ────────────────────────────────────────────────────────────────────

func _on_motor_controls(ctrl_alpha: Dictionary, ctrl_beta: Dictionary, gen: int, stats: Dictionary = {}) -> void:
	current_generation = gen
	if is_instance_valid(gen_label):
		gen_label.text = "GENERATION: %04d" % gen
	fly_alpha.apply_brain_controls(ctrl_alpha)
	fly_beta.apply_brain_controls(ctrl_beta)
	# Brain activation readout: spikes + descending-neuron balance per fly.
	var st_a = stats.get("alpha", {})
	var st_b = stats.get("beta", {})
	if is_instance_valid(brain_alpha_label):
		brain_alpha_label.text = "%s brain n=%d DN L/R %d/%d LPLC2 %d MN %d VS %d thrust %.2f yaw %+.2f pitch %+.2f roll %+.2f" % [
			(_slot_name("alpha") + "      ").substr(0, 6),
			int(st_a.get("spikes", 0)), int(st_a.get("dn_left", 0)), int(st_a.get("dn_right", 0)),
			int(st_a.get("lplc2", 0)), int(st_a.get("mn_thrust", 0)), int(st_a.get("vs_flow", 0)),
			float(ctrl_alpha.get("thrust", 0.2)), float(ctrl_alpha.get("yaw_torque", 0.0)),
			float(ctrl_alpha.get("pitch_torque", 0.0)), float(ctrl_alpha.get("roll_torque", 0.0))]
	if is_instance_valid(brain_beta_label):
		brain_beta_label.text = "%s brain n=%d DN L/R %d/%d LPLC2 %d MN %d VS %d thrust %.2f yaw %+.2f pitch %+.2f roll %+.2f" % [
			(_slot_name("beta") + "      ").substr(0, 6),
			int(st_b.get("spikes", 0)), int(st_b.get("dn_left", 0)), int(st_b.get("dn_right", 0)),
			int(st_b.get("lplc2", 0)), int(st_b.get("mn_thrust", 0)), int(st_b.get("vs_flow", 0)),
			float(ctrl_beta.get("thrust", 0.2)), float(ctrl_beta.get("yaw_torque", 0.0)),
			float(ctrl_beta.get("pitch_torque", 0.0)), float(ctrl_beta.get("roll_torque", 0.0))]

func _on_strike_landed(attacker_id: String, target_part: String) -> void:
	# Wing hits pay 60 (plus the tear + 15 wound in FlyPhysics): hits register
	# in fitness even without a kill. Thorax stays 80 (lethal regardless).
	# A spike clash already wounded BOTH bodies in FlyPhysics; credit the
	# shared 25 to damage accounts (each fly's signal credits the other).
	var dmg = 80.0 if target_part == "thorax" else (25.0 if target_part == "spike_clash" else 60.0)
	if attacker_id == "alpha":
		stats_alpha["damage_dealt"] += dmg
		stats_beta["damage_taken"] += dmg
	else:
		stats_beta["damage_dealt"] += dmg
		stats_alpha["damage_taken"] += dmg
	_hit_feedback(attacker_id, "beta" if attacker_id == "alpha" else "alpha", target_part)

func _on_wing_torn(fly_id: String, side: String) -> void:
	# Stronger flash + message: losing a wing is the big mid-fight event.
	# Refresh HUD now - the round ends immediately, so physics-driven updates
	# would never show the torn wing / dried-up health bar.
	_update_health_hud()
	_flash_victim(fly_id, 0.6)
	if is_instance_valid(status_label):
		status_label.text = _slot_name(fly_id) + " LOST " + side.to_upper() + " WING!"

func _on_fly_knocked_out(victim_id: String) -> void:
	if not is_round_active:
		return

	# Draw the final state (health floor, torn wing) BEFORE the winner text.
	_update_health_hud()
	_flash_victim(victim_id, 0.75)

	if victim_id == "alpha":
		stats_beta["kills"] += 1
		if is_instance_valid(status_label):
			status_label.text = _ko_text("beta")
	else:
		stats_alpha["kills"] += 1
		if is_instance_valid(status_label):
			status_label.text = _ko_text("alpha")

	_end_round()

# Knockout banner: free battle keeps the classic "FLY ALPHA" phrasing;
# tournament battles use the assigned brain name.
func _ko_text(winner_slot: String) -> String:
	var n := _slot_name(winner_slot)
	if tournament_active:
		return "KNOCKOUT! %s WINS!" % n
	return "KNOCKOUT! FLY %s WINS!" % n

func _end_round() -> void:
	is_round_active = false
	print("[Arena] Round concluded! Sending battle stats to evolution engine...")
	if tournament_active:
		_report_battle(false)
		return
	brain_client.send_round_over(stats_alpha, stats_beta)

func _on_tournament_battle(battle_winner: String, _fit_a: float, _fit_b: float, _battle_id: String) -> void:
	# Server already banked dopamine + records + weights to the vault.
	# Late replies after a fail-loud battle timeout are dropped here so a
	# battle is never applied twice.
	if not _tourney_awaiting_battle:
		print("[Arena] Ignoring late/duplicate tournament_battle (id=", _battle_id, ")")
		return
	if _battle_id != "" and _seq_battle_id != "" and _battle_id != _seq_battle_id:
		print("[Arena] Ignoring tournament_battle id mismatch: got ", _battle_id,
			" want ", _seq_battle_id)
		return
	_tourney_awaiting_battle = false
	_clear_seq()
	_hide_loading()
	var director := _director()
	if director == null:
		return
	_update_health_hud()
	if battle_winner == "draw":
		if is_instance_valid(status_label):
			status_label.text = "%s DRAW - REPLAYING" % tourney_match_label
		_show_callout("DRAW", Color(0.78, 0.78, 0.82),
			"%s STALEMATE - REPLAY" % tourney_match_label, "REMATCH", false)
		await get_tree().create_timer(5.0).timeout
		director.on_battle_result("draw")
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")
		return
	var winner_name := tourney_a_name if battle_winner == "alpha" else tourney_b_name
	var res: Dictionary = director.on_battle_result(battle_winner)
	var action := str(res.get("action", "next_battle"))
	print("[Arena] Battle result: winner=", battle_winner, " action=", action)
	var score := "%d - %d" % [int(res.get("score_a", 0)), int(res.get("score_b", 0))]
	if action == "match_over":
		var match_winner := str(res.get("match_winner", battle_winner))
		var match_name := tourney_a_name if match_winner == "alpha" else tourney_b_name
		brain_client.request_tournament_match(match_winner)
		# The bracket overlay carries the result: gold connectors show the
		# path, the loser is grayed out, next lineup is visible.
		_show_arena_bracket("%s TAKES %s  (%s)" % [match_name, tourney_match_label, score])
		await get_tree().create_timer(6.0).timeout
		_hide_arena_bracket()
		_advance_tournament()
	else:
		_show_callout("%s TAKES BATTLE (%s)" % [winner_name, score],
			Color(1.0, 0.55, 0.3) if battle_winner == "alpha" else Color(0.4, 0.75, 1.0),
			"%s  BATTLE %d" % [tourney_match_label, _battle_count() + 1], "NEXT BATTLE", false)
		await get_tree().create_timer(5.0).timeout
		_update_tourney_status("BATTLE %d" % (_battle_count() + 1))
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")

func _battle_count() -> int:
	var director := _director()
	if director == null:
		return 0
	var m: Dictionary = director.current_match()
	return int(m.get("battles", 0))

func _advance_tournament() -> void:
	var director := _director()
	if director == null:
		return
	_handle_advance_result(director.advance_after_match())

func _handle_advance_result(res: Dictionary) -> void:
	var director := _director()
	if director == null:
		return
	var action := str(res.get("action", "next_match"))
	if action == "tournament_end":
		var champ_id := str(res.get("champion_id", ""))
		if director.is_quick():
			# Single exhibition battle: no title, no extra server call (the
			# battle + match are already recorded). Show winner, go home.
			var quick_name: String = director.champion_name()
			_show_callout("%s WINS THE QUICK BATTLE" % quick_name,
				Color(1.0, 0.85, 0.3), "EXHIBITION COMPLETE", "MENU", false)
			await get_tree().create_timer(5.0).timeout
			director.quit_to_menu()
			return
		var champ_slot := _slot_of(champ_id)
		_tourney_close_ack = false
		brain_client.request_tournament_end(champ_slot)
		var champ_name: String = director.champion_name()
		# The final bracket stays open for review: no auto-hide, no auto
		# quit. The user leaves via QUIT TO MENU in the bottom bar when
		# done (the bracket CLOSE button only hides the overlay; BRACKET
		# re-opens it).
		_hide_loading()
		winner_overlay.visible = false
		_show_arena_bracket("CHAMPION: %s - REVIEWING BRACKET" % champ_name)
		if is_instance_valid(status_label):
			status_label.text = "TOURNAMENT COMPLETE - CHAMPION %s - review, then QUIT TO MENU" % champ_name
		# Wait for the server's title write in the background (no leaving
		# until it lands, so the menu never shows a stale pre-title vault).
		# Bounded so a dead server can never hang the game here.
		var waited := 0.0
		while not _tourney_close_ack and waited < 60.0:
			await get_tree().create_timer(0.25).timeout
			waited += 0.25
		if not _tourney_close_ack:
			push_warning("[Arena] tournament_closed ack timeout; menu stats may lag the vault file.")
			if is_instance_valid(status_label):
				status_label.text += " (title may lag - see server_log.txt)"
		elif is_instance_valid(status_label):
			status_label.text = "TOURNAMENT COMPLETE - CHAMPION %s (title banked) - review, then QUIT TO MENU" % champ_name
	else:
		_request_current_battle_load()

func _slot_of(brain_id: String) -> String:
	var director := _director()
	if director == null:
		return "alpha"
	# Search from the final round backwards: the champion's slot in the
	# last match it fought identifies the server-side brain to crown.
	var rounds: Array = director.tourney.get("rounds", [])
	for ri in range(rounds.size() - 1, -1, -1):
		for mm in rounds[ri]:
			if str(mm.get("a_id", "")) == brain_id:
				return "alpha"
			if str(mm.get("b_id", "")) == brain_id:
				return "beta"
	return "alpha"

func _on_generation_advanced(new_gen: int, winner: String) -> void:
	print("[Arena] Champion: ", winner.to_upper(), "! Evolving Generation ", new_gen, "...")
	current_generation = new_gen
	_record_win(winner)
	if is_instance_valid(gen_label):
		gen_label.text = "GENERATION: %04d" % new_gen
	if is_instance_valid(status_label):
		status_label.text = "EVOLUTION COMPLETE: " + winner.to_upper() + " CHAMPION"

	# Big winner callout + countdown, then the round resets.
	var win_color := Color(1.0, 0.55, 0.3) if winner == "alpha" else Color(0.4, 0.75, 1.0)
	_show_winner_and_countdown(
		winner.to_upper() + " WINS!",
		win_color,
		"NEW CHAMPION - EVOLVING GENERATION " + str(current_generation),
		"NEXT ROUND")

func _on_merge_pressed() -> void:
	if is_instance_valid(status_label):
		status_label.text = "MERGING BRAINS (Alpha x Beta -> Beta)..."
	brain_client.request_merge()

func _on_restart_pressed() -> void:
	# Manual round reset that banks the fight so far as dopamine WITHOUT
	# touching the weights' lineage: no clone/mutate, no new generation.
	# Both brains (and their variant personalities) survive intact.
	if not is_round_active:
		return
	is_round_active = false
	if is_instance_valid(status_label):
		status_label.text = "ROUND RESTARTED - banking battle rewards..."
	print("[Arena] Restart requested! Sending battle stats for dopamine banking...")
	brain_client.request_restart(stats_alpha, stats_beta)

func _on_restarted(round_winner: String) -> void:
	_record_win(round_winner)
	if is_instance_valid(status_label):
		status_label.text = "RESTART BANKED: " + _slot_name(round_winner) + " LED - fresh round"
	await get_tree().create_timer(1.0).timeout
	_reset_round()

func _record_win(winner: String) -> void:
	if winner == "alpha":
		wins_alpha += 1
	elif winner == "beta":
		wins_beta += 1
	_update_win_label()

func _update_win_label() -> void:
	if not is_instance_valid(win_label):
		return
	var total = wins_alpha + wins_beta
	if total == 0:
		win_label.text = "WINS - %s 0 : 0 %s" % [_slot_name("alpha"), _slot_name("beta")]
	else:
		var pct_a = 100.0 * wins_alpha / total
		win_label.text = "WINS - %s %d (%.0f%%) : (%.0f%%) %d %s" % [_slot_name("alpha"), wins_alpha, pct_a, 100.0 - pct_a, wins_beta, _slot_name("beta")]

func _on_merged(merge_count: int, archived_loser: String) -> void:
	print("[Arena] Merged brains #", merge_count, " (archived ", archived_loser, ")")
	if is_instance_valid(status_label):
		status_label.text = "MERGED #%d - loser archived: %s" % [merge_count, archived_loser]
