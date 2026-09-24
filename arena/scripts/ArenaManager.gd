extends Node3D

const BrainClientScript = preload("res://scripts/BrainClient.gd")
const FlyPhysicsScript = preload("res://scripts/FlyPhysics.gd")
const BrainViewScript = preload("res://scripts/BrainView.gd")
const BrainRasterScript = preload("res://scripts/BrainRaster.gd")
const BrainCloudScript = preload("res://scripts/BrainCloud.gd")
const BracketView = preload("res://scripts/TournamentBracket.gd")

@export var round_time_limit: float = 40.0
var current_round_time: float = 0.0
var current_generation: int = 1
var is_round_active: bool = true

var stats_alpha := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
var stats_beta  := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }

# Shared control cadence (fairness invariant): BOTH flies' commands
# arrive in one packet, so both always share the same reply interval
# and the same torque-hold tau. Per-side taus would hand one fly
# crisper handling and are forbidden by construction (single shared
# variable, set on both flies every reply).
var ctrl_label: Label
var bv_reply_ema: float = 0.2
var bv_shared_tau: float = 0.15
var bv_last_reply: float = -1.0
var bv_cad_n: int = 0
var bv_cad_dt_sum: float = 0.0
var bv_cad_tau_sum: float = 0.0

# Brain-view L0 pool-rate bars (key, short label, bar-full count).
# Updated on every motor reply (~5 Hz) with EMA smoothing; always-on
# capable (toggled by menu setting, B key, BRAIN button).
const BV_POOLS := [
	["pheromone_da1", "DA1", 120.0], ["pheromone_va1v", "VA1v", 80.0],
	["visual_lc10", "LC10", 40.0], ["visual_lc4", "LC4", 60.0],
	["visual_lplc2", "LPLC2", 60.0], ["visual_lc11", "LC11", 40.0],
	["visual_lc15", "LC15", 40.0], ["visual_lc17", "LC17", 40.0],
	["visual_lc18", "LC18", 40.0], ["gyro_jo", "JO", 60.0],
	["visual_t4a", "T4a", 40.0], ["visual_t4b", "T4b", 40.0],
	["visual_t4c", "T4c", 40.0], ["visual_t4d", "T4d", 40.0],
	["visual_t5a", "T5a", 40.0], ["visual_t5b", "T5b", 40.0],
	["visual_t5c", "T5c", 40.0], ["visual_t5d", "T5d", 40.0],
	["mbon_app", "MBONap", 30.0], ["mbon_av", "MBONav", 30.0],
	["dn_left", "dnL", 120.0], ["dn_right", "dnR", 120.0],
	["motor_thrust_dnp09", "DNp09", 4.0], ["motor_turn_dnp20", "DNp20", 4.0],
	["motor_giant_fiber", "GF", 3.0], ["motor_ram_dnpe017", "RAM", 3.0],
	["motor_mouth", "MOUTH", 8.0], ["motor_flight_thrust", "MN", 30.0],
	["motor_steer", "STEER", 60.0], ["flow_vs", "VS", 30.0],
	["flow_hs", "HS", 15.0],
]
var bv_panel_alpha: VBoxContainer
var bv_panel_beta: VBoxContainer
var bv_head_alpha: Label
var bv_head_beta: Label
var bv_rows_alpha := {}
var bv_rows_beta := {}
var bv_ema_alpha := {}
var bv_ema_beta := {}
# Flow-diagram layer (L1): one BrainView overlay per fly, fed by the
# shared bar EMAs + per-side wiring/mapping labels from the server.
var bv_flow_alpha: Control
var bv_flow_beta: Control
var bv_wiring_alpha: Array = []
var bv_wiring_beta: Array = []
var bv_mapping_alpha: Array = []
var bv_mapping_beta: Array = []
var bv_caps := {}
# Raster drill-down (L2): one view + selection per side. Selecting a
# pool node auto-escalates the UDP detail to 2 (spike ids) and drops
# back to the menu level on deselect.
var bv_raster_alpha: Control
var bv_raster_beta: Control
var bv_sel_alpha := ""
var bv_sel_beta := ""
var bv_menu_detail := 1
# 3D soma cloud (L5): one MultiMesh holder per fly, parented to the
# camera so the brain floats in view. Spike ids flash cells via the
# shader; holders slow-spin for depth while visible.
var bv_cloud_alpha: Node3D
var bv_cloud_beta: Node3D
var bv_cloud_asset := {}
var bv_cloud_centroids := {}
# 3D network edges: from-pool, to-pool, kind (same gating as the 2D
# flow diagram: base always, overlays/schemes per fighter config).
const BV_NETS := [
	["pheromone_da1", "dn_left", "base"], ["pheromone_da1", "dn_right", "base"],
	["pheromone_va1v", "dn_left", "base"], ["pheromone_va1v", "dn_right", "base"],
	["visual_lc10", "dn_left", "base"], ["visual_lc10", "dn_right", "base"],
	["visual_lc4", "motor_giant_fiber", "base"],
	["visual_lplc2", "dn_left", "base"], ["visual_lplc2", "dn_right", "base"],
	["visual_lplc2", "dn_left", "contra"], ["visual_lplc2", "dn_right", "contra"],
	["visual_lc11", "dn_left", "wide"], ["visual_lc11", "dn_right", "wide"],
	["visual_lc15", "dn_left", "wide"], ["visual_lc15", "dn_right", "wide"],
	["visual_lc17", "dn_left", "wide"], ["visual_lc17", "dn_right", "wide"],
	["visual_lc18", "dn_left", "wide"], ["visual_lc18", "dn_right", "wide"],
	["visual_lc11", "motor_mouth", "spear"], ["visual_lc15", "motor_mouth", "spear"],
	["visual_lc17", "motor_mouth", "spear"], ["visual_lc18", "motor_mouth", "spear"],
	["gyro_jo", "flow_vs", "gyro"], ["gyro_jo", "flow_hs", "gyro"],
	["visual_t4a", "dn_left", "flowt"], ["visual_t4a", "dn_right", "flowt"],
	["visual_t4b", "dn_left", "flowt"], ["visual_t4b", "dn_right", "flowt"],
	["visual_t4c", "dn_left", "flowt"], ["visual_t4c", "dn_right", "flowt"],
	["visual_t4d", "dn_left", "flowt"], ["visual_t4d", "dn_right", "flowt"],
	["visual_t5a", "dn_left", "flowt"], ["visual_t5a", "dn_right", "flowt"],
	["visual_t5b", "dn_left", "flowt"], ["visual_t5b", "dn_right", "flowt"],
	["visual_t5c", "dn_left", "flowt"], ["visual_t5c", "dn_right", "flowt"],
	["visual_t5d", "dn_left", "flowt"], ["visual_t5d", "dn_right", "flowt"],
	["mbon_app", "dn_left", "value"], ["mbon_app", "dn_right", "value"],
	["mbon_av", "dn_left", "value"], ["mbon_av", "dn_right", "value"],
	["dn_left", "motor_steer", "base"], ["dn_right", "motor_steer", "base"],
	["dn_left", "motor_flight_thrust", "base"], ["dn_right", "motor_flight_thrust", "base"],
]
const BV_NET_WIRING := {"contra": "lplc2_contra_dn", "wide": "retina_wide",
	"spear": "spear_lunge"}
const BV_NET_SCHEME := {"gyro": "gyro_flow", "flowt": "flow_trans"}
const BV_NET_COLORS := {
	"pheromone_da1": Color(0.4, 1.0, 0.4), "pheromone_va1v": Color(0.5, 0.9, 0.3),
	"visual_lc10": Color(1.0, 0.9, 0.3), "visual_lc4": Color(1.0, 0.5, 0.2),
	"visual_lplc2": Color(1.0, 0.6, 0.9), "visual_lc11": Color(1.0, 1.0, 0.4),
	"visual_lc15": Color(1.0, 0.8, 0.2), "visual_lc17": Color(1.0, 0.7, 0.2),
	"visual_lc18": Color(0.9, 0.8, 0.3), "gyro_jo": Color(0.4, 0.8, 1.0),
	"mbon_app": Color(0.7, 0.4, 1.0), "mbon_av": Color(0.5, 0.2, 0.8),
	"dn_left": Color(1.0, 0.6, 0.15), "dn_right": Color(1.0, 0.6, 0.15),
}
# Replay (L4): per-battle pool-rate stream. One count array per motor
# reply (~5 Hz), capped; banked into the tournament JSON `flights`
# entry when the menu record toggle is on, plus an in-memory copy for
# the post-battle scrubber. ~50 KB per 40 s battle ??toggle-gated.
const BV_STREAM_MAX := 600
var bv_stream_alpha: Array = []
var bv_stream_beta: Array = []
var bv_replay_mode := false
var bv_replay_idx := 0
var bv_replay_playing := false
var bv_replay_accum := 0.0
var bv_replay_panel: PanelContainer
var bv_replay_slider: HSlider
var bv_replay_playbtn: Button
var bv_replay_label: Label
var bv_replay_prior_bars: Array = []

# Per-battle flight telemetry (answered by control step): altitude profile,
# thrust/pitch command means, evade/ram exposure, spear demand. Reported
# with the battle verdict and banked per-battle in the tournament JSON so
# flight-style questions ("why won't it climb?") have recorded evidence.
var flight_alpha := {}
var flight_beta := {}

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
# Battle verdict: how the round ended ("ko" | "time" | "draw", set by the
# KO/timeout handlers before _report_battle) plus the killing blow read
# off the victim's damage ledger. Composed into _last_verdict at report
# time so the server reply, callout, and retry all tell the same story.
var _end_reason := ""
var _ko_victim := ""
var _last_verdict := {}
var tourney_awaiting_load: bool = false
var bracket_overlay: Control
var arena_bracket: BracketView
var bracket_scroll: ScrollContainer
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
# Battle reports routinely take ~60 s (dopamine + gain pinning over 25M
# synapses, then two ~100 MB vault writes + journal fsync). A 30 s
# watchdog fired on EVERY battle and doubled server work with a retry
# that always lost the race. 90 s still fails loud on real stalls.
const SEQ_BATTLE_TIMEOUT_MSEC: int = 90000
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
	# Called whenever a new match's brains are known. New fighters means
	# a new session tally (only called on tournament match load, so the
	# free-battle running tally is untouched).
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
	wins_alpha = 0
	wins_beta = 0
	_update_win_label()
	# Brain-view headers follow the fighters: named brains in
	# tournament/quick battles, ALPHA/BETA in free battle.
	if is_instance_valid(bv_head_alpha):
		bv_head_alpha.text = _slot_name("alpha") + " BRAIN"
	if is_instance_valid(bv_head_beta):
		bv_head_beta.text = _slot_name("beta") + " BRAIN"
	if is_instance_valid(bv_flow_alpha):
		bv_flow_alpha.set("title", _slot_name("alpha") + " FLOW")
	if is_instance_valid(bv_flow_beta):
		bv_flow_beta.set("title", _slot_name("beta") + " FLOW")
	# New fighters: raster selections reference the old brains' pools.
	bv_sel_alpha = ""
	bv_sel_beta = ""
	if is_instance_valid(bv_flow_alpha):
		bv_flow_alpha.set("selected", "")
	if is_instance_valid(bv_flow_beta):
		bv_flow_beta.set("selected", "")
	_apply_bv_detail()
	_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")

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
	_apply_beauty_pass()
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
	var _edir := _director()
	if _edir != null:
		_edir.async_done.connect(_on_evo_async)
	brain_client.raster_map_received.connect(_on_raster_map)
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
	_layout_match_hud()
	_build_brainview()
	_build_evo_panel()
	_build_evo_status()
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
		print("[Arena] Requesting free_mode (no director tournament).")
		brain_client.request_free_mode()
		_reset_round()

func _apply_beauty_pass() -> void:
	# Vibrant stylized look, wired at runtime: painted ground + sky
	# shaders ride material_override / sky_material so the tscn keeps
	# its plain materials as a fallback if a shader ever fails to load.
	var ground_mi := get_node_or_null("Ground/GroundMesh") as MeshInstance3D
	if ground_mi != null:
		var gmat := ShaderMaterial.new()
		gmat.shader = preload("res://scripts/glade_ground.gdshader")
		ground_mi.material_override = gmat
	var wenv := get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env: Environment = wenv.environment if wenv != null else null
	if env != null and env.sky != null:
		var smat := ShaderMaterial.new()
		smat.shader = preload("res://scripts/stylized_sky.gdshader")
		env.sky.sky_material = smat
		env.sky.process_mode = Sky.PROCESS_MODE_REALTIME
		# Horizon melts into the scene fog: match it automatically.
		var fog := env.fog_light_color
		smat.set_shader_parameter("horizon_color",
			Vector3(fog.r, fog.g, fog.b))


func _director() -> Node:
	return get_node_or_null("/root/TournamentDirector")

func _enter_tournament_mode() -> void:
	tournament_active = true
	var director := _director()
	director.arena = self
	_build_bracket_overlay()
	_build_menu_bar(true)
	# Pipeline kick-off: queue a wild breed for the next generation
	# immediately, so it trains in the background while gen 1 plays.
	if _evo_active():
		var evo: Dictionary = director.tourney.get("evo", {})
		_evo_queue_wild(int(evo.get("generation", 1)) + 1)
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
		var brain_b := _menu_bar_button("BRAIN", "Cycle brain views: bars, flow, raster, 3D.")
		brain_b.pressed.connect(_on_brain_button)
		bar.add_child(brain_b)
		var replay_bt := _menu_bar_button("REPLAY", "Scrub the last battle's brain stream.")
		replay_bt.pressed.connect(_toggle_replay)
		bar.add_child(replay_bt)
		var evo_stop_b := _menu_bar_button("EVO STOP", "Stop the evolution loop (keeps current bracket).")
		evo_stop_b.pressed.connect(_on_evo_stop)
		bar.add_child(evo_stop_b)
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
		var brain_b := _menu_bar_button("BRAIN", "Cycle brain views: bars, flow, raster, 3D.")
		brain_b.pressed.connect(_on_brain_button)
		bar.add_child(brain_b)
		var replay_b2 := _menu_bar_button("REPLAY", "Scrub the last battle's brain stream.")
		replay_b2.pressed.connect(_toggle_replay)
		bar.add_child(replay_b2)


const BV_LAYERS := ["bars", "flow", "raster", "brain3d"]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_B:
			_toggle_brainview()
		elif (event as InputEventKey).keycode == KEY_N:
			_cycle_bv_layer()


func _cycle_bv_layer() -> void:
	# Live layer cycling (no menu round-trip): bars -> flow ->
	# raster -> brain3d. Syncs back to the menu bus.
	var director := _director()
	var cur := "bars"
	if director != null:
		cur = str(director.brainview_layer)
	var nxt: String = BV_LAYERS[(BV_LAYERS.find(cur) + 1) % BV_LAYERS.size()]
	if director != null:
		director.brainview_layer = nxt
	_apply_bv_detail()
	_apply_bv_layer(nxt)
	if is_instance_valid(status_label):
		status_label.text = "BRAIN VIEW layer: %s (N cycles)" % nxt


func _menu_bar_button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(130, 30)
	b.add_theme_font_size_override("font_size", 13)
	b.modulate = Color(1, 1, 1, 0.85)
	return b

func _build_bracket_overlay() -> void:
	# Edge-to-edge bracket graph: title + scrollable TournamentBracket +
	# close. The panel fills the whole viewport (no side margins) with a
	# slightly translucent backdrop so the arena stays faintly visible.
	# Hidden by default; auto-shown when a match completes.
	var hud: CanvasLayer = $HUD
	bracket_overlay = Control.new()
	bracket_overlay.name = "BracketOverlay"
	bracket_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	bracket_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_overlay.visible = false
	hud.add_child(bracket_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.05, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_overlay.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.09, 0.9)
	sb.border_color = Color(0.4, 0.4, 0.46)
	sb.set_border_width_all(1)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", sb)
	bracket_overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)
	bracket_title = Label.new()
	bracket_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bracket_title.add_theme_font_size_override("font_size", 18)
	vb.add_child(bracket_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vb.add_child(scroll)
	bracket_scroll = scroll
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
	# The renderer picks compact metrics for big brackets so most fit
	# outright; whatever still overflows keeps native scrolling here.
	if is_instance_valid(bracket_scroll):
		bracket_scroll.scroll_horizontal = 0
		bracket_scroll.scroll_vertical = 0
	bracket_overlay.visible = true

func _hide_arena_bracket() -> void:
	if bracket_overlay != null:
		bracket_overlay.visible = false


func _save_bracket_record(with_png: bool) -> void:
	# Permanent record of the finished bracket: bracket text always, plus
	# a viewport PNG once the overlay has settled (2 frames). TXT/PNG land
	# next to the tournament save as bracket_<id>.txt/.png. Skipped for
	# quick battles (single exhibition, no bracket).
	var director := _director()
	if director == null or director.is_quick():
		return
	if (director.tourney.get("rounds", []) as Array).is_empty():
		return
	var base: String = director.tournament_dir.path_join("bracket_%s" % str(director.tourney.get("id", "draft")))
	var f := FileAccess.open(base + ".txt", FileAccess.WRITE)
	if f != null:
		f.store_string(director.bracket_text())
		f.close()
		print("[Arena] Bracket record saved: ", base + ".txt")
	if not with_png:
		return
	var showed := false
	if not (is_instance_valid(bracket_overlay) and bracket_overlay.visible):
		_show_arena_bracket("CHAMPION: %s - FINAL RECORD" % director.champion_name())
		showed = true
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(bracket_overlay) and bracket_overlay.visible:
		var img := get_viewport().get_texture().get_image()
		if img.save_png(base + ".png") == OK:
			print("[Arena] Bracket screenshot saved: ", base + ".png")
		else:
			push_warning("[Arena] Bracket screenshot failed: " + base + ".png")
	if showed:
		_hide_arena_bracket()

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
			str(q.get("tournament_id", "")), str(q.get("match", "")),
			q.get("flight_a", {}), q.get("flight_b", {}),
			false, str(q.get("end_reason", "")), q.get("verdict", {}))
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


func _sway_material(base: Color, amp: float, bend: float, half_h: float) -> ShaderMaterial:
	# One wind-sway instance per palette entry (bushes x2, grass x1);
	# instances share the mesh + shader, phase comes from each node's
	# origin hash in-shader.
	var m := ShaderMaterial.new()
	m.shader = preload("res://scripts/underbrush.gdshader")
	m.set_shader_parameter("base_color", Vector3(base.r, base.g, base.b))
	m.set_shader_parameter("sway_amp", amp)
	m.set_shader_parameter("bend_amount", bend)
	m.set_shader_parameter("mesh_half_height", half_h)
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
	# Butt joints, no overlaps: each section starts exactly where the one
	# below ends (flare 0-1.8, trunk 1.8-9.8, trunk-top 9.8-17.8, canopy
	# stacked tangent on top). Radii already match at every rim
	# (0.85 / 0.55), so the seams read as growth rings, not intersections.
	# The upper trunk still tilts, pivoting about its base point seated
	# on the lower trunk's top rim (<=4 deg, rim shift negligible).
	# Canopy side blobs stay merged foliage masses by design - only the
	# wood-to-wood and wood-to-canopy joints abut. Mesh names feed the
	# dynamic-fade system.
	_add_tree_part(parent, "Roots", _tree_mesh("flare"), Vector3(0, 0.9, 0), tmat)
	_add_tree_part(parent, "Trunk", _tree_mesh("trunk_low"), Vector3(0, 5.8, 0), tmat)
	var tilt_ang := decor.randf_range(0.0, 0.07)
	var tilt_az := decor.randf_range(0.0, TAU)
	var tilt_dir := Vector3(cos(tilt_az), 0.0, sin(tilt_az))
	var axis := Vector3.UP.cross(tilt_dir)
	if axis.length() < 0.01:
		axis = Vector3.RIGHT
	var top_basis := Basis(axis.normalized(), tilt_ang)
	var top_base := Vector3(0, 9.8, 0)
	var top_part := _add_tree_part(parent, "TrunkTop", _tree_mesh("trunk_top"), top_base, tmat)
	top_part.position = top_base + top_basis * Vector3(0, 4.0, 0)
	top_part.basis = top_basis
	var top_pos: Vector3 = top_base + top_basis * Vector3(0, 8.0, 0)
	# Main canopy blob (scaled half-height 1.98) tangent on the trunk top.
	var canopy_main := top_pos + Vector3(0, 1.98, 0)
	_add_tree_part(parent, "Canopy", _tree_mesh("blob"), canopy_main, cmat,
		Vector3(1.15, 0.90, 1.15))
	var a2 := decor.randf_range(0.0, TAU)
	var side_dir := Vector3(cos(a2), 0.0, sin(a2))
	_add_tree_part(parent, "Canopy2", _tree_mesh("blob"),
		canopy_main + side_dir * 1.8 + Vector3(0, -1.0, 0), cmat,
		Vector3(0.72, 0.58, 0.72))
	if full:
		# Crown blob (scaled half-height 1.35) tangent on the main mass.
		_add_tree_part(parent, "Canopy3", _tree_mesh("blob_small"),
			canopy_main + tilt_dir * 0.2 + Vector3(0, 3.33, 0), cmat,
			Vector3(1.0, 0.90, 1.0))


func _build_underbrush(forest_root: Node3D, decor: RandomNumberGenerator, placed: Array, spawn_a: Vector2, spawn_b: Vector2) -> void:
	# Bushes, rocks and grass tufts: visual-only dressing that fills the
	# glade floor. Positions use the decor stream; the tree layout above
	# is untouched.
	var under := Node3D.new()
	under.name = "Underbrush"
	forest_root.add_child(under)
	# Wind-swayed bushes + grass (trees keep StandardMaterials for the
	# occlusion-fade system). Rocks stay still, exactly as before.
	var bush_mat_a := _sway_material(Color(0.13, 0.30, 0.11), 0.05, 0.3, 0.85)
	var bush_mat_b := _sway_material(Color(0.18, 0.36, 0.13), 0.05, 0.3, 0.85)
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.45, 0.44, 0.42)
	rock_mat.roughness = 0.95
	var grass_mat := _sway_material(Color(0.24, 0.47, 0.17), 0.15, 1.0, 0.55)
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
				str(q.get("tournament_id", "")), str(q.get("match", "")),
				q.get("flight_a", {}), q.get("flight_b", {}),
				false, str(q.get("end_reason", "")), q.get("verdict", {}))
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
	# New round waits for the landing ceremony (bounded inside).
	await _await_landing()
	current_round_time = round_time_limit
	if tournament_active:
		var director := _director()
		if director != null:
			current_round_time = float(director.tourney.get("round_time", round_time_limit))
	is_round_active = true
	stats_alpha = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
	stats_beta  = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
	_end_reason = ""
	_ko_victim = ""
	_last_verdict = {}
	flight_alpha = {}
	flight_beta = {}
	bv_cad_n = 0
	bv_cad_dt_sum = 0.0
	bv_cad_tau_sum = 0.0
	bv_last_reply = -1.0
	bv_stream_alpha.clear()
	bv_stream_beta.clear()
	_exit_replay()
	if is_instance_valid(bv_raster_alpha):
		bv_raster_alpha.clear()
	if is_instance_valid(bv_raster_beta):
		bv_raster_beta.clear()

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
			_end_reason = "draw"
			_handle_draw()
		else:
			_end_reason = "time"
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
		feat.text = "AZ %+.0f EL %+.0f RIV %.2f TR %.2f (L%.2f R%.2f) VIS %s PH L%.2f R%.2f LOST %.0fs SURGE %.2f TAIL %.0f" % [
			float(sens.get("visual_target_azimuth", 0.0)),
			float(sens.get("visual_target_elevation", 0.0)),
			float(sens.get("visual_rival_looming", 0.0)),
			float(sens.get("visual_tree_looming", 0.0)),
			float(sens.get("visual_tree_left_looming", 0.0)),
			float(sens.get("visual_tree_right_looming", 0.0)),
			vis,
			float(sens.get("pheromone_conc_left", 0.0)),
			float(sens.get("pheromone_conc_right", 0.0)),
			float(sens.get("scent_lost", 0.0)),
			float(sens.get("scent_surge", 0.0)),
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
	alpha_wing_l = _make_wing_label("Left Wing")
	alpha_wing_r = _make_wing_label("Right Wing")
	beta_wing_l = _make_wing_label("Left Wing")
	beta_wing_r = _make_wing_label("Right Wing")

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
	l.custom_minimum_size = Vector2(96, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.clip_text = true
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


func _layout_match_hud() -> void:
	# Generation readout is a retired free-battle-evolution leftover:
	# hide it outright (updates stay guarded no-ops).
	if is_instance_valid(gen_label):
		gen_label.visible = false
	# Round time + wins move to a centered top strip, clear of the
	# side brain-view panels (reparented scene labels, same nodes).
	var hud: CanvasLayer = $HUD
	var strip := HBoxContainer.new()
	strip.name = "MatchStrip"
	strip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	strip.offset_left = -320.0
	strip.offset_right = 320.0
	strip.offset_top = 64.0
	strip.offset_bottom = 96.0
	strip.alignment = BoxContainer.ALIGNMENT_CENTER
	strip.add_theme_constant_override("separation", 40)
	hud.add_child(strip)
	for lbl in [timer_label, win_label]:
		if is_instance_valid(lbl):
			(lbl as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			var parent := (lbl as Node).get_parent()
			if parent != null:
				parent.remove_child(lbl)
			strip.add_child(lbl)
	# Control-cadence readout: shared reply rate + torque-hold tau.
	# Both flies always share these (fairness invariant).
	ctrl_label = Label.new()
	ctrl_label.name = "CtrlLabel"
	ctrl_label.add_theme_font_size_override("font_size", 14)
	ctrl_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	strip.add_child(ctrl_label)
	_update_ctrl_label()
	# Status line ("AERIAL JOUST IN PROGRESS", etc.) centered right
	# above the buttons - stacked over the EVO line (menu bar -46/-10,
	# EVO line -74/-50, this box -104/-78), out of the fight view.
	if is_instance_valid(status_label):
		var corner := VBoxContainer.new()
		corner.name = "StatusCorner"
		corner.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		corner.offset_left = -400.0
		corner.offset_right = 400.0
		corner.offset_top = -104.0
		corner.offset_bottom = -78.0
		corner.alignment = BoxContainer.ALIGNMENT_CENTER
		hud.add_child(corner)
		var old_parent := (status_label as Node).get_parent()
		if old_parent != null:
			old_parent.remove_child(status_label)
		(status_label as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		corner.add_child(status_label)


func _build_brainview() -> void:
	# L0 pool-rate bars: one slim panel per fly, screen edges, always-on
	# capable. 31 rows x 2 panels of tiny bars is trivial draw load; the
	# values arrive inside the existing motor reply (no extra packets).
	var hud: CanvasLayer = $HUD
	bv_panel_alpha = _make_bv_panel(hud, "BrainAlpha", Control.PRESET_BOTTOM_LEFT,
		Color(1.0, 0.55, 0.3), "ALPHA", bv_rows_alpha)
	bv_panel_beta = _make_bv_panel(hud, "BrainBeta", Control.PRESET_BOTTOM_RIGHT,
		Color(0.4, 0.75, 1.0), "BETA", bv_rows_beta)
	bv_flow_alpha = _make_bv_flow(hud, "FlowAlpha", Control.PRESET_BOTTOM_LEFT,
		Color(1.0, 0.55, 0.3))
	bv_flow_beta = _make_bv_flow(hud, "FlowBeta", Control.PRESET_BOTTOM_RIGHT,
		Color(0.4, 0.75, 1.0))
	bv_flow_alpha.set("title", "ALPHA FLOW")
	bv_flow_beta.set("title", "BETA FLOW")
	_build_brain_clouds()
	_build_replay_panel(hud)
	_apply_brainview_settings()


func _build_brain_clouds() -> void:
	# Soma clouds ride the camera (always in frame, out of the fight's
	# way): alpha left, beta right, slow-spinning while visible.
	bv_cloud_asset = BrainCloudScript.load_asset()
	if (bv_cloud_asset as Dictionary).is_empty():
		print("[Arena] BrainView: no brain_cloud.json (run brain_engine/export_brain_cloud.py).")
		return
	if not is_instance_valid(arena_camera):
		return
	bv_cloud_alpha = _make_bv_cloud("CloudAlpha", Vector3(-1.5, 0.7, -3.2))
	bv_cloud_beta = _make_bv_cloud("CloudBeta", Vector3(1.5, 0.7, -3.2))
	# Centroid lookup for the network overlay (asset unit-box coords
	# scaled like the cell instances).
	bv_cloud_centroids.clear()
	var raw: Dictionary = (bv_cloud_asset as Dictionary).get("centroids", {})
	for key in raw.keys():
		var c: Array = raw[key]
		bv_cloud_centroids[str(key)] = Vector3(
			float(c[0]) * 1.1, float(c[1]) * 1.1, float(c[2]) * 1.1)


func _make_bv_cloud(cname: String, campos: Vector3) -> Node3D:
	var holder := Node3D.new()
	holder.name = cname
	holder.position = campos
	holder.visible = false
	arena_camera.add_child(holder)
	var cloud := BrainCloudScript.new()
	holder.add_child(cloud)
	if not cloud.build(bv_cloud_asset, 1.1):
		holder.queue_free()
		return null
	return holder


func _build_replay_panel(hud: CanvasLayer) -> void:
	# Post-battle scrubber: play/pause + slider over the banked
	# pool-rate stream, rendered through the same bars + diagram.
	bv_replay_panel = PanelContainer.new()
	bv_replay_panel.name = "ReplayPanel"
	bv_replay_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bv_replay_panel.offset_left = -320.0
	bv_replay_panel.offset_right = 320.0
	bv_replay_panel.offset_top = -104.0
	bv_replay_panel.offset_bottom = -56.0
	bv_replay_panel.visible = false
	hud.add_child(bv_replay_panel)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	bv_replay_panel.add_child(hb)
	var tag := Label.new()
	tag.text = "REPLAY"
	tag.add_theme_font_size_override("font_size", 12)
	hb.add_child(tag)
	bv_replay_playbtn = Button.new()
	bv_replay_playbtn.text = "Play"
	bv_replay_playbtn.pressed.connect(_on_replay_play)
	hb.add_child(bv_replay_playbtn)
	bv_replay_slider = HSlider.new()
	bv_replay_slider.min_value = 0.0
	bv_replay_slider.max_value = 1.0
	bv_replay_slider.step = 1.0
	bv_replay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bv_replay_slider.value_changed.connect(_on_replay_scrub)
	hb.add_child(bv_replay_slider)
	bv_replay_label = Label.new()
	bv_replay_label.text = "0/0"
	bv_replay_label.add_theme_font_size_override("font_size", 12)
	hb.add_child(bv_replay_label)
	var close_b := Button.new()
	close_b.text = "X"
	close_b.pressed.connect(_exit_replay)
	hb.add_child(close_b)


func _toggle_replay() -> void:
	if bv_replay_mode:
		_exit_replay()
		return
	if is_round_active:
		if is_instance_valid(status_label):
			status_label.text = "REPLAY available between battles."
		return
	if bv_stream_alpha.is_empty():
		if is_instance_valid(status_label):
			status_label.text = "No recorded stream (menu record toggle?)."
		return
	bv_replay_mode = true
	bv_replay_idx = 0
	bv_replay_playing = false
	bv_replay_playbtn.text = "Play"
	bv_replay_slider.max_value = float(bv_stream_alpha.size() - 1)
	bv_replay_slider.value = 0.0
	bv_replay_panel.visible = true
	# Replay forces the bars visible; prior state restores on exit.
	bv_replay_prior_bars = [
		is_instance_valid(bv_panel_alpha) and bv_panel_alpha.visible,
		is_instance_valid(bv_panel_beta) and bv_panel_beta.visible]
	if is_instance_valid(bv_panel_alpha):
		bv_panel_alpha.visible = true
	if is_instance_valid(bv_panel_beta):
		bv_panel_beta.visible = true
	_render_replay_frame()


func _exit_replay() -> void:
	bv_replay_mode = false
	bv_replay_playing = false
	if is_instance_valid(bv_replay_panel):
		bv_replay_panel.visible = false
	if bv_replay_prior_bars.size() == 2:
		if is_instance_valid(bv_panel_alpha):
			bv_panel_alpha.visible = bool(bv_replay_prior_bars[0])
		if is_instance_valid(bv_panel_beta):
			bv_panel_beta.visible = bool(bv_replay_prior_bars[1])
		bv_replay_prior_bars.clear()


func _on_replay_play() -> void:
	bv_replay_playing = not bv_replay_playing
	bv_replay_playbtn.text = "Pause" if bv_replay_playing else "Play"


func _on_replay_scrub(value: float) -> void:
	if not bv_replay_mode:
		return
	bv_replay_idx = int(value)
	_render_replay_frame()


func _render_replay_frame() -> void:
	var n := bv_stream_alpha.size()
	if n == 0:
		return
	bv_replay_idx = clampi(bv_replay_idx, 0, n - 1)
	bv_replay_label.text = "%d/%d" % [bv_replay_idx + 1, n]
	var keys: Array = []
	for spec in BV_POOLS:
		keys.append(str(spec[0]))
	_render_replay_side(bv_rows_alpha, bv_ema_alpha, bv_stream_alpha[bv_replay_idx], keys)
	_render_replay_side(bv_rows_beta, bv_ema_beta, bv_stream_beta[bv_replay_idx], keys)
	if is_instance_valid(bv_flow_alpha):
		bv_flow_alpha.refresh(_replay_emas(bv_stream_alpha[bv_replay_idx], keys),
			bv_caps, bv_wiring_alpha, bv_mapping_alpha)
	if is_instance_valid(bv_flow_beta):
		bv_flow_beta.refresh(_replay_emas(bv_stream_beta[bv_replay_idx], keys),
			bv_caps, bv_wiring_beta, bv_mapping_beta)


func _replay_emas(row: Array, keys: Array) -> Dictionary:
	var emas := {}
	for i in range(mini(row.size(), keys.size())):
		emas[keys[i]] = float(row[i])
	return emas


func _render_replay_side(rows: Dictionary, _live_emas: Dictionary, row: Array, keys: Array) -> void:
	_render_bv_side(rows, _replay_emas(row, keys))


func _make_bv_flow(hud: CanvasLayer, vname: String, anchor: Control.LayoutPreset,
		tint: Color) -> Control:
	# Flow diagram overlay (L1): same side as its bar panel, wider and
	# taller, hidden unless the menu layer is "flow". Click a node to
	# arm the raster drill-down (Phase 3 consumes the selection).
	var view := BrainViewScript.new()
	view.name = vname
	view.set_anchors_preset(anchor)
	var left_side := anchor == Control.PRESET_CENTER_LEFT or anchor == Control.PRESET_BOTTOM_LEFT
	view.offset_left = 204.0 if left_side else -560.0
	view.offset_right = 560.0 if left_side else -204.0
	# Same top as the bar panels: every brainview layer starts just
	# below the PiP eye views (raster copies these offsets).
	view.offset_top = -488.0
	view.offset_bottom = -60.0
	view.tint = tint
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(view)
	var side := "alpha" if vname == "FlowAlpha" else "beta"
	view.pool_selected.connect(_on_bv_pool_selected.bind(side))
	var raster := BrainRasterScript.new()
	raster.name = "RasterAlpha" if side == "alpha" else "RasterBeta"
	raster.set_anchors_preset(anchor)
	raster.offset_left = view.offset_left
	raster.offset_right = view.offset_right
	raster.offset_top = view.offset_top
	raster.offset_bottom = view.offset_bottom
	raster.visible = false
	hud.add_child(raster)
	if side == "alpha":
		bv_raster_alpha = raster
	else:
		bv_raster_beta = raster
	return view


func _on_bv_pool_selected(pool: String, side: String) -> void:
	# Click toggles (BrainView emits "" on re-click of the same node).
	if side == "alpha":
		bv_sel_alpha = pool
	else:
		bv_sel_beta = pool
	if pool == "":
		_apply_bv_detail()
		_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")
		return
	brain_client.request_raster_map(side, pool)
	brain_client.detail_level = 2
	_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")


func _on_raster_map(side: String, pool: String, ids: Array, total: int) -> void:
	var sel := bv_sel_alpha if side == "alpha" else bv_sel_beta
	if sel == "" or sel != pool:
		return
	var raster: Control = bv_raster_alpha if side == "alpha" else bv_raster_beta
	if not is_instance_valid(raster):
		return
	raster.setup(pool, ids, total,
		Color(1.0, 0.55, 0.3) if side == "alpha" else Color(0.4, 0.75, 1.0),
		_slot_name(side))
	_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")


func _apply_bv_detail() -> void:
	# Detail 2 while a raster selection is live or the 3D cloud shows
	# (both consume spike ids); otherwise the menu level keeps UDP small.
	var detail := bv_menu_detail
	if bv_sel_alpha != "" or bv_sel_beta != "":
		detail = 2
	elif _bv_layer_is_3d():
		detail = 2
	brain_client.detail_level = detail


func _bv_layer_is_3d() -> bool:
	var director := _director()
	return director != null and str(director.brainview_layer) == "brain3d"


static func _parse_wiring_label(label: String) -> Array:
	# Server canonical labels: "base" or "a+b" (sorted).
	var s := label.strip_edges()
	if s == "" or s.to_lower() == "base":
		return []
	return s.split("+")


static func _parse_mapping(m) -> Array:
	if m is Array:
		return (m as Array).duplicate()
	var s := str(m).strip_edges().to_lower()
	if s in ["", "none", "base", "null"]:
		return []
	return [s]


func _make_bv_panel(hud: CanvasLayer, pname: String, anchor: Control.LayoutPreset,
		tint: Color, title: String, rows: Dictionary) -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = pname
	panel.set_anchors_preset(anchor)
	# Bottom-anchored: sits above the menu bar with its top tucked just
	# below the top-corner PiP eye views (feat text ends ~226px; panel
	# top lands ~232px at 720p).
	var left_side := anchor == Control.PRESET_CENTER_LEFT or anchor == Control.PRESET_BOTTOM_LEFT
	# Compact chart: 46 label + 64 bar + 26 count = 140px wide; ~385px
	# tall for all 31 pool rows, top tucked just below the PiP eye
	# views, bottom clear of the menu bar (and a smaller mouse rect).
	panel.offset_left = 8.0 if left_side else -148.0
	panel.offset_right = 148.0 if left_side else -8.0
	panel.offset_top = -488.0
	panel.offset_bottom = -103.0
	panel.add_theme_constant_override("separation", 1)
	hud.add_child(panel)
	var head := Label.new()
	head.text = title + " BRAIN"
	head.add_theme_font_size_override("font_size", 10)
	head.add_theme_color_override("font_color", tint)
	panel.add_child(head)
	if pname == "BrainAlpha":
		bv_head_alpha = head
	else:
		bv_head_beta = head
	for spec in BV_POOLS:
		bv_caps[str(spec[0])] = float(spec[2])
	for spec in BV_POOLS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		panel.add_child(row)
		var nm := Label.new()
		nm.text = spec[1]
		nm.custom_minimum_size = Vector2(46, 0)
		nm.add_theme_font_size_override("font_size", 9)
		nm.add_theme_color_override("font_color", tint)
		row.add_child(nm)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(64, 8)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		var num := Label.new()
		num.text = "0"
		num.custom_minimum_size = Vector2(26, 0)
		num.add_theme_font_size_override("font_size", 9)
		row.add_child(num)
		rows[str(spec[0])] = [bar, num, float(spec[2])]
	return panel


func _apply_brainview_settings() -> void:
	var director := _director()
	var enabled := true
	var detail := 1
	var layer := "bars"
	if director != null:
		# Direct property access (the autoload carries these vars);
		# .get() on a Node-typed ref would bind Object.get (1 arg).
		enabled = bool(director.brainview_enabled)
		detail = int(director.brainview_detail)
		layer = str(director.brainview_layer)
	bv_menu_detail = detail
	_apply_bv_detail()
	if is_instance_valid(bv_panel_alpha):
		bv_panel_alpha.visible = enabled
	if is_instance_valid(bv_panel_beta):
		bv_panel_beta.visible = enabled
	# Per-fly spike readout lines ("brain n=... thrust/yaw/...") stay
	# hidden permanently: bars + diagram + 3D carry the same data and
	# the labels just eat layout room.
	if is_instance_valid(brain_alpha_label):
		brain_alpha_label.visible = false
	if is_instance_valid(brain_beta_label):
		brain_beta_label.visible = false
	_apply_bv_layer(layer)


func _apply_bv_layer(layer: String) -> void:
	# Bars always ride along when enabled. Flow shows on "flow", or on
	# "raster" until a pool is selected ??then the raster takes its
	# rect (click again to deselect and return to the diagram).
	_apply_bv_side_layer("alpha", layer)
	_apply_bv_side_layer("beta", layer)


func _bv_panels_on(side: String) -> bool:
	var panel: Control = bv_panel_alpha if side == "alpha" else bv_panel_beta
	return is_instance_valid(panel) and panel.visible


func _apply_bv_side_layer(side: String, layer: String) -> void:
	var flow: Control = bv_flow_alpha if side == "alpha" else bv_flow_beta
	var raster: Control = bv_raster_alpha if side == "alpha" else bv_raster_beta
	var cloud: Node3D = bv_cloud_alpha if side == "alpha" else bv_cloud_beta
	var sel := bv_sel_alpha if side == "alpha" else bv_sel_beta
	var on := _bv_panels_on(side)
	var show_raster := on and layer == "raster" and sel != ""
	if is_instance_valid(raster):
		raster.visible = show_raster
	if is_instance_valid(flow):
		flow.visible = on and (layer == "flow" or (layer == "raster" and not show_raster))
	if is_instance_valid(cloud):
		cloud.visible = on and layer == "brain3d"


func _on_brain_button() -> void:
	# BRAIN button cycles every representation (bars/flow/raster/3D)
	# so the views are discoverable without knowing the keys; B
	# still toggles visibility outright.
	var any_hidden := false
	if is_instance_valid(bv_panel_alpha) and not bv_panel_alpha.visible:
		any_hidden = true
	if is_instance_valid(bv_panel_beta) and not bv_panel_beta.visible:
		any_hidden = true
	if any_hidden:
		if is_instance_valid(bv_panel_alpha):
			bv_panel_alpha.visible = true
		if is_instance_valid(bv_panel_beta):
			bv_panel_beta.visible = true
		# Spike readout lines stay hidden (see _apply_brainview_settings).
		_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")
	else:
		_cycle_bv_layer()


func _toggle_brainview() -> void:
	# Master visibility switch: bars flip here, every other layer
	# re-resolves from the menu layer underneath.
	var show_now := true
	if is_instance_valid(bv_panel_alpha):
		show_now = not bv_panel_alpha.visible
		bv_panel_alpha.visible = show_now
	if is_instance_valid(bv_panel_beta):
		bv_panel_beta.visible = show_now
	# Spike readout lines stay hidden (see _apply_brainview_settings).
	_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")


func _bv_layer_is_flow() -> bool:
	var director := _director()
	if director == null:
		return false
	var layer := str(director.brainview_layer)
	return layer == "flow" or layer == "raster"


func _update_brainview(st_a: Dictionary, st_b: Dictionary, stats: Dictionary) -> void:
	# Per-layer gating: hiding the bars must not freeze the diagram,
	# raster, cloud, or stream recording behind them.
	if is_instance_valid(bv_panel_alpha) and bv_panel_alpha.visible:
		_update_bv_side(st_a, bv_rows_alpha, bv_ema_alpha)
	if is_instance_valid(bv_panel_beta) and bv_panel_beta.visible:
		_update_bv_side(st_b, bv_rows_beta, bv_ema_beta)
	_record_bv_stream(st_a, st_b)
	# Wiring/mapping labels ride the stats envelope (server adds them
	# every step; cached per side so edges keep resolving regardless).
	var sw: Dictionary = stats.get("wiring", {})
	var sm: Dictionary = stats.get("mapping", {})
	if not sw.is_empty():
		bv_wiring_alpha = _parse_wiring_label(str(sw.get("alpha", "base")))
		bv_wiring_beta = _parse_wiring_label(str(sw.get("beta", "base")))
	if not sm.is_empty():
		bv_mapping_alpha = _parse_mapping(sm.get("alpha", []))
		bv_mapping_beta = _parse_mapping(sm.get("beta", []))
	if is_instance_valid(bv_flow_alpha) and bv_flow_alpha.visible:
		bv_flow_alpha.refresh(bv_ema_alpha, bv_caps, bv_wiring_alpha, bv_mapping_alpha)
	if is_instance_valid(bv_flow_beta) and bv_flow_beta.visible:
		bv_flow_beta.refresh(bv_ema_beta, bv_caps, bv_wiring_beta, bv_mapping_beta)
	_push_bv_raster(st_a, "alpha")
	_push_bv_raster(st_b, "beta")
	_push_bv_cloud(st_a, "alpha")
	_push_bv_cloud(st_b, "beta")


func _push_bv_cloud(st: Dictionary, side: String) -> void:
	var cloud: Node3D = bv_cloud_alpha if side == "alpha" else bv_cloud_beta
	if not is_instance_valid(cloud) or not cloud.visible:
		return
	for child in cloud.get_children():
		if child.has_method("push_spikes"):
			child.push_spikes(st.get("spike_ids", []))
	_update_bv_nets(side)


func _update_bv_nets(side: String) -> void:
	# Network overlay: pool-to-pool flow lines at real centroid
	# positions, lit by presynaptic drive, gated on this fighter's
	# wiring mix + mapping (mirrors the 2D flow diagram).
	var cloud: Node3D = bv_cloud_alpha if side == "alpha" else bv_cloud_beta
	if not is_instance_valid(cloud):
		return
	var emas: Dictionary = bv_ema_alpha if side == "alpha" else bv_ema_beta
	var wiring: Array = bv_wiring_alpha if side == "alpha" else bv_wiring_beta
	var mapping: Array = bv_mapping_alpha if side == "alpha" else bv_mapping_beta
	var edges: Array = []
	for e in BV_NETS:
		var kind := str(e[2])
		var on := true
		if kind in BV_NET_WIRING:
			on = BV_NET_WIRING[kind] in wiring
		elif kind in BV_NET_SCHEME:
			on = BV_NET_SCHEME[kind] in mapping
		elif kind == "value":
			on = "mbon" in mapping
		if not on:
			continue
		if not bv_cloud_centroids.has(e[0]) or not bv_cloud_centroids.has(e[1]):
			continue
		var cap := float(bv_caps.get(str(e[0]), 30.0))
		var drive := 0.0
		if cap > 0.0:
			drive = clampf(float(emas.get(str(e[0]), 0.0)) / cap, 0.0, 1.0)
		if drive < 0.02:
			continue
		edges.append([bv_cloud_centroids[e[0]], bv_cloud_centroids[e[1]],
			drive, BV_NET_COLORS.get(str(e[0]), Color(0.7, 0.7, 0.75))])
	for child in cloud.get_children():
		if child.has_method("set_nets"):
			child.set_nets(edges)


func _bv_stream_row(st: Dictionary) -> Array:
	# Fixed BV_POOLS order (dn splits read top-level like the bars).
	# Ints, not floats: pool counts serialize ~2x smaller into the
	# banked JSON (600 steps x 23 pools x 2 flies).
	var pools: Dictionary = st.get("pools", {})
	var row: Array = []
	row.resize(BV_POOLS.size())
	for i in range(BV_POOLS.size()):
		var key := str(BV_POOLS[i][0])
		row[i] = int(st.get(key, pools.get(key, 0.0)))
	return row


func _record_bv_stream(st_a: Dictionary, st_b: Dictionary) -> void:
	if not is_round_active:
		return
	var director := _director()
	if director == null or not bool(director.brainview_replay):
		return
	if bv_stream_alpha.size() >= BV_STREAM_MAX:
		return
	bv_stream_alpha.append(_bv_stream_row(st_a))
	bv_stream_beta.append(_bv_stream_row(st_b))


func _bv_stream_packet() -> Dictionary:
	var keys: Array = []
	for spec in BV_POOLS:
		keys.append(str(spec[0]))
	return {"pools": keys, "alpha": bv_stream_alpha, "beta": bv_stream_beta}


func _push_bv_raster(st: Dictionary, side: String) -> void:
	var raster: Control = bv_raster_alpha if side == "alpha" else bv_raster_beta
	if not is_instance_valid(raster) or not raster.visible:
		return
	raster.push_step(st.get("spike_ids", []))


func _update_bv_side(st: Dictionary, rows: Dictionary, emas: Dictionary) -> void:
	var pools: Dictionary = st.get("pools", {})
	for key in rows.keys():
		# dn_left/dn_right ride at stats top level (legacy HUD keys);
		# everything else lives in the pools dict.
		var count := float(st.get(key, pools.get(key, 0.0)))
		emas[key] = lerpf(float(emas.get(key, 0.0)), count, 0.35)
	_render_bv_side(rows, emas)


func _render_bv_side(rows: Dictionary, emas: Dictionary) -> void:
	# Bar painter shared by live EMA and replay frames (replay passes
	# throwaway EMA dicts so live smoothing is never polluted).
	for key in rows.keys():
		var slot: Array = rows[key]
		var ema := float(emas.get(key, 0.0))
		(slot[0] as ProgressBar).value = clampf(ema / float(slot[2]), 0.0, 1.0) * 100.0
		(slot[1] as Label).text = str(int(ema))

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
	_flash_body(fly_alpha if victim_id == "alpha" else fly_beta, 1.0)

func _flash_attacker(attacker_id: String, strength: float) -> void:
	var rect := alpha_hit_flash if attacker_id == "alpha" else beta_hit_flash
	if rect != null:
		_flash_rect(rect, Color(1.0, 1.0, 0.8), strength)
	_flash_body(fly_alpha if attacker_id == "alpha" else fly_beta, 0.6)

func _flash_rect(rect: ColorRect, color: Color, strength: float) -> void:
	rect.color = Color(color.r, color.g, color.b, strength)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, 0.4)

func _flash_body(fly: CharacterBody3D, strength: float) -> void:
	# Chitin-shader flash: the fly owns a decaying flash_energy uniform
	# (FlyPhysics.flash_hit); the old StandardMaterial3D emission poke
	# died with the flat team-blob material.
	if not is_instance_valid(fly):
		return
	if fly.has_method("flash_hit"):
		fly.call("flash_hit", strength)

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

func _show_loading(title: String, sub: String, title_color: Color = Color(0.85, 0.85, 0.9)) -> void:
	# Persistent overlay (no countdown): proves the game is waiting on the
	# server, not frozen. Hidden by _hide_loading on the matching reply.
	# Smaller fonts than the winner callout so multi-line status text
	# wraps on-screen instead of running off the edges.
	if is_instance_valid(winner_label):
		winner_label.text = title
		winner_label.add_theme_font_size_override("font_size", 44)
		winner_label.add_theme_color_override("font_color", title_color)
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

const BLOW_NAMES := {
	"thorax_puncture": "THORAX PUNCTURE",
	"wing_tear": "WING TEAR (forfeit)",
	"spike_wound": "spike wound",
	"spike_clash": "spike clash",
	"tree_slam": "tree slam",
	"tree_clip": "tree clip",
	"seizure": "seizure drain",
}


func _killing_blow(victim_slot: String) -> Dictionary:
	var fly: CharacterBody3D = fly_alpha if victim_slot == "alpha" else fly_beta
	if not is_instance_valid(fly):
		return {"source": "", "amount": 0.0}
	return {"source": str(fly.get("last_damage_source")),
		"amount": float(fly.get("last_damage_amount"))}


func _compose_verdict(draw: bool) -> Dictionary:
	# Who/how the battle ended, for the server report, callout, and
	# retry. Timeout winners are unknown here (server picks on fitness),
	# so the winner slot stays empty and the line says who decides.
	var v := {"end_reason": "draw" if draw else _end_reason,
		"winner_slot": "", "loser_slot": "", "blow_source": "",
		"blow_amount": 0.0, "time_left": maxf(current_round_time, 0.0),
		"dmg_a": float(stats_alpha.get("damage_dealt", 0.0)),
		"dmg_b": float(stats_beta.get("damage_dealt", 0.0)), "line": ""}
	if draw:
		v["line"] = "DRAW - time expired, nobody bled"
	elif _end_reason == "ko" and (_ko_victim == "alpha" or _ko_victim == "beta"):
		var winner_slot := "beta" if _ko_victim == "alpha" else "alpha"
		var blow := _killing_blow(_ko_victim)
		v["winner_slot"] = winner_slot
		v["loser_slot"] = _ko_victim
		v["blow_source"] = str(blow["source"])
		v["blow_amount"] = float(blow["amount"])
		var blow_src := str(v["blow_source"])
		var blow_name := str(BLOW_NAMES[blow_src]) if BLOW_NAMES.has(blow_src) else blow_src
		v["line"] = "%s WINS by KO - killing blow: %s %.1f on %s" % [
			_slot_name(winner_slot), blow_name, v["blow_amount"],
			_slot_name(_ko_victim)]
	else:
		v["end_reason"] = "time"
		v["line"] = "TIME - damage %.0f-%.0f, server decides on fitness" % [
			v["dmg_a"], v["dmg_b"]]
	print("[Arena] Verdict: ", v["line"])
	return v


func _verdict_short() -> String:
	# One-line verdict for the battle callout (full line went to the
	# server report + console at report time).
	var reason := str(_last_verdict.get("end_reason", ""))
	if reason == "ko":
		var bsrc := str(_last_verdict.get("blow_source", ""))
		var blow := str(BLOW_NAMES[bsrc]) if BLOW_NAMES.has(bsrc) else "?"
		var amt := float(_last_verdict.get("blow_amount", 0.0))
		return "KO - %s %s" % [blow,
			("%.1f" % amt) if amt > 0.0 else "finisher"]
	if reason == "time":
		return "TIME - dmg %.0f-%.0f" % [
			float(_last_verdict.get("dmg_a", 0.0)),
			float(_last_verdict.get("dmg_b", 0.0))]
	return ""


func _draw_title() -> String:
	# Numbered draws: the banked count doesn't include the latest one
	# yet, so +1 (a third draw resolves the match instead of replaying).
	var director := _director()
	var draws := 0
	if director != null:
		draws = int(director.current_match().get("draws", 0))
	return "DRAW" if draws + 1 <= 1 else "DRAW x%d" % (draws + 1)


func _verdict_headline() -> Dictionary:
	# Big-overlay headline for the reporting screen: the outcome first
	# (winner + killing blow), the reporting detail beneath it.
	var reason := str(_last_verdict.get("end_reason", ""))
	if reason == "ko":
		var winner_slot := str(_last_verdict.get("winner_slot", "alpha"))
		var blow_src := str(_last_verdict.get("blow_source", ""))
		var blow := str(BLOW_NAMES[blow_src]) if BLOW_NAMES.has(blow_src) else blow_src
		var amt := float(_last_verdict.get("blow_amount", 0.0))
		var detail := "%s %s" % [blow, ("%.1f" % amt)] if amt > 0.0 else blow
		return {"text": "%s WINS BY KO" % _slot_name(winner_slot),
			"sub": "Killing blow: %s" % detail,
			"color": Color(1.0, 0.55, 0.3) if winner_slot == "alpha" else Color(0.4, 0.75, 1.0)}
	if reason == "time":
		return {"text": "TIME - SERVER DECIDES",
			"sub": "Damage %.0f-%.0f" % [float(_last_verdict.get("dmg_a", 0.0)),
				float(_last_verdict.get("dmg_b", 0.0))],
			"color": Color(0.78, 0.78, 0.85)}
	return {"text": _draw_title(),
		"sub": "Stalemate - nobody bled",
		"color": Color(0.78, 0.78, 0.82)}


func _report_battle(draw: bool, draw_penalty: bool = false) -> void:
	# Single choke point for tournament battle reports: stamps the same
	# (tournament, match, battle) id used as the server's idempotency key,
	# keeps a copy for one safe retry, and arms the battle watchdog.
	# draw_penalty marks a 3rd draw so the server docks both ELOs.
	_seq_battle_id = _current_battle_id()
	_tourney_awaiting_battle = true
	var fa := _flight_summary(flight_alpha, fly_alpha)
	var fb := _flight_summary(flight_beta, fly_beta)
	_last_verdict = _compose_verdict(draw)
	_seq_last_round = {
		"stats_a": stats_alpha.duplicate(), "stats_b": stats_beta.duplicate(),
		"draw": draw, "tournament_id": _tourney_id(), "match": tourney_match_label,
		"flight_a": fa, "flight_b": fb,
		"end_reason": str(_last_verdict.get("end_reason", "")),
		"verdict": _last_verdict.duplicate()}
	brain_client.send_round_over(stats_alpha, stats_beta, draw, _seq_battle_id,
		_tourney_id(), tourney_match_label, fa, fb, draw_penalty,
		str(_last_verdict.get("end_reason", "")), _last_verdict)
	_print_flight_line("alpha", fa)
	_print_flight_line("beta", fb)
	_arm_seq("battle")
	# Verdict headlines big on top (winner + killing blow); the
	# reporting detail sits beneath in smaller type.
	var head := _verdict_headline()
	_show_loading(str(head.get("text", "")),
		"%s\n%s - battle %s sent, waiting for server..." % [
		str(head.get("sub", "")), tourney_match_label, _seq_battle_id],
		head.get("color", Color(0.85, 0.85, 0.9)))
	if is_instance_valid(status_label):
		status_label.text = "%s - %s (%s REPORTING)" % [
			str(head.get("text", "")), str(head.get("sub", "")),
			tourney_match_label]

func _handle_draw() -> void:
	print("[Arena] Stalemate! Time expired with zero damage - DRAW, rematch same brains.")
	is_round_active = false
	# Both walk away: land upright for the rematch.
	_begin_landing("")
	if tournament_active:
		# Server records the draw (no dopamine) and replies tournament_battle
		# "draw"; sequencing continues in _on_tournament_battle. A draw
		# reported while two are already banked is the 3rd: flag it so
		# the server docks both ELOs for stalling the match out.
		var third := false
		var director := _director()
		if director != null:
			third = int(director.current_match().get("draws", 0)) >= 2
		_report_battle(true, third)
		return
	_show_winner_and_countdown(
		"DRAW",
		Color(0.78, 0.78, 0.82),
		"TIME UP - NOBODY BLED - REMATCH",
		"REMATCH")

# ?�?� Dynamic tree fade ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�
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

func _evo_watcher_tick(delta: float) -> void:
	# Background pipeline pump, throttled: adopts finished breeds,
	# launches queued specs when the shared slot is free, refreshes
	# the bottom-left status line. No-ops unless evo is active.
	if not _evo_active():
		if is_instance_valid(evo_status_line):
			evo_status_line.visible = false
		return
	_evo_adopt_finished()
	var director := _director()
	if director != null and not evo_waiting and director.pending_async.is_empty():
		for spec in _evo_pending():
			var s := spec as Dictionary
			if not bool(s.get("launched", false)) \
					and _evo_blocking_spec(str(s.get("kind", ""))).is_empty():
				_evo_spawn_spec(spec)
				break
	evo_status_tick += delta
	if evo_status_tick < EVO_STATUS_EVERY:
		return
	evo_status_tick = 0.0
	_update_evo_status_line()


func _update_evo_status_line() -> void:
	if not is_instance_valid(evo_status_line):
		return
	var director := _director()
	if director == null:
		evo_status_line.visible = false
		return
	var evo: Dictionary = director.tourney.get("evo", {})
	var gen := int(evo.get("generation", 1))
	var parts: Array = []
	for spec in _evo_pending():
		var s := spec as Dictionary
		var label := str(s.get("name", ""))
		if label == "":
			label = "wild G%d" % int(s.get("gen", gen + 1))
		if bool(s.get("launched", false)):
			var prog := _evo_poll_file(str(s.get("progress", "")))
			if prog.is_empty():
				parts.append("%s warming up" % label)
			else:
				parts.append("%s ep %d/%d" % [label,
					int(prog.get("episode", 0)), EVO_EPISODES])
		else:
			parts.append("%s queued" % label)
	for kind in (evo.get("done", {}) as Dictionary).keys():
		parts.append("%s done" % _evo_done_name(str(kind)))
	if parts.is_empty():
		evo_status_line.visible = false
		return
	evo_status_line.text = "EVO G%d • %s" % [gen, " • ".join(parts)]
	evo_status_line.visible = true


var _shot_path := ""
var _shot_frames := 0
var _shot_done := false


func _process(delta: float) -> void:
	# Dev screenshot hook: `--shot=C:/path/out.png` saves one viewport
	# frame ~1 s after boot. Untouched in normal runs.
	if not _shot_done:
		if _shot_path == "":
			for a in OS.get_cmdline_user_args():
				if str(a).begins_with("--shot="):
					_shot_path = str(a).get_slice("=", 1)
					_shot_frames = 0
					break
		if _shot_path != "":
			_shot_frames += 1
			if _shot_frames >= 500:
				var img := get_viewport().get_texture().get_image()
				var err := img.save_png(_shot_path)
				print("[Arena] Screenshot -> %s (err=%s)" % [_shot_path, str(err)])
				_shot_done = true
	_evo_watcher_tick(delta)
	# Evo spinner animation while the phase panel is up.
	if is_instance_valid(evo_panel) and evo_panel.visible:
		evo_spin_tick += delta
		if evo_spin_tick >= 0.1:
			evo_spin_tick = 0.0
			evo_spin_frame = (evo_spin_frame + 1) % EVO_SPINNER.size()
			if is_instance_valid(evo_spinner):
				evo_spinner.text = EVO_SPINNER[evo_spin_frame]
	# Soma-cloud slow spin for depth while visible.
	if is_instance_valid(bv_cloud_alpha) and bv_cloud_alpha.visible:
		bv_cloud_alpha.rotate_y(0.25 * delta)
	if is_instance_valid(bv_cloud_beta) and bv_cloud_beta.visible:
		bv_cloud_beta.rotate_y(0.25 * delta)
	# Replay playback: 5 Hz frame advance through the banked stream.
	if bv_replay_mode and bv_replay_playing and not bv_stream_alpha.is_empty():
		bv_replay_accum += delta
		while bv_replay_accum >= 0.2:
			bv_replay_accum -= 0.2
			if bv_replay_idx < bv_stream_alpha.size() - 1:
				bv_replay_idx += 1
				bv_replay_slider.value = float(bv_replay_idx)
				_render_replay_frame()
			else:
				bv_replay_playing = false
				bv_replay_playbtn.text = "Play"
				break
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

# ?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�?�

func _update_ctrl_label() -> void:
	if not is_instance_valid(ctrl_label):
		return
	var hz := 0.0
	if bv_reply_ema > 0.001:
		hz = 1.0 / bv_reply_ema
	ctrl_label.text = "CTRL %.1fHz t%.2f" % [hz, bv_shared_tau]


func _on_motor_controls(ctrl_alpha: Dictionary, ctrl_beta: Dictionary, gen: int, stats: Dictionary = {}) -> void:
	# Shared cadence tracking: reply interval EMA -> shared hold tau
	# (0.75x, clamped 0.10-0.40), set identically on both flies.
	var now := Time.get_ticks_msec() / 1000.0
	if bv_last_reply > 0.0:
		var dt := maxf(now - bv_last_reply, 0.001)
		bv_reply_ema = lerpf(bv_reply_ema, dt, 0.2)
		bv_shared_tau = clampf(0.75 * bv_reply_ema, 0.10, 0.40)
		bv_cad_n += 1
		bv_cad_dt_sum += dt
		bv_cad_tau_sum += bv_shared_tau
	bv_last_reply = now
	if is_instance_valid(fly_alpha):
		fly_alpha.hold_tau = bv_shared_tau
	if is_instance_valid(fly_beta):
		fly_beta.hold_tau = bv_shared_tau
	_update_ctrl_label()
	current_generation = gen
	fly_alpha.apply_brain_controls(ctrl_alpha)
	fly_beta.apply_brain_controls(ctrl_beta)
	_accum_flight(flight_alpha, fly_alpha, ctrl_alpha)
	_accum_flight(flight_beta, fly_beta, ctrl_beta)
	_update_brainview(stats.get("alpha", {}), stats.get("beta", {}), stats)
	# Brain activation readout: spikes + descending-neuron balance per fly.
	var st_a = stats.get("alpha", {})
	var st_b = stats.get("beta", {})
	if is_instance_valid(brain_alpha_label) and brain_alpha_label.visible:
		brain_alpha_label.text = "%s brain n=%d DN L/R %d/%d LPLC2 %d MN %d VS %d thrust %.2f yaw %+.2f pitch %+.2f roll %+.2f" % [
			(_slot_name("alpha") + "      ").substr(0, 6),
			int(st_a.get("spikes", 0)), int(st_a.get("dn_left", 0)), int(st_a.get("dn_right", 0)),
			int(st_a.get("lplc2", 0)), int(st_a.get("mn_thrust", 0)), int(st_a.get("vs_flow", 0)),
			float(ctrl_alpha.get("thrust", 0.2)), float(ctrl_alpha.get("yaw_torque", 0.0)),
			float(ctrl_alpha.get("pitch_torque", 0.0)), float(ctrl_alpha.get("roll_torque", 0.0))]
	if is_instance_valid(brain_beta_label) and brain_beta_label.visible:
		brain_beta_label.text = "%s brain n=%d DN L/R %d/%d LPLC2 %d MN %d VS %d thrust %.2f yaw %+.2f pitch %+.2f roll %+.2f" % [
			(_slot_name("beta") + "      ").substr(0, 6),
			int(st_b.get("spikes", 0)), int(st_b.get("dn_left", 0)), int(st_b.get("dn_right", 0)),
			int(st_b.get("lplc2", 0)), int(st_b.get("mn_thrust", 0)), int(st_b.get("vs_flow", 0)),
			float(ctrl_beta.get("thrust", 0.2)), float(ctrl_beta.get("yaw_torque", 0.0)),
			float(ctrl_beta.get("pitch_torque", 0.0)), float(ctrl_beta.get("roll_torque", 0.0))]

func _new_flight_accum() -> Dictionary:
	return {"n": 0, "alt_sum": 0.0, "alt_min": 999.0, "alt_max": -999.0,
		"thrust_sum": 0.0, "pitch_sum": 0.0, "yaw_abs_sum": 0.0,
		"evade_steps": 0, "ram_steps": 0, "spear_max": 0.0}


func _accum_flight(acc: Dictionary, fly: CharacterBody3D, ctrl: Dictionary) -> void:
	if acc.is_empty():
		acc.merge(_new_flight_accum())
	acc["n"] = int(acc["n"]) + 1
	var alt := (fly as Node3D).global_position.y
	acc["alt_sum"] = float(acc["alt_sum"]) + alt
	acc["alt_min"] = minf(float(acc["alt_min"]), alt)
	acc["alt_max"] = maxf(float(acc["alt_max"]), alt)
	acc["thrust_sum"] = float(acc["thrust_sum"]) + float(ctrl.get("thrust", 0.2))
	acc["pitch_sum"] = float(acc["pitch_sum"]) + float(ctrl.get("pitch_torque", 0.0))
	acc["yaw_abs_sum"] = float(acc["yaw_abs_sum"]) + absf(float(ctrl.get("yaw_torque", 0.0)))
	if bool(ctrl.get("emergency_evade", false)):
		acc["evade_steps"] = int(acc["evade_steps"]) + 1
	if bool(ctrl.get("ram_burst", false)):
		acc["ram_steps"] = int(acc["ram_steps"]) + 1
	acc["spear_max"] = maxf(float(acc["spear_max"]), float(ctrl.get("spear_thrust", 0.0)))


func _flight_summary(acc: Dictionary, fly: CharacterBody3D) -> Dictionary:
	if acc.is_empty() or int(acc.get("n", 0)) == 0:
		return {"samples": 0}
	var n := float(acc["n"])
	# FlyPhysics carries lunge_count (`in` and two-arg .get() are
	# both invalid on Objects and would abort battle reporting here).
	var lunges := 0
	if fly != null and fly is FlyPhysicsScript:
		lunges = int((fly as FlyPhysicsScript).lunge_count)
	return {
		"samples": int(acc["n"]),
		"alt_mean": snappedf(float(acc["alt_sum"]) / n, 0.01),
		"alt_min": snappedf(float(acc["alt_min"]), 0.01),
		"alt_max": snappedf(float(acc["alt_max"]), 0.01),
		"thrust_mean": snappedf(float(acc["thrust_sum"]) / n, 0.001),
		"pitch_mean": snappedf(float(acc["pitch_sum"]) / n, 0.001),
		"yaw_abs_mean": snappedf(float(acc["yaw_abs_sum"]) / n, 0.001),
		"evade_frac": snappedf(float(acc["evade_steps"]) / n, 0.001),
		"ram_frac": snappedf(float(acc["ram_steps"]) / n, 0.001),
		"spear_max": snappedf(float(acc["spear_max"]), 0.01),
		"lunges": lunges,
		"ctrl_hz": snappedf(float(bv_cad_n) / maxf(bv_cad_dt_sum, 0.001), 0.01),
		"tau": snappedf(bv_cad_tau_sum / maxf(bv_cad_n, 1), 0.001),
	}


func _print_flight_line(slot: String, f: Dictionary) -> void:
	if f.is_empty() or int(f.get("samples", 0)) == 0:
		return
	print("[Arena] Flight %s: alt mean %.1f [%.1f-%.1f] thrust %.2f pitch %+.3f yaw|.| %.3f evade %.1f%% ram %.1f%% spear_max %.2f lunges %d (%d samples) ctrl %.1fHz t%.3f" % [
		slot, float(f.get("alt_mean", 0.0)), float(f.get("alt_min", 0.0)),
		float(f.get("alt_max", 0.0)), float(f.get("thrust_mean", 0.0)),
		float(f.get("pitch_mean", 0.0)), float(f.get("yaw_abs_mean", 0.0)),
		100.0 * float(f.get("evade_frac", 0.0)), 100.0 * float(f.get("ram_frac", 0.0)),
		float(f.get("spear_max", 0.0)), int(f.get("lunges", 0)), int(f.get("samples", 0)),
		float(f.get("ctrl_hz", 0.0)), float(f.get("tau", 0.0))])


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
	_end_reason = "ko"
	_ko_victim = victim_id

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

	# Landing ceremony instead of a frozen frame: loser drops
	# belly-up, winner lowers onto its feet (runs behind the banner).
	_begin_landing("beta" if victim_id == "alpha" else "alpha")
	_end_round()


func _begin_landing(winner_slot: String) -> void:
	# winner_slot "alpha"/"beta", or "" for a draw (both land upright).
	for side in ["alpha", "beta"]:
		var fly: CharacterBody3D = fly_alpha if side == "alpha" else fly_beta
		if is_instance_valid(fly):
			fly.begin_landing(winner_slot == "" or side == winner_slot)


func _await_landing() -> void:
	# Holds the round reset until both flies are down (bounded: a fly
	# stuck on a tree still resets after 8 s).
	var waited := 0.0
	while waited < 8.0:
		var a_down := true
		if is_instance_valid(fly_alpha):
			a_down = bool(fly_alpha.landing_done())
		var b_down := true
		if is_instance_valid(fly_beta):
			b_down = bool(fly_beta.landing_done())
		if a_down and b_down:
			return
		await get_tree().create_timer(0.25).timeout
		waited += 0.25

# Knockout banner: free battle keeps the classic "FLY ALPHA" phrasing;
# tournament battles use the assigned brain name.
func _ko_text(winner_slot: String) -> String:
	var n := _slot_name(winner_slot)
	if tournament_active:
		return "KNOCKOUT! %s WINS!" % n
	return "KNOCKOUT! FLY %s WINS!" % n

func _check_speed_violations() -> void:
	# ILLEGAL-speed marking: a fly that lived pinned at the hard speed
	# cap was flying impossibly (the G2-wild zoom exploit), not
	# skillfully. The physics cap already neutralized it mid-battle;
	# this marks the record on console + status. Dynamic .get() because
	# the flies are statically CharacterBody3D (FlyPhysics members).
	for side in ["alpha", "beta"]:
		var fly: CharacterBody3D = fly_alpha if side == "alpha" else fly_beta
		if not is_instance_valid(fly):
			continue
		if not bool(fly.get("speed_exploit")):
			continue
		var frac := 0.0
		if float(fly.get("fly_time")) > 0.0:
			frac = float(fly.get("capped_time")) / float(fly.get("fly_time"))
		var msg := "ILLEGAL SPEED: %s capped %.0f%% of battle (peak %.1f m/s)" % [
			_slot_name(side), frac * 100.0, float(fly.get("peak_speed"))]
		print("[Arena] ", msg)
		if is_instance_valid(status_label):
			status_label.text = msg


func _end_round() -> void:
	is_round_active = false
	_check_speed_violations()
	print("[Arena] Round concluded! Sending battle stats to evolution engine...")
	if tournament_active:
		_report_battle(false)
		return
	var fa := _flight_summary(flight_alpha, fly_alpha)
	var fb := _flight_summary(flight_beta, fly_beta)
	_print_flight_line("alpha", fa)
	_print_flight_line("beta", fb)
	_last_verdict = _compose_verdict(false)
	# Free battles carry a unique id (no vault records to key on, so the
	# server dedups on this): a lost reply is simply lost, but a retry
	# can never advance two generations.
	var free_id := "FREE-%d" % Time.get_ticks_msec()
	brain_client.send_round_over(stats_alpha, stats_beta, false, free_id, "", "", fa, fb,
		false, str(_last_verdict.get("end_reason", "")), _last_verdict)

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
	# Session wins tally: _record_win previously only ran on the
	# free-battle paths, so tournament/quick battle wins never moved the
	# WINS label. Draws record nothing (no winner).
	if battle_winner == "alpha" or battle_winner == "beta":
		_record_win(battle_winner)
	if battle_winner == "draw":
		var draw_title := _draw_title()
		if is_instance_valid(status_label):
			status_label.text = "%s %s - REPLAYING" % [tourney_match_label, draw_title]
		_begin_landing("")
		_show_callout(draw_title, Color(0.78, 0.78, 0.82),
			"%s STALEMATE - REPLAY" % tourney_match_label, "REMATCH", false)
		await get_tree().create_timer(5.0).timeout
		var draw_adv: Dictionary = director.on_battle_result("draw",
			_flight_summary(flight_alpha, fly_alpha),
			_flight_summary(flight_beta, fly_beta),
			_bv_stream_packet())
		# Third draw resolves the match outright (higher ELO advances)
		# instead of replaying forever.
		if str(draw_adv.get("action", "")) == "match_over":
			var draw_score := "%d - %d" % [int(draw_adv.get("score_a", 0)), int(draw_adv.get("score_b", 0))]
			_on_match_over(str(draw_adv.get("match_winner", "alpha")), draw_score)
			return
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")
		return
	var winner_name := tourney_a_name if battle_winner == "alpha" else tourney_b_name
	var res: Dictionary = director.on_battle_result(battle_winner,
		_flight_summary(flight_alpha, fly_alpha),
		_flight_summary(flight_beta, fly_beta),
		_bv_stream_packet())
	var action := str(res.get("action", "next_battle"))
	print("[Arena] Battle result: winner=", battle_winner, " action=", action,
		" verdict=", str(_last_verdict.get("line", "")))
	var score := "%d - %d" % [int(res.get("score_a", 0)), int(res.get("score_b", 0))]
	if action == "match_over":
		var match_winner := str(res.get("match_winner", battle_winner))
		_on_match_over(match_winner, score)
	else:
		var sub := "%s  BATTLE %d" % [tourney_match_label, _battle_count() + 1]
		var vshort := _verdict_short()
		if vshort != "":
			sub += "  |  " + vshort
		_show_callout("%s TAKES BATTLE (%s)" % [winner_name, score],
			Color(1.0, 0.55, 0.3) if battle_winner == "alpha" else Color(0.4, 0.75, 1.0),
			sub, "NEXT BATTLE", false)
		await get_tree().create_timer(5.0).timeout
		_update_tourney_status("BATTLE %d" % (_battle_count() + 1))
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")

func _on_match_over(match_winner: String, score: String) -> void:
	var match_name := tourney_a_name if match_winner == "alpha" else tourney_b_name
	brain_client.request_tournament_match(match_winner, _tourney_id(), tourney_match_label)
	# Advance synchronously BEFORE the overlay wait: advance_after_match
	# is pure logic + save, while the 6 s await below dies with the scene
	# if the user quits to menu mid-overlay - which used to swallow the
	# title request (and the evo chain) after the match was already
	# banked. Banking requests are fire-and-forget; only the ack display
	# below is allowed to depend on the wait.
	var adv := {"action": "next_match"}
	var director := _director()
	if director != null:
		adv = director.advance_after_match()
	# The bracket overlay carries the result: gold connectors show the
	# path, the loser is grayed out, next lineup is visible.
	_show_arena_bracket("%s TAKES %s  (%s)" % [match_name, tourney_match_label, score])
	await get_tree().create_timer(6.0).timeout
	_hide_arena_bracket()
	_handle_advance_result(adv)


func _battle_count() -> int:
	var director := _director()
	if director == null:
		return 0
	var m: Dictionary = director.current_match()
	return int(m.get("battles", 0))

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
		# Evolution mode: skip the review-wait and breed the next
		# generation instead (champion display happens inside).
		if _evo_active():
			_run_evo_generation()
			return
		var last_line := ""
		var last_id := str(res.get("last_place_id", ""))
		if last_id != "":
			last_line = " - LAST PLACE %s" % director.last_place_name()
		# The final bracket stays open for review: no auto-hide, no auto
		# quit. The user leaves via QUIT TO MENU in the bottom bar when
		# done (the bracket CLOSE button only hides the overlay; BRACKET
		# re-opens it).
		_hide_loading()
		winner_overlay.visible = false
		_show_arena_bracket("CHAMPION: %s - REVIEWING BRACKET" % champ_name)
		_save_bracket_record(true)
		if is_instance_valid(status_label):
			status_label.text = "TOURNAMENT COMPLETE - CHAMPION %s%s - review, then QUIT TO MENU" % [champ_name, last_line]
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
			status_label.text = "TOURNAMENT COMPLETE - CHAMPION %s%s (title banked) - review, then QUIT TO MENU" % [champ_name, last_line]
	else:
		if bool(res.get("consolation_started", false)):
			_show_arena_bracket("LOSERS BRACKET - LOSER ADVANCES TO LAST PLACE")
			if is_instance_valid(status_label):
				status_label.text = "Main champion crowned - loser advances, converging to last place."
			# Pipeline: queue clone breed from champion while consolation runs.
			# The wild head-start has trained since tourney start; announce
			# the generation now that its champion half is known, and
			# refresh immediately instead of waiting for the 5s tick.
			if _evo_active():
				var evo: Dictionary = director.tourney.get("evo", {})
				var gen := int(evo.get("generation", 1))
				var champ_name: String = director.champion_name()
				_evo_queue_clone(gen + 1, str(director.tourney.get("champion_id", "")),
					champ_name)
				_update_evo_status_line()
				if is_instance_valid(status_label):
					status_label.text = "EVO GEN %d begun - training %s + wild in background..." % [gen + 1, director.kin_name(champ_name, gen + 1)]
			await get_tree().create_timer(3.0).timeout
			_hide_arena_bracket()
		_request_current_battle_load()

func _evo_active() -> bool:
	var director := _director()
	if director == null:
		return false
	return bool(director.tourney.get("evo", {}).get("active", false))


const EVO_EPISODES := 50
# Await/slot-wait ceiling: two-stage breeds (25+25 eps) run ~40+ min on
# this hardware (single-stage wild already took 22 min). The old fixed
# 20-min timeout aborted generations mid-training while the worker was
# still legitimately burning CPU - the log showed only the banner
# (buffered) and the verdict never landed. Episodes-proportional: 50
# eps x 80 s + loader headroom = 66 min.
const EVO_AWAIT_TIMEOUT := EVO_EPISODES * 80.0
# Two-step evo breeding: half the episodes pre-train, half Advanced
# Flight School (default school curriculum; school code selects stages).
# NOTE: this JSON must NEVER ride argv (--params2): Godot strips embedded
# double-quotes when joining argv on Windows, corrupting it exactly like
# the old empty --name bug. _evo_params2_file writes it to disk and the
# spawns pass --params2-file instead (same pattern as generate_brain_async).
const EVO_SCHOOL_PARAMS := '{"curriculum": {}}'
const EVO_NOISE := 0.05


func _evo_params2_file(result_file: String) -> String:
	# Writes the school params JSON next to the result file; returns the
	# path for --params2-file, or "" when unwritable (caller then omits
	# stage 2 and the breed degrades to single-stage instead of aborting).
	var path := result_file.get_base_dir().path_join(
		result_file.get_file().get_basename() + "_params2.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(EVO_SCHOOL_PARAMS)
	f.close()
	return path
var evo_waiting := false
var evo_wait_result := {}
var evo_breed_pid := 0
# Display name of the brain banked by the last _evo_await_result success
# (wild brains are christened Python-side; the id alone can't show it).
var evo_last_bred_name := ""
# Last _evo_spawn_spec failure text, so tournament-end aborts can say
# WHY a breed never started (e.g. slot held by a stuck worker) instead
# of just "check brains/jobs log".
var evo_last_spawn_error := ""
# Pipelined breeding: specs live in tourney["evo"]["pending"], completions
# in ["done"], so quit/resume and the tournament-end handoff share one
# source of truth. A spec: {kind, name, parent, seed, gen, progress,
# result, pid, launched}. Wild display names come from Python
# (evo_breeder.wild_name, deterministic from seed); the arena passes
# name "" + --gen and reads the christened name back from the result.
var evo_status_line: Label
var evo_status_tick := 0.0
const EVO_STATUS_EVERY := 5.0


func _build_evo_status() -> void:
	# Small dim line centered right above the bottom menu bar. Updated
	# at most every EVO_STATUS_EVERY seconds - never fights per-battle
	# status_label writers for the same pixels.
	var hud: CanvasLayer = $HUD
	evo_status_line = Label.new()
	evo_status_line.name = "EvoStatusLine"
	evo_status_line.add_theme_font_size_override("font_size", 13)
	evo_status_line.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7, 0.9))
	evo_status_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	evo_status_line.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	evo_status_line.offset_left = -400.0
	evo_status_line.offset_right = 400.0
	evo_status_line.offset_top = -74.0
	evo_status_line.offset_bottom = -50.0
	evo_status_line.visible = false
	hud.add_child(evo_status_line)
# Centered evolution phase overlay: big title + status + progress bar
# + spinner, so long breed/train waits read as a loading phase.
var evo_panel: ColorRect
var evo_title: Label
var evo_status: Label
var evo_bar: ProgressBar
var evo_spinner: Label
var evo_spin_tick := 0.0
var evo_spin_frame := 0
const EVO_SPINNER := ["|", "/", "-", "\\", "|", "/", "-", "\\"]


func _build_evo_panel() -> void:
	var hud: CanvasLayer = $HUD
	evo_panel = ColorRect.new()
	evo_panel.name = "EvoPanel"
	evo_panel.color = Color(0.02, 0.02, 0.05, 0.72)
	evo_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	evo_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	evo_panel.visible = false
	hud.add_child(evo_panel)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	evo_panel.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	evo_spinner = Label.new()
	evo_spinner.add_theme_font_size_override("font_size", 56)
	evo_spinner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(evo_spinner)
	evo_title = Label.new()
	evo_title.add_theme_font_size_override("font_size", 30)
	evo_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(evo_title)
	evo_status = Label.new()
	evo_status.add_theme_font_size_override("font_size", 18)
	evo_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	evo_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	evo_status.custom_minimum_size = Vector2(560, 0)
	vb.add_child(evo_status)
	evo_bar = ProgressBar.new()
	evo_bar.min_value = 0.0
	evo_bar.max_value = 100.0
	evo_bar.custom_minimum_size = Vector2(420, 22)
	evo_bar.show_percentage = true
	vb.add_child(evo_bar)


func _show_evo_phase(title: String, status: String) -> void:
	if is_instance_valid(evo_title):
		evo_title.text = title
	_update_evo_phase(status, -1.0)
	if is_instance_valid(evo_panel):
		evo_panel.visible = true


func _update_evo_phase(status: String, pct: float) -> void:
	if is_instance_valid(evo_status):
		evo_status.text = status
	if is_instance_valid(evo_bar) and pct >= 0.0:
		evo_bar.value = clampf(pct, 0.0, 100.0)


func _hide_evo_phase() -> void:
	if is_instance_valid(evo_panel):
		evo_panel.visible = false


func _on_evo_async(op: String, result: Dictionary) -> void:
	# Catches breed completions for the evolution loop (only while a
	# breed is awaited; training jobs use their own signalling).
	if evo_waiting and op == "evo_breed":
		evo_wait_result = result


func _evo_poll_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text().strip_edges()
	f.close()
	if text.begins_with("{") and text.ends_with("}"):
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary:
			return parsed
	return {}


func _evo_breed(strategy: String, brain_name: String, parent_id: String,
		seed: int, progress_path: String, result_file: String,
		target_gen: int = 1) -> String:
	# LEGACY - no live callers (tournament-end handoff uses the queued
	# pipeline + _evo_await_queued instead). Kept as a retry-wrapper
	# reference. Returns the
	# new brain id, or "" on failure/abort. One automatic retry covers
	# transient worker deaths (the 86%-then-silence failure); only a
	# second failure aborts the generation loudly. Empty wild names are
	# christened Python-side from seed+gen (--gen), so pass it through.
	for attempt in [1, 2]:
		var got := await _evo_breed_attempt(strategy, brain_name, parent_id,
			seed, progress_path, result_file, attempt, target_gen)
		if got != "" or not _evo_active():
			return got
		_show_evo_phase("BREEDING " + brain_name,
			"Attempt 1 died - retrying once...")
	return ""


func _evo_breed_attempt(strategy: String, brain_name: String, parent_id: String,
		seed: int, progress_path: String, result_file: String, attempt: int,
		target_gen: int = 1) -> String:
	var director := _director()
	if director == null:
		return ""
	var log_path := result_file.get_base_dir().path_join(
		result_file.get_file().get_basename() + ".log")
	var display := brain_name if brain_name != "" else ("wild G%d" % target_gen)
	var args := ["breed", "--strategy", strategy,
		"--episodes", str(EVO_EPISODES / 2), "--seed", str(seed),
		"--episodes2", str(EVO_EPISODES / 2),
		"--noise", str(EVO_NOISE), "--progress", progress_path,
		"--gen", str(target_gen),
		"--log-file", log_path]
	var p2 := _evo_params2_file(result_file)
	if p2 != "":
		args += ["--params2-file", p2]
	if brain_name != "":
		args += ["--name", brain_name]
	if parent_id != "":
		args += ["--parent", parent_id]
	_show_evo_phase("BREEDING " + display,
		"Spawning worker (attempt %d)... ep 0/%d" % [attempt, EVO_EPISODES])
	var res: Dictionary = director.run_cli_async(
		"evo_breed", args, result_file)
	if not bool(res.get("ok", false)):
		_show_evo_phase("BREEDING " + display,
			"Breed failed to start: %s" % str(res.get("error", "?")))
		return ""
	# Lost in the _evo_await_result extraction: the await loop's liveness
	# gate and kill path both key off evo_breed_pid. Without this the
	# worker is unkillable and silent deaths hang to the full timeout.
	evo_breed_pid = int(res.get("pid", 0))
	return await _evo_await_result(display, progress_path, result_file, seed)


func _evo_await_result(display: String, progress_path: String,
		result_file: String, expect_seed: int = -1) -> String:
	# Poll loop shared by fresh spawns and adopted pipelined specs:
	# waits for the verdict, with liveness gate + timeout + cleanup.
	# evo_breed_pid must hold the worker pid (spawn sets it; adopters
	# copy it from the spec first). expect_seed >= 0 rejects stale
	# verdicts from previous runs at the same deterministic path.
	# Returns the bred brain id or "".
	evo_waiting = true
	evo_wait_result = {}
	var waited := 0.0
	while evo_waiting and waited < EVO_AWAIT_TIMEOUT:
		await get_tree().create_timer(2.0).timeout
		waited += 2.0
		if not _evo_active():
			_evo_kill_job()
			evo_waiting = false
			_hide_evo_phase()
			return ""
		# Liveness gate: a worker that died silently (no result file,
		# no exception verdict) must fail fast with its last episode,
		# not hang to the 20-minute timeout.
		if evo_breed_pid > 0 and not OS.is_process_running(evo_breed_pid):
			var last := _evo_poll_file(progress_path)
			_show_evo_phase("BREEDING " + display,
				"Worker died at ep %d/%d - failing fast." % [
				int(last.get("episode", 0)), EVO_EPISODES])
			evo_waiting = false
			break
		var prog := _evo_poll_file(progress_path)
		if not prog.is_empty():
			var pct := 100.0 * float(prog.get("episode", 0)) / maxf(float(prog.get("total", EVO_EPISODES)), 1.0)
			_show_evo_phase("BREEDING " + display,
				"Training ep %d/%d ..." % [int(prog.get("episode", 0)), EVO_EPISODES])
			_update_evo_phase("Training ep %d/%d ..." % [int(prog.get("episode", 0)), EVO_EPISODES], pct)
		# Verdicts are accepted from our own result file only. The shared
		# async signal can carry another pipelined job's verdict while we
		# wait, so a signal value with no corroborating file of our own is
		# discarded instead of misattributed to this breed.
		var fres := _evo_read_result(result_file)
		if not fres.is_empty():
			if expect_seed >= 0 and bool(fres.get("ok", false)) \
					and _evo_verdict_seed(fres) != expect_seed:
				print("[Arena] EVO stale verdict ignored while awaiting %s." % display)
				DirAccess.remove_absolute(result_file)
			else:
				evo_wait_result = fres
				evo_waiting = false
		elif not evo_wait_result.is_empty():
			evo_wait_result = {}
	# Grace check: a verdict that landed on the very tick the budget
	# expired must not turn a success into a timeout abort (this exact
	# miss orphaned a healthy clone verdict on disk in gen 1).
	if evo_wait_result.is_empty():
		var late := _evo_read_result(result_file)
		if not late.is_empty() and (expect_seed < 0 \
				or not bool(late.get("ok", false)) \
				or _evo_verdict_seed(late) == expect_seed):
			evo_wait_result = late
	if evo_wait_result.is_empty():
		# Timed out with no verdict: the worker may STILL be training
		# legitimately (buffered log hides progress) - kill it here so
		# it stops burning CPU, free the shared async slot now
		# instead of leaving _poll_async's 30-minute timeout to hold
		# every other vault op hostage. Waiting flag clears too, or
		# every later gate misreads this dead wait as live.
		_evo_kill_job()
		evo_waiting = false
		_hide_evo_phase()
		var tdir := _director()
		if tdir != null:
			tdir.pending_async = {}
		return ""
	var out: Dictionary = (evo_wait_result as Dictionary).duplicate()
	evo_wait_result = {}
	evo_breed_pid = 0
	if not bool(out.get("ok", false)):
		return ""
	var bred_brain := out.get("brain", {}) as Dictionary
	var bred := str(bred_brain.get("id", ""))
	evo_last_bred_name = str(bred_brain.get("name", ""))
	# Job litter cleanup: per-generation progress/result files served
	# their purpose once the id is banked (failures + logs stay).
	if bred != "":
		DirAccess.remove_absolute(progress_path)
		DirAccess.remove_absolute(result_file)
	return bred


func _evo_kill_job() -> void:
	if evo_breed_pid > 0:
		OS.kill(evo_breed_pid)
	evo_breed_pid = 0


func _evo_spec_paths(kind: String, target_gen: int) -> Array:
	var director := _director()
	var jd: String = director.job_dir if director != null else "."
	var base := "evo_g%d_%s" % [target_gen, kind]
	return [jd.path_join(base + ".json"), jd.path_join(base + "_result.json")]


func _evo_pending() -> Array:
	var director := _director()
	if director == null:
		return []
	return director.tourney.get("evo", {}).get("pending", [])


func _evo_spec_alive(spec: Dictionary) -> bool:
	# True while a launched, unadopted spec is still working. The pid
	# check covers the normal case; a launched spec with no verdict and
	# no live pid proof still counts as running, so a silently cleared
	# slot (30-min poll timeout, stale-verdict delete) can never
	# double-launch the pipeline into parallel breeds.
	if not bool(spec.get("launched", false)):
		return false
	var pid := int(spec.get("pid", 0))
	if pid > 0 and OS.is_process_running(pid):
		return true
	if pid > 0:
		return false
	return _evo_read_result(str(spec.get("result", ""))).is_empty()


func _evo_blocking_spec(except_kind: String) -> Dictionary:
	# The sibling breed still in flight ({} when the lane is clear).
	# Launch gates use this - not just the shared-slot flag - so the
	# clone stays QUEUED behind a running wild instead of training
	# alongside it at 0%.
	for spec in _evo_pending():
		var s := spec as Dictionary
		if str(s.get("kind", "")) == except_kind:
			continue
		if _evo_spec_alive(s):
			return s
	return {}


func _evo_done() -> Dictionary:
	var director := _director()
	if director == null:
		return {}
	return director.tourney.get("evo", {}).get("done", {})


func _evo_done_id(kind: String) -> String:
	# done values are {id, name} dicts; pre-name-change saves banked
	# bare id strings, which quit/resume can still load - tolerate both.
	var entry = _evo_done().get(kind, "")
	if entry is Dictionary:
		return str((entry as Dictionary).get("id", ""))
	return str(entry)


func _evo_done_name(kind: String) -> String:
	# Display name for a banked offspring, falling back to the kind
	# when the entry predates name banking or the verdict had none.
	var entry = _evo_done().get(kind, "")
	if entry is Dictionary:
		var nm := str((entry as Dictionary).get("name", ""))
		if nm != "":
			return nm
	return kind


func _evo_save_queue(pending: Array, done: Dictionary) -> void:
	var director := _director()
	if director == null:
		return
	var evo: Dictionary = director.tourney.get("evo", {})
	evo["pending"] = pending
	evo["done"] = done
	director.save_state()


func _evo_has_kind(kind: String) -> bool:
	# True once a kind is queued OR completed (prevents double-spawns
	# across hooks, watcher ticks, and the tournament-end fallback).
	for spec in _evo_pending():
		if str((spec as Dictionary).get("kind", "")) == kind:
			return true
	return _evo_done().has(kind)


func _evo_queue_spec(kind: String, brain_name: String, parent_id: String,
		seed: int, target_gen: int) -> void:
	var pending := _evo_pending()
	for spec in pending:
		if str((spec as Dictionary).get("kind", "")) == kind:
			return
	var paths := _evo_spec_paths(kind, target_gen)
	pending.append({"kind": kind, "name": brain_name, "parent": parent_id,
		"seed": seed, "gen": target_gen, "progress": paths[0],
		"result": paths[1], "pid": 0, "launched": false})
	_evo_save_queue(pending, _evo_done())


func _evo_queue_wild(target_gen: int) -> void:
	# Random needs nothing but a generation: name "" lets Python
	# christen it deterministically (wild_name from seed).
	if _evo_has_kind("wild"):
		return
	_evo_queue_spec("wild", "", "", randi(), target_gen)


func _evo_queue_clone(target_gen: int, champ_id: String, champ_name: String) -> void:
	if champ_id == "" or _evo_has_kind("clone"):
		return
	var director := _director()
	var kin := champ_name
	if director != null:
		kin = director.kin_name(champ_name, target_gen)
	_evo_queue_spec("clone", kin, champ_id, randi(), target_gen)


func _evo_spawn_spec(spec: Dictionary) -> bool:
	# Fire-and-forget spawn for one queued spec. Completion is adopted
	# by the watcher or the tournament-end handoff - never awaited here.
	var director := _director()
	if director == null:
		return false
	var kind := str(spec.get("kind", ""))
	var rf := str(spec.get("result", ""))
	var log_path := rf.get_base_dir().path_join(
		rf.get_file().get_basename() + ".log")
	var args := ["breed", "--strategy",
		"clone" if kind == "clone" else "random",
		"--episodes", str(EVO_EPISODES / 2), "--seed", str(int(spec.get("seed", 0))),
		"--episodes2", str(EVO_EPISODES / 2),
		"--noise", str(EVO_NOISE), "--progress", str(spec.get("progress", "")),
		"--gen", str(int(spec.get("gen", 1))),
		"--log-file", log_path]
	var p2 := _evo_params2_file(rf)
	if p2 != "":
		args += ["--params2-file", p2]
	# Kin trait mutation rides the tournament's evo settings (menu
	# toggle at START EVOLUTION, preserved across generations).
	var evod: Dictionary = director.tourney.get("evo", {})
	args += ["--mutate-traits", str(int(evod.get("mutate_traits", 1)))]
	# Never emit an empty argv element: Godot drops it on Windows, so
	# `--name ""` arrives as a bare `--name` and argparse aborts the
	# worker (this killed every wild breed). Empty = wild auto-christen.
	var sname := str(spec.get("name", ""))
	if sname != "":
		args += ["--name", sname]
	if str(spec.get("parent", "")) != "":
		args += ["--parent", str(spec.get("parent", ""))]
	DirAccess.remove_absolute(str(spec.get("progress", "")))
	var res: Dictionary = director.run_cli_async(
		"evo_breed", args, str(spec.get("result", "")))
	if not bool(res.get("ok", false)):
		evo_last_spawn_error = str(res.get("error", "?"))
		print("[Arena] EVO spawn failed for ", kind, ": ", evo_last_spawn_error)
		return false
	evo_last_spawn_error = ""
	spec["pid"] = int(res.get("pid", 0))
	spec["launched"] = true
	_evo_save_queue(_evo_pending(), _evo_done())
	return true


func _evo_read_result(path: String) -> Dictionary:
	# Complete-verdict read with the brace guard (partial writes retry
	# next tick). Returns {} when nothing conclusive is on disk.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text().strip_edges()
	f.close()
	if not (text.begins_with("{") and text.ends_with("}")):
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _evo_verdict_seed(verdict: Dictionary) -> int:
	# Seed stamped in the bred brain's generator_params, or -1 when the
	# verdict carries none. Breed paths are deterministic per
	# gen+kind, so a seed mismatch means STALE (previous run's verdict
	# at the same path) - never adopt it.
	var brain := verdict.get("brain", {}) as Dictionary
	var gp := brain.get("generator_params", {}) as Dictionary
	if not gp.has("seed"):
		return -1
	return int(gp.get("seed", -1))


func _evo_adopt_finished() -> Dictionary:
	# Sweeps queued specs for completed result files: banks {kind: id},
	# drops failed specs (re-bred at tournament end), cleans litter.
	# Returns ids adopted this sweep.
	var got := {}
	var pending := _evo_pending()
	var done := _evo_done()
	var director := _director()
	var keep: Array = []
	for spec in pending:
		var sd := spec as Dictionary
		var rf := str(sd.get("result", ""))
		var verdict := _evo_read_result(rf)
		if verdict.is_empty():
			# Liveness gate (background path had none): a worker that
			# died before writing a verdict must not hold the shared
			# slot hostage - that wedged generation-end spawns with
			# "another operation is already running" forever.
			if bool(sd.get("launched", false)):
				var pid := int(sd.get("pid", 0))
				if pid > 0 and not OS.is_process_running(pid):
					var last := _evo_poll_file(str(sd.get("progress", "")))
					var log_path := rf.get_base_dir().path_join(
						rf.get_file().get_basename() + ".log")
					print("[Arena] EVO background worker died at ep %d/%d (%s) - dropping; see %s" % [
						int(last.get("episode", 0)), EVO_EPISODES,
						str(sd.get("kind", "?")), log_path])
					if director != null and str(director.pending_async.get("result_file", "")) == rf:
						director.pending_async = {}
					continue
			keep.append(spec)
			continue
		if bool(verdict.get("ok", false)):
			var vbrain := verdict.get("brain", {}) as Dictionary
			var bid := str(vbrain.get("id", ""))
			if bid != "":
				# Stale-verdict guard: same path as a previous run's
				# breed (paths are deterministic per gen+kind). Adopting
				# it would bank the wrong brain; delete and keep waiting
				# for our own worker instead.
				if _evo_verdict_seed(verdict) != int(sd.get("seed", -1)):
					print("[Arena] EVO stale verdict for %s (seed %d, want %d) - deleting." % [
						str(sd.get("kind", "?")), _evo_verdict_seed(verdict),
						int(sd.get("seed", -1))])
					DirAccess.remove_absolute(rf)
					keep.append(spec)
					continue
				var bname := str(vbrain.get("name", ""))
				done[str((spec as Dictionary).get("kind", ""))] = {"id": bid, "name": bname}
				got[str((spec as Dictionary).get("kind", ""))] = bid
				DirAccess.remove_absolute(str((spec as Dictionary).get("progress", "")))
				DirAccess.remove_absolute(rf)
			else:
				keep.append(spec)
		else:
			print("[Arena] EVO breed failed in background: ",
				str(verdict.get("error", "?")))
			# Dropped: the tournament-end fallback re-breeds it fresh.
	_evo_save_queue(keep, done)
	return got


func _run_evo_generation() -> void:
	# Tournament-end handoff for the evolution loop. Adopts any breeds
	# that finished in the background (wild from tourney start, clone
	# from consolation start), awaits stragglers via the shared slot,
	# then rebuilds the bracket at constant roster size. STOP (menu
	# bar) or quit aborts between polls; failures disable evo loudly.
	var director := _director()
	if director == null:
		return
	# Record the finished bracket first: archiving below mutates the
	# tourney, and the rebuild replaces it entirely.
	await _save_bracket_record(true)
	var evo: Dictionary = director.tourney.get("evo", {})
	var gen := int(evo.get("generation", 1))
	var champ_id := str(director.tourney.get("champion_id", ""))
	var champ_name: String = director.champion_name()
	_show_callout("EVO GEN %d CHAMPION: %s" % [gen, champ_name],
		Color(1.0, 0.85, 0.3), "BREEDING NEXT GENERATION", "", false)
	_show_evo_phase("EVO GENERATION %d" % [gen + 1],
		"Champion %s - ranking bottom two..." % champ_name)
	if is_instance_valid(status_label):
		status_label.text = "EVO gen %d champion %s - ranking bottom two..." % [gen, champ_name]
	# --- Archive bottom two ---
	var bottom: Dictionary = director.evo_bottom_two()
	var last_id := str((bottom.get("last", {}) as Dictionary).get("id", ""))
	var second_id := str((bottom.get("second", {}) as Dictionary).get("id", ""))
	var via := str((bottom.get("last", {}) as Dictionary).get("via", "ranking"))
	if via == "ranking" and is_instance_valid(status_label):
		status_label.text = "EVO gen %d: no consolation ran - bottom two by ranking fallback." % gen
	if last_id == "":
		_evo_abort("no loser found - bracket empty?")
		return
	for pair in [[last_id, "biggest loser"], [second_id, "second-last"]]:
		if str(pair[0]) == "":
			continue
		var ares: Dictionary = director.evo_archive(
			str(pair[0]), "evo gen %d %s (%s)" % [gen, str(pair[1]), via])
		if not bool(ares.get("ok", false)):
			_evo_abort("archive failed: %s" % str(ares.get("error", "?")))
			return
		print("[Arena] EVO gen %d: archived %s %s" % [gen, str(pair[1]), str(pair[0])])
	# --- Adopt background breeds + await stragglers ---
	var target_gen := gen + 1
	_evo_adopt_finished()
	var id1 := _evo_done_id("clone")
	var id2 := _evo_done_id("wild")
	# Queue missing specs (watcher will launch them when the slot is free)
	if id1 == "" and not _evo_has_kind("clone"):
		_evo_queue_clone(target_gen, champ_id, champ_name)
	if id2 == "" and not _evo_has_kind("wild"):
		_evo_queue_wild(target_gen)
	# Tournament is over: show whatever is left in training before
	# blocking on stragglers (names for the done, ep counts for the
	# live, queued for the rest).
	_show_evo_phase("EVO GENERATION %d" % target_gen,
		_evo_offspring_summary(target_gen))
	if is_instance_valid(status_label):
		status_label.text = "EVO gen %d over - breeding gen %d..." % [gen, target_gen]
	# Await any still-pending specs one by one via the shared slot.
	# done is re-read between awaits: the watcher may bank the wild
	# breed while the clone await is in flight.
	if id1 == "" and _evo_has_kind("clone"):
		id1 = await _evo_await_queued("clone")
		if id1 == "":
			# Last-chance rescue: a verdict adopted by a concurrent
			# sweep between the await's last tick and this line.
			_evo_adopt_finished()
			id1 = _evo_done_id("clone")
		if id1 == "" and _evo_active():
			_evo_abort("clone breeding failed - %s" % _evo_spawn_why())
			return
	if id2 == "":
		id2 = _evo_done_id("wild")
	if id2 == "" and _evo_has_kind("wild"):
		id2 = await _evo_await_queued("wild")
		if id2 == "":
			_evo_adopt_finished()
			id2 = _evo_done_id("wild")
		if id2 == "" and _evo_active():
			_evo_abort("random breeding failed - %s" % _evo_spawn_why())
			return
	# --- Rebuild bracket at constant roster size ---
	var size := int(director.tourney.get("size", 8))
	var gone := [last_id, second_id]
	var present: Array = director.evo_vault_ids()
	var roster: Array = []
	for p in director.tourney.get("players", []):
		var pid := str((p as Dictionary).get("id", ""))
		if pid != "" and not (pid in gone) and pid in present:
			roster.append(pid)
	roster.append(id1)
	roster.append(id2)
	while roster.size() > size:
		var extra := ""
		for pid in director.evo_ranking():
			if str(pid) in roster and str(pid) != champ_id:
				extra = str(pid)
				break
		if extra == "":
			break
		var trim: Dictionary = director.evo_archive(extra, "evo roster trim gen %d" % (gen + 1))
		roster.erase(extra)
		if not bool(trim.get("ok", false)):
			print("[Arena] EVO trim skipped missing %s, continuing." % extra)
	var res: Dictionary = director.build_bracket(
		roster, size, int(director.tourney.get("best_of", 7)),
		float(director.tourney.get("lr_scale", 0.5)),
		float(director.tourney.get("round_time", 40.0)),
		false, [], bool(director.tourney.get("random_draw", false)), true)
	if not bool(res.get("ok", false)):
		_evo_abort("next bracket failed: %s" % str(res.get("error", "?")))
		return
	director.tourney["evo"] = {"active": true, "generation": gen + 1,
		"episodes": EVO_EPISODES,
		"mutate_traits": int((director.tourney.get("evo", {}) as Dictionary).get("mutate_traits", 1))}
	director.save_state()
	# Pipeline: kick off the next generation's wild breed immediately
	_evo_queue_wild(gen + 2)
	_show_evo_phase("EVO GENERATION %d" % [gen + 1],
		"Roster ready (%d fighters) - loading first battle..." % roster.size())
	if is_instance_valid(status_label):
		status_label.text = "EVO gen %d ready (%d fighters)." % [gen + 1, roster.size()]
	await get_tree().create_timer(2.0).timeout
	_hide_evo_phase()
	_request_current_battle_load()


func _evo_offspring_summary(target_gen: int) -> String:
	# One line per offspring for the tournament-end phase panel: done
	# brains by christened name, live ones with ep progress, the rest
	# as queued. Shows "whatever is left in training" at a glance.
	var lines: Array = []
	for kind in ["clone", "wild"]:
		if _evo_done().has(kind):
			lines.append("%s - done" % _evo_done_name(kind))
			continue
		var found := false
		for spec in _evo_pending():
			var s := spec as Dictionary
			if str(s.get("kind", "")) != kind:
				continue
			found = true
			var label := str(s.get("name", ""))
			if label == "":
				label = "wild G%d" % int(s.get("gen", target_gen))
			if bool(s.get("launched", false)):
				var prog := _evo_poll_file(str(s.get("progress", "")))
				if prog.is_empty():
					lines.append("%s - warming up" % label)
				else:
					lines.append("%s - training ep %d/%d" % [label,
						int(prog.get("episode", 0)), EVO_EPISODES])
			else:
				lines.append("%s - queued" % label)
		if not found:
			lines.append("%s - queued" % kind)
	return "\n".join(lines)


func _evo_spawn_why() -> String:
	# Human-readable cause for the last spawn failure, defaulting to
	# the log pointer when the breed died mid-flight instead.
	if evo_last_spawn_error != "":
		return evo_last_spawn_error
	return "check brains/jobs log"


func _evo_await_queued(kind: String) -> String:
	# Waits for a queued spec of the given kind to finish. The spec is
	# DETACHED from the pending list first, so the watcher can neither
	# adopt its result file out from under the await nor double-launch
	# it; the bred id is banked into done here instead. Returns id or "".
	if _evo_done().has(kind):
		return _evo_done_id(kind)
	var pending := _evo_pending()
	for i in range(pending.size()):
		var s := pending[i] as Dictionary
		if str(s.get("kind", "")) != kind:
			continue
		pending.remove_at(i)
		_evo_save_queue(pending, _evo_done())
		var sname0 := str(s.get("name", ""))
		var display0 := sname0 if sname0 != "" else ("wild G%d" % int(s.get("gen", 1)))
		if not bool(s.get("launched", false)):
			# The lane may still be held by the sibling breed (e.g. wild
			# head-start unfinished at tournament end): it trains on
			# while this one shows QUEUED. Spawning into a busy slot
			# fails instantly ("another operation is already running"),
			# so wait for it instead, sweeping adoptions meanwhile.
			# STOP aborts the wait.
			var tdir := _director()
			var swait := 0.0
			while tdir != null and (not tdir.pending_async.is_empty() \
					or not _evo_blocking_spec(kind).is_empty()) \
					and swait < EVO_AWAIT_TIMEOUT:
				if not _evo_active():
					return ""
				var blk := _evo_blocking_spec(kind)
				if blk.is_empty():
					_show_evo_phase("BREEDING " + display0,
						"Waiting for the training slot (%s in progress)..." % str(tdir.pending_async.get("op", "?")))
				else:
					var blabel := str(blk.get("name", ""))
					if blabel == "":
						blabel = "wild G%d" % int(blk.get("gen", 1))
					var bprog := _evo_poll_file(str(blk.get("progress", "")))
					var bep := "warming up"
					if not bprog.is_empty():
						bep = "ep %d/%d" % [int(bprog.get("episode", 0)), EVO_EPISODES]
					_show_evo_phase("BREEDING " + display0,
						"Queued behind %s (%s)..." % [blabel, bep])
				await get_tree().create_timer(2.0).timeout
				swait += 2.0
				_evo_adopt_finished()
				tdir = _director()
			if tdir == null:
				return ""
			if not tdir.pending_async.is_empty():
				_show_evo_phase("BREEDING " + display0,
					"Training slot never freed - check brains/jobs log")
				return ""
			if not _evo_spawn_spec(s):
				_show_evo_phase("BREEDING " + display0,
					"Breed failed to start: %s" % evo_last_spawn_error)
				return ""
		# Fresh spawns and watcher-launched jobs alike: the await loop's
		# liveness gate and kill path key off evo_breed_pid.
		evo_breed_pid = int(s.get("pid", 0))
		var sname := str(s.get("name", ""))
		var display := sname if sname != "" else ("wild G%d" % int(s.get("gen", 1)))
		var bred := await _evo_await_result(display,
			str(s.get("progress", "")), str(s.get("result", "")),
			int(s.get("seed", -1)))
		if bred != "":
			var done := _evo_done()
			done[kind] = {"id": bred, "name": evo_last_bred_name}
			_evo_save_queue(_evo_pending(), done)
		return bred
	return ""


func _evo_abort(reason: String) -> void:
	var director := _director()
	if director != null:
		director.tourney["evo"] = {"active": false}
		director.save_state()
	_hide_evo_phase()
	if is_instance_valid(status_label):
		status_label.text = "EVOLUTION STOPPED: %s" % reason
	print("[Arena] EVOLUTION STOPPED: %s" % reason)


func _on_evo_stop() -> void:
	if not _evo_active() and not evo_waiting:
		if is_instance_valid(status_label):
			status_label.text = "Evolution loop is not running."
		return
	_evo_kill_job()
	evo_waiting = false
	# Kill watcher-launched pipelined workers too: they hold no global
	# pid, so _evo_kill_job can't reach them. Otherwise they keep
	# burning GPU and land stray verdicts after the loop is gone.
	for spec in _evo_pending():
		var pid := int((spec as Dictionary).get("pid", 0))
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	# Free the shared async slot: the killed breed job will never write
	# its result file, and _poll_async only times that out after 30 min
	# (blocking every other vault op meanwhile).
	var director := _director()
	if director != null:
		director.pending_async = {}
	# Clear pipeline queue so the watcher stops trying to spawn/adopt.
	_evo_save_queue([], {})
	_evo_abort("stopped by user")


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
	if tournament_active:
		# Wrong-mode reply mid-tournament (server lost tournament state:
		# restart, or a stray free_mode): NEVER self-advance here. The old
		# code reset + refought the same battle id, multi-banking one
		# fight into many generations. Hold the battle watchdog instead;
		# if the real verdict never comes it fails loud (QUIT TO MENU +
		# RESUME re-sends tournament_load, which heals the server).
		print("[Arena] Ignoring generation_advanced during tournament ",
			"(server desync, would-be gen ", new_gen, ")")
		if is_instance_valid(status_label):
			status_label.text = "SERVER DESYNC - QUIT TO MENU + RESUME TO RELOAD BRAINS"
		return
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
