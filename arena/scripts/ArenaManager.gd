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
# DNF wander rule: the white outer arena ring sits 30 m from center
# (glade_ground.gdshader). A timeout-tie measures each fly's meters
# past that ring; farthest out reads confused/evading. Overtime
# battles dock 4 HP per drift meter (cap 50, zero drift docks zero),
# so wandering converts into a decisive disadvantage and a third DNF
# gets rare: unequal health breaks the next tie on damage.
const ARENA_RING_R := 30.0
const DOCK_PER_M := 4.0
const DOCK_CAP := 50.0
# Chase exemption: flies within this many meters of each other are
# still fighting, wherever they are - both chasing out past the ring
# is valid engagement, not wandering. Only a fly that is BOTH past
# the ring AND separated from its rival reads drift.
const CHASE_TOGETHER_M := 8.0


func _wander_overshoot(fly) -> float:
	# Meters past the arena ring, floor zero (inside/A-ring reads 0).
	if not is_instance_valid(fly):
		return 0.0
	var flat := Vector2((fly as Node3D).global_position.x,
		(fly as Node3D).global_position.z)
	return maxf(flat.length() - ARENA_RING_R, 0.0)


func _wander_dock(drift: float) -> float:
	# Overtime starting-health dock for a drift reading. Pure
	# (unit-tested): 0 -> 0, 2.5 -> 10, 10 -> 40, >=12.5 -> 50.
	return clampf(float(drift) * DOCK_PER_M, 0.0, DOCK_CAP)


func _flat_separation() -> float:
	# XZ meters between the flies; -1 when either is missing (unknown
	# reads disengaged - never exempt on missing data).
	if not is_instance_valid(fly_alpha) or not is_instance_valid(fly_beta):
		return -1.0
	var pa := (fly_alpha as Node3D).global_position
	var pb := (fly_beta as Node3D).global_position
	return Vector2(pa.x - pb.x, pa.z - pb.z).length()


func _gate_drift(drift_a: float, drift_b: float, sep_m: float) -> Array:
	# Chase exemption, pure (unit-tested): engaged flies (within
	# CHASE_TOGETHER_M) read zero drift even outside the ring; unknown
	# or wide separation keeps each fly's own overshoot.
	if sep_m >= 0.0 and sep_m <= CHASE_TOGETHER_M:
		return [0.0, 0.0]
	return [float(drift_a), float(drift_b)]

var stats_alpha := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0, "scrape_time_s": 0.0 }
var stats_beta  := { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0, "scrape_time_s": 0.0 }

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
# Lockstep proof (HUD n/srv): control pairs applied vs server steps
# integrated. Session-cumulative to match the server's cumulative
# step_count - do NOT reset per round (see _on_motor_controls).
var _ctrl_n: int = 0
var _ctrl_srv_seq: int = 0

# Control-link pacing (stop-and-wait): at most one step reply may be
# outstanding. TUNING:
# - STEP_TIMEOUT_MSEC (below): how long to wait for a reply before
#   assuming it lost and sending fresh state. Raise it if the HUD's
#   srv-n gap grows on huge brains (server step cost is printed in
#   server_log.txt every 50 steps: "step ~Nms"); lower it (min ~500)
#   if flies go limp too long on a genuinely dead link. Rule of
#   thumb: 7-10x the worst observed single-step ms.
# - BRAIN_TICK_DT (below) stays the *request ceiling* (20 Hz):
#   pacing can only slow sends below it, never above.
const STEP_TIMEOUT_MSEC := 2000
var _step_in_flight := false
var _step_deadline_msec := 0
var _step_timeouts := 0 # consecutive expiries; >=5 shows link-slow text

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
# Pool-rate stream (flights telemetry): one count array per motor
# reply (~5 Hz), capped; banked into the tournament JSON `flights`
# entry when the menu record toggle is on. ~50 KB per 40 s battle -
# toggle-gated. (The post-battle scrubber viewer was removed: the
# REPLAY button never worked and was never used.)
const BV_STREAM_MAX := 600
var bv_stream_alpha: Array = []
var bv_stream_beta: Array = []

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


# Dynamic tree fade: trees sitting on the camera->fly line go translucent so
# the fight stays visible; everything else stays solid. Rebuilt per frame.
const TREE_FADE_ALPHA: float = 0.30
const TREE_FADE_SMOOTH: float = 10.0
var tree_sight_entries: Array = []

# Round-end winner overlay: big name + next-round countdown (procedural)
var winner_overlay: Control
var winner_label: Label
var countdown_label: Label
# Callout typography: 64pt across an 1100px floor keeps
# "NAME TAKES BATTLE (2 - 0)" to two clean lines (name + result)
# instead of wrapping mid-phrase at 88pt.
const CALLOUT_TITLE_FS := 64
# Slow-motion finish: after the final blow the fight plays at quarter
# speed for a beat (the landing unfolds dramatically), timescale
# restores, a 1 s beat passes, and only then the winner text lands.
const SLOWMO_SCALE := 0.25
const SLOWMO_SECS := 2.0
const WINNER_BEAT_SECS := 1.0
var _slowmo_active := false

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
# Timeouts carry the arena-decided winner (_time_winner); ties go draw.
const TIME_TIE_EPS := 0.5
var _end_reason := ""
var _ko_victim := ""
var _time_winner := ""
var _last_verdict := {}


func _timeout_winner(ha: float, hb: float) -> String:
	# Timeout decided by remaining health — most health wins, every
	# dent counts (tree rams and ground scrapes are bad flying too).
	# Within half a point is a tie for the DNF/overtime ladder. Pure
	# (unit-tested); the arena decides, the server only records.
	if absf(ha - hb) < TIME_TIE_EPS:
		return "draw"
	return "alpha" if ha > hb else "beta"
var tourney_awaiting_load: bool = false
# Preload bookkeeping (NEXT match into the server's prepare slot):
# separate from _seq_last_load so the watchdog never retries a prepare
# as the official load. A prepared reply only marks readiness; the
# official load (activation hit or disk fallback) stays the starter.
var _preload_params: Dictionary = {}
var _preload_ready := false
# Batched match reporting: every battle's sync payload caches here and
# the WHOLE match banks once at match over (one message, one journal,
# one save pair server-side). Between battles only the ms match_reset
# runs, so battles flow back-to-back on identical weights.
var _match_battle_cache: Array = []
var _last_match_winner := ""
var _last_match_score := ""
# Round-batch reporting: completed matches append here; ONE round_report
# banks the whole round at the round boundary (round nonce, one journal,
# one save set server-side). Between matches only the ms match_reset
# runs, so best-of series flow back-to-back on identical pre-round
# weights. Battles AND matches fight on the same weights all round.
var _round_match_cache: Array = []
var _round_bank_pending := false
var _tourney_awaiting_roundbank := false
var _seq_round_id := ""
var _seq_last_round_report: Dictionary = {}
var _seq_forgive_roundbank: Dictionary = {}
var _pending_roundbank_resend := false
# Group-bank twins (group files only): the rounds journal fast; the
# group seal saves once. Same nonce/verdict contract, separate state
# so round acks never consume group waits.
var _group_bank_pending := false
var _tourney_awaiting_groupbank := false
var _seq_group_id := ""
var _seq_last_group_report: Dictionary = {}
var _seq_forgive_groupbank: Dictionary = {}
var _pending_groupbank_resend := false
var _pending_final_group: Dictionary = {}
var _load_gated_on_bank := false
var _pending_advance: Dictionary = {}
var _pending_final_ev: Dictionary = {}
# Last-step sensorimotor context (the dopamine replay's inputs): the
# sens refs land at send time, the ctrl refs at motor-reply time -
# exactly what the server used to capture per battle.
var _last_sens_a: Dictionary = {}
var _last_sens_b: Dictionary = {}
var _last_ctrl_a: Dictionary = {}
var _last_ctrl_b: Dictionary = {}
var bracket_overlay: Control
var arena_bracket: BracketView
var bracket_scroll: ScrollContainer
var bracket_title: Label
var wait_title: Label
var wait_sub: Label
var _wait_bracket := false
# Next-generation waiting room (evo handoff only): preview bracket +
# rotating fighter gallery + training strip, sharing the overlay above.
var gallery_box: VBoxContainer
var gallery_title: Label
var gallery_star: Label
var gallery_elo: Label
var gallery_rows: Label
var strip_box: HBoxContainer
var strip_clone_label: Label
var strip_clone_bar: ProgressBar
var strip_wild_label: Label
var strip_wild_bar: ProgressBar
var nextgen_visible := false
var nextgen_preview := {}
var nextgen_gallery: Array = []
var nextgen_gallery_idx := 0
var nextgen_gallery_tick := 0.0
var nextgen_strip_tick := 0.0
var nextgen_brains := {}
var nextgen_survivors: Array = []
var nextgen_gone: Array = []
var nextgen_size := 8
var nextgen_gen := 1
var nextgen_champ_id := ""
var nextgen_champ_name := ""
var nextgen_clone_name := ""

# Group-stage event widgets (evo size-16): standings table + the
# intermission countdown row, sharing the bracket overlay above.
var standings_label: Label
var intermission_row: HBoxContainer
var intermission_label: Label
var _event_skip := false
const EVENT_INTERMISSION_SECS := 60.0
const EVENT_PREVIEW_SECS := 30.0
const EVENT_FINAL_SECS := 120.0
# Event gallery (bracket-view right column): rotates fighter stat
# cards for the next pending group (all fighters pre-event). Keyed
# cache so records refetch only when the target changes.
var _event_gallery_active := false
var _event_gallery_key := ""
var _event_gallery_moved := false
var bracket_row: HBoxContainer
const EVENT_MIN_MATCHES := 10
const EVENT_POOL_TARGET := 2
const POOL_TRAIN_TARGET := 50
const EVENT_TOPUP_EVERY := 30.0
var _event_topup_cd := 0.0
const EVENT_POOL_CAP := 4
# In-flight awaited breed: _evo_await_queued DETACHES its spec from
# pending, so every progress readout (strip, gallery, status line)
# must consult this fallback or flatline for the whole (long) await.
var evo_await_spec := {}


func _evo_awaited_spec(kind: String) -> Dictionary:
	if str(evo_await_spec.get("kind", "")) == kind:
		return evo_await_spec
	return {}
const NEXTGEN_GALLERY_EVERY := 7.0
const NEXTGEN_STRIP_EVERY := 1.0
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
# Mid-match server-brain-loss recovery: the server restarts (or is
# relaunched) under a live tournament, and the next match_reset fails
# on the fresh server. Reloading the CURRENT match self-heals (the
# fresh load's _reset_round continues the match; the arena's cached
# battles still bank at match over) where the old fail-loud killed the
# tournament. Capped: a persistently broken server still lands loud.
const MAX_SERVER_RELOADS := 2
var _server_reloads := 0
# Pending match-bank resend across a recovery reload: the server lost
# state mid-bank (restart), the reload restores brains, then the STORED
# report (same nonce, idempotent) goes out again instead of starting a
# round. Set on the free-mode error, consumed in _on_brains_loaded.
# A supervisor reload is in flight: errors/state replies arriving now
# are attributed but never re-trigger (the refusal that MOTIVATED the
# recovery can land after it armed; brains_loaded consumes it).
var _recover_in_flight := false
# Forgiveness context for a banked-but-unconfirmed battle: set at
# report, cleared when its reply is applied. A post-fail-loud reply
# matching this triple is applied instead of dropped (self-heals
# SERVER SILENT when the bank actually landed); anything else stays
# dropped so a battle is never applied twice.
var _seq_forgive_match: Dictionary = {}
const SEQ_TIMEOUT_MSEC: int = 30000
# Battle reports routinely take ~60 s (dopamine + gain pinning over 25M
# synapses, then vault writes + journal fsync). A 30 s watchdog fired
# on EVERY battle and doubled server work with a retry that always
# lost the race. 240 s fails loud on real stalls while surviving
# loaded-machine battles (compressed saves shrank the work; this is
# the safety net, not the fix).
const SEQ_BATTLE_TIMEOUT_MSEC: int = 240000
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
@onready var pip_alpha_view: SubViewport = $HUD/PiPAlpha/PiPAlphaView
@onready var pip_beta_view: SubViewport = $HUD/PiPBeta/PiPBetaView
@onready var pip_alpha_box: Control = $HUD/PiPAlpha
@onready var pip_beta_box: Control = $HUD/PiPBeta

# Laptop performance switches (menu PERFORMANCE row, user://perf.cfg):
# eye-view PiPs render throttled (every 3rd tick) or hidden outright;
# glow + sun shadows toggleable. All default true (current look).
var perf_pip := true
var perf_glow := true
var perf_shadows := true
var _pip_tick := 0
var _pip_hidden := false
# PiP-slot modes, cycled by the BRAIN button: EYES (fly-head cams),
# BRAIN (cams parked on the spinning 3D clouds), STATS (live fly stat
# cards instead of viewports), MOTORS (live motor-command debug: text
# rows + bipolar bars + scrolling command traces per fly).
const PIP_SLOT_MODES := ["EYES", "BRAIN", "STATS", "MOTORS"]
var pip_slot_mode := "STATS"
var pip_stats_alpha: Label
var pip_stats_beta: Label
var pip_flash_alpha: ColorRect
var pip_flash_beta: ColorRect
var pip_name_alpha: Label
# Motor debug (MOTORS PiP slot): last-120 command snapshots per side
# for the scrolling traces, consecutive zero-spike replies per side
# for the silence badge, spike-rate EMAs for the tick readout.
const MOTOR_TRACE_MAX := 120
const MOTOR_SILENT_REPLIES := 10
var _motor_trace_alpha: Array = []
var _motor_trace_beta: Array = []
var _motor_silent_alpha := 0
var _motor_silent_beta := 0
var _motor_spike_ema_alpha := 0.0
var _motor_spike_ema_beta := 0.0
var pip_motor_bars_alpha: Array = []
var pip_motor_bars_beta: Array = []
var pip_motor_trace_alpha: Control
var pip_motor_trace_beta: Control
var pip_motor_scope_alpha: PanelContainer
var pip_motor_scope_beta: PanelContainer
var pip_name_beta: Label
# Active flash tweens (one per wash rect / per label, previous killed
# on re-flash): the KO presentation must stop the attacker's fading
# flash DEAD, and a killed tween needs its reference.
var _pip_wash_tween := {}
var _label_flash_tween := {}

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
	fly_alpha.set_team_color(Color(1.0, 0.55, 0.30))
	fly_beta.set_team_color(Color(0.4, 0.75, 1.0))
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
	# (the _last_ctrl capture inside feeds the deferred dopamine replay)
	brain_client.generation_advanced.connect(_on_generation_advanced)
	brain_client.merged.connect(_on_merged)
	brain_client.restarted.connect(_on_restarted)
	brain_client.tournament_battle_received.connect(_on_tournament_battle)
	brain_client.server_state_received.connect(_on_server_state)
	brain_client.battle_progress_received.connect(_on_battle_progress)
	brain_client.round_banked_received.connect(_on_round_banked)
	brain_client.group_banked_received.connect(_on_group_banked)
	var _edir := _director()
	if _edir != null:
		_edir.async_done.connect(_on_evo_async)
		_edir.job_progress.connect(_on_train_progress)
		_edir.train_queue_changed.connect(_on_train_queue_changed)
	brain_client.raster_map_received.connect(_on_raster_map)
	brain_client.brains_loaded_received.connect(_on_brains_loaded)
	brain_client.prepared_received.connect(_on_prepared)
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
	_build_combat_fx()
	_build_vignette()
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
	var director := _director()
	if director != null and director.has_method("perf_get"):
		perf_pip = bool(director.call("perf_get", "pip"))
		perf_glow = bool(director.call("perf_get", "glow"))
		perf_shadows = bool(director.call("perf_get", "shadows"))
	_init_sound()
	var wenv := get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env: Environment = wenv.environment if wenv != null else null
	if env != null:
		env.glow_enabled = perf_glow
	var sun := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = perf_shadows
	if env != null and env.sky != null:
		var smat := ShaderMaterial.new()
		smat.shader = preload("res://scripts/stylized_sky.gdshader")
		env.sky.sky_material = smat
		env.sky.process_mode = Sky.PROCESS_MODE_REALTIME
		# Horizon melts into the scene fog: match it automatically.
		var fog := env.fog_light_color
		smat.set_shader_parameter("horizon_color",
			Vector3(fog.r, fog.g, fog.b))


var _dir_ref: Node = null
var _dir_lookup_done := false


func _director() -> Node:
	# Bare-instance safe (headless unit tests): absolute lookup outside
	# the tree errors in the log, so report null the quiet way.
	# Memoized: ~40 call sites, several on tick paths; the director is
	# an autoload (lives for the whole session), so one lookup suffices.
	if _dir_lookup_done:
		return _dir_ref
	if not is_inside_tree():
		return null
	_dir_ref = get_node_or_null("/root/TournamentDirector")
	_dir_lookup_done = _dir_ref != null
	return _dir_ref

func _enter_tournament_mode() -> void:
	# Close the round BEFORE the first await: the boot countdowns
	# (tip-off / resume intermission) run ahead of any load request,
	# and the scene's is_round_active=true default would fight and
	# phantom-timeout behind them from the very first physics tick.
	_close_round_for_wait()
	tournament_active = true
	var director := _director()
	director.arena = self
	_build_bracket_overlay()
	_build_menu_bar(true)
	if is_instance_valid(timer_label):
		timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if is_instance_valid(status_label):
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_pip_slot()
	# Pipeline kick-off: queue a wild breed for the next generation
	# immediately, so it trains in the background while gen 1 plays.
	# Events stock the pool bench instead (clones need the champion,
	# so only wilds pipeline mid-event). Fresh events open with a
	# 30 s tip-off: full overview plus every fighter in the gallery.
	if _evo_active():
		if _event_active():
			_event_maintain_pool()
			if _event_is_fresh():
				await _event_pre_showcase()
				if not _event_active():
					return
			elif not await _event_resume_intermission():
				var rdirector := _director()
				if rdirector != null:
					rdirector.quit_to_menu()
				return
		else:
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
		var brain_b := _menu_bar_button("BRAIN", "Cycle PiP slot: fly eyes, brain 3D, fly stats. (N cycles diagrams.)")
		brain_b.pressed.connect(_on_brain_button)
		bar.add_child(brain_b)
		mute_button = _menu_bar_button("MUTE", "Mute/unmute all battle sound. (M)")
		mute_button.pressed.connect(_on_mute_button)
		bar.add_child(mute_button)
		var evo_stop_b := _menu_bar_button("STOP CONTINUOUS", "Stop the continuous tournament loop (keeps current bracket).")
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
		var brain_b := _menu_bar_button("BRAIN", "Cycle PiP slot: fly eyes, brain 3D, fly stats. (N cycles diagrams.)")
		brain_b.pressed.connect(_on_brain_button)
		bar.add_child(brain_b)
		mute_button = _menu_bar_button("MUTE", "Mute/unmute all battle sound. (M)")
		mute_button.pressed.connect(_on_mute_button)
		bar.add_child(mute_button)


const BV_LAYERS := ["bars", "flow", "raster", "brain3d"]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_B:
			_toggle_brainview()
		elif (event as InputEventKey).keycode == KEY_N:
			_cycle_bv_layer()
		elif (event as InputEventKey).keycode == KEY_M:
			_set_muted(not _sound_muted)


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
	# Squeezed wait header (server waits only, hidden otherwise):
	# outcome/wait title in verdict color + white detail line. Plain
	# minimum-size rows above the sole EXPAND_FILL scroll row, so the
	# bracket reflows by exactly their height.
	wait_title = Label.new()
	wait_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wait_title.add_theme_font_size_override("font_size", 16)
	wait_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wait_title.visible = false
	vb.add_child(wait_title)
	wait_sub = Label.new()
	wait_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wait_sub.add_theme_font_size_override("font_size", 13)
	wait_sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	wait_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wait_sub.visible = false
	vb.add_child(wait_sub)
	# Group standings (event group brackets only, hidden otherwise).
	standings_label = Label.new()
	standings_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	standings_label.add_theme_font_size_override("font_size", 14)
	standings_label.visible = false
	vb.add_child(standings_label)
	# Intermission row (event transitions only): countdown + skip/stop.
	intermission_row = HBoxContainer.new()
	intermission_row.add_theme_constant_override("separation", 16)
	intermission_row.alignment = BoxContainer.ALIGNMENT_CENTER
	intermission_row.visible = false
	vb.add_child(intermission_row)
	intermission_label = Label.new()
	intermission_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	intermission_label.add_theme_font_size_override("font_size", 16)
	# EXPAND_FILL is load-bearing: without it the label renders at its
	# ~1px minimum inside this button row and every line wraps into
	# vertical soup (measured 73 lines for a 3-line text). With it the
	# label takes all leftover row width and the roster reads.
	intermission_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Dedicated top-margin band for the preview row: wraps (the
	# side-by-side names must fold, never run off-edge) with a fixed
	# two-row floor, so the per-second countdown rewrites never resize
	# or reflow the bracket below. Same minimum-size-rows pattern as
	# the wait header above.
	intermission_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intermission_label.custom_minimum_size = Vector2(0, 52)
	intermission_row.add_child(intermission_label)
	var skip_btn := Button.new()
	skip_btn.text = "SKIP WAIT"
	skip_btn.pressed.connect(_on_intermission_skip)
	intermission_row.add_child(skip_btn)
	var stop_btn := Button.new()
	stop_btn.text = "STOP EVENT"
	stop_btn.pressed.connect(_on_intermission_stop)
	intermission_row.add_child(stop_btn)
	# Training strip FIRST (next-gen waiting room only): progress must
	# stay visible even when a tall bracket fills the scroll area below.
	strip_box = HBoxContainer.new()
	strip_box.add_theme_constant_override("separation", 16)
	strip_box.alignment = BoxContainer.ALIGNMENT_CENTER
	strip_box.visible = false
	vb.add_child(strip_box)
	for slot in ["clone", "wild"]:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		cell.custom_minimum_size = Vector2(300, 0)
		strip_box.add_child(cell)
		var lab := Label.new()
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.add_theme_font_size_override("font_size", 14)
		cell.add_child(lab)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.custom_minimum_size = Vector2(300, 20)
		bar.show_percentage = true
		cell.add_child(bar)
		if slot == "clone":
			strip_clone_label = lab
			strip_clone_bar = bar
		else:
			strip_wild_label = lab
			strip_wild_bar = bar
	# Bracket row: gallery column (next-gen waiting room only, hidden
	# otherwise so mid-tournament views render exactly as before).
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	brow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Floor under the bracket row: header rows (title, wait, standings,
	# intermission, strip) can stack during transitions - the bracket
	# area never collapses below this, so its position and spacing hold
	# and the scroll takes the overflow internally instead.
	brow.custom_minimum_size = Vector2(0, 380)
	vb.add_child(brow)
	bracket_row = brow
	gallery_box = VBoxContainer.new()
	gallery_box.custom_minimum_size = Vector2(300, 0)
	gallery_box.add_theme_constant_override("separation", 2)
	gallery_box.visible = false
	brow.add_child(gallery_box)
	# Showcased name in the shared cyan accent (same color as the
	# bracket rows) plus the same red "*" marker the bracket rows
	# carry, so the gallery names its showcased fighter exactly the
	# way the bracket does. Title + star ride a centered row so the
	# star sits right after the name; the card keeps its dark look.
	var title_row := HBoxContainer.new()
	title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	title_row.add_theme_constant_override("separation", 6)
	gallery_box.add_child(title_row)
	gallery_title = Label.new()
	gallery_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gallery_title.add_theme_font_size_override("font_size", 20)
	gallery_title.add_theme_color_override("font_color",
		BracketView.COL_SHOWCASE)
	# Same 1px-soup disease as the intermission label: a bare label in
	# a centered row collapses and wraps long fighter names into a
	# vertical stack. Expand + wrap like its sibling.
	gallery_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gallery_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_row.add_child(gallery_title)
	gallery_star = Label.new()
	gallery_star.text = "*"
	gallery_star.add_theme_font_size_override("font_size", 20)
	gallery_star.add_theme_color_override("font_color",
		BracketView.COL_MARKER)
	gallery_star.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gallery_star.visible = false
	title_row.add_child(gallery_star)
	gallery_elo = Label.new()
	gallery_elo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gallery_elo.add_theme_font_size_override("font_size", 28)
	gallery_box.add_child(gallery_elo)
	gallery_rows = Label.new()
	gallery_rows.add_theme_font_size_override("font_size", 14)
	gallery_rows.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gallery_box.add_child(gallery_rows)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	brow.add_child(scroll)
	bracket_scroll = scroll
	arena_bracket = BracketView.new()
	arena_bracket.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arena_bracket.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(arena_bracket)
	# No overlay CLOSE row: it sat under the bottom menu bar and could
	# never receive clicks. The menu-bar "Bracket Close" button (kept
	# in sync by _sync_bracket_button) is the close control.
	# Countdown above bracket: WinnerOverlay is built first (lower
	# sibling), so raise it over the bracket - the NEXT BATTLE callout
	# then plays on top of the waiting bracket instead of under it.
	if is_instance_valid(winner_overlay):
		hud.move_child(winner_overlay, bracket_overlay.get_index() + 1)

func _show_arena_bracket(title_text: String) -> void:
	var director := _director()
	if director == null or arena_bracket == null:
		return
	# Fresh views never carry stale wait text (wait flows set it after).
	if is_instance_valid(wait_title):
		wait_title.visible = false
		wait_title.text = ""
	if is_instance_valid(wait_sub):
		wait_sub.visible = false
		wait_sub.text = ""
	bracket_title.text = title_text
	if _event_active() and str(director.tourney.get("format", "bracket")) == "groups":
		# Event view: all four groups in one 2x2 overview (the single
		# file would render as a fake single-elim). Gallery previews
		# the next pending group alongside.
		var ov: Dictionary = director.event_overview_data(_event_id())
		arena_bracket.render_event_groups(ov, str(ov.get("current", "")))
		_event_gallery_update()
	else:
		arena_bracket.render_bracket(director.tourney,
			int(director.tourney.get("current_round", 0)),
			int(director.tourney.get("current_match", 0)))
	_refresh_standings()
	# The renderer picks compact metrics for big brackets so most fit
	# outright; whatever still overflows keeps native scrolling here.
	if is_instance_valid(bracket_scroll):
		bracket_scroll.scroll_horizontal = 0
		bracket_scroll.scroll_vertical = 0
	bracket_overlay.visible = true
	_sync_bracket_button()

func _hide_arena_bracket() -> void:
	if bracket_overlay != null:
		bracket_overlay.visible = false
	_sync_bracket_button()


func _show_wait_bracket(title_text: String) -> bool:
	# Bracket + squeezed wait header for routine server waits (battle
	# load, report await, reset wait, error retry). Returns false when
	# no bracket can render (caller falls back to fullscreen loading).
	# Ownership: takes over only a closed overlay; a manually opened
	# bracket stays the user's (no auto-hide on reply). Never downgrade:
	# re-shows over a visible overlay (e.g. after the callout) keep the
	# earlier ownership so the reply still auto-hides our wait view.
	var director := _director()
	if director == null or arena_bracket == null or bracket_overlay == null:
		return false
	_wait_bracket = _wait_bracket or not bracket_overlay.visible
	_show_arena_bracket(title_text)
	return true


func _set_wait_header(head: String, sub: String, head_color: Color) -> void:
	if is_instance_valid(wait_title):
		wait_title.text = head
		wait_title.add_theme_color_override("font_color", head_color)
		wait_title.visible = true
	if is_instance_valid(wait_sub):
		wait_sub.text = sub
		wait_sub.visible = true


func _hide_wait_bracket() -> void:
	# Auto-opened wait view only; manual brackets are never yanked.
	if not _wait_bracket:
		return
	_wait_bracket = false
	if is_instance_valid(wait_title):
		wait_title.visible = false
		wait_title.text = ""
	if is_instance_valid(wait_sub):
		wait_sub.visible = false
		wait_sub.text = ""
	_hide_arena_bracket()


func _sync_bracket_button() -> void:
	# The overlay's own CLOSE row sits under the bottom menu bar and
	# can't be reached, so the menu-bar button doubles as the close
	# control: it reads "Bracket Close" while the overlay is open.
	if not is_instance_valid(bracket_button):
		return
	var open := is_instance_valid(bracket_overlay) and bracket_overlay.visible
	bracket_button.text = "Bracket Close" if open else "BRACKET"


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
		# Headless (dummy renderer) has no real pixels: the viewport
		# texture read errors and yields null. The frame choreography
		# above still runs (callers await it), only the capture skips.
		if DisplayServer.get_name() == "headless":
			print("[Arena] Bracket screenshot skipped (headless renderer).")
		else:
			var img := get_viewport().get_texture().get_image()
			if img.save_png(base + ".png") == OK:
				print("[Arena] Bracket screenshot saved: ", base + ".png")
			else:
				push_warning("[Arena] Bracket screenshot failed: " + base + ".png")
	if showed:
		_hide_arena_bracket()

func _on_bracket_toggle() -> void:
	if bracket_overlay != null and bracket_overlay.visible:
		_wait_bracket = false
		_hide_arena_bracket()
	elif tournament_active:
		_wait_bracket = false
		_show_arena_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name])

func _flush_round_report() -> void:
	# Best-effort: quitting mid-round banks the cached matches (the
	# round nonce makes the report idempotent; a later full report of
	# the same round re-banks nothing). Partial = battles banked, match
	# results undecided. Fire-and-forget - the scene dies right after;
	# a server restart here loses the batch (the accepted tradeoff).
	if (_match_battle_cache.is_empty() and _round_match_cache.is_empty()) \
			or not tournament_active:
		return
	var extra := 0
	if not _match_battle_cache.is_empty():
		_round_match_cache.append(_current_match_entry("pending"))
		extra = _match_battle_cache.size()
		_match_battle_cache.clear()
	var n := _round_match_cache.size()
	brain_client.request_round_report(
		"%s-RND-%d-%d" % [tourney_match_label,
			Time.get_ticks_msec(), randi() % 100000],
		_tourney_id(), tourney_match_label,
		_round_match_cache)
	_round_match_cache.clear()
	print("[Arena] Flushed %d cached matches (%d stray battles) before quit." % [n, extra])


func _on_quit_to_menu() -> void:
	_restore_timescale()
	_flush_round_report()
	var director := _director()
	if director != null:
		director.hold_spawns = false
		director.quit_to_menu()

func _request_current_battle_load(bypass_bank_gate: bool = false) -> void:
	# Bank gate: next-round brains must load post-bank weights, and the
	# vault files turn post-round only when the bank's saves land (atomic
	# replaces: old-or-new, never torn - but old is STALE for the next
	# round). While a round OR group bank is owed, loads park on a
	# banking wait; the ack fires the parked load. Recovery reloads
	# bypass (they re-establish server state for a resend, not a fight).
	if (_round_bank_pending or _group_bank_pending) and not bypass_bank_gate:
		_load_gated_on_bank = true
		if is_instance_valid(status_label):
			status_label.text = "BANKING ROUND - loading %s on the ack..." % expand_match_label(tourney_match_label)
		print("[Arena] Load parked: round bank %s still owed." % _seq_round_id)
		return
	_restore_timescale()
	var director := _director()
	if director == null:
		return
	# Fresh match, no preview: a fail-loud QUIT+RESUME must never
	# resurrect the previous match's report-wait stamp on re-render.
	if arena_bracket != null:
		arena_bracket.live_preview = {}
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
			status_label.text = "CANNOT LOAD %s - brain file missing, QUIT TO MENU" % expand_match_label(tourney_match_label)
		return
	print("[Arena] Requesting tournament load: %s (%s vs %s)" % [
		str(p.get("match", "?")), str(p.get("a_name", "?")), str(p.get("b_name", "?"))])
	tourney_a_name = str(p.get("a_name", "ALPHA"))
	tourney_b_name = str(p.get("b_name", "BETA"))
	tourney_match_label = str(p.get("match", ""))
	tourney_awaiting_load = true
	refresh_slot_names()
	# Freeze the arena while the server swaps brains: no steps go out, so
	# the flies can never fight a round on stale/boot brains ("only
	# charges" first-battle bug). The bracket stays up with a squeezed
	# wait header (same strings/colors as the old fullscreen loader)
	# so no moment shows an empty arena; fullscreen only on fallback.
	is_round_active = false
	_set_combat(false)
	if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
		_set_wait_header("LOADING %s" % expand_match_label(tourney_match_label),
			"%s vs %s - brains loading..." % [tourney_a_name, tourney_b_name],
			Color(0.85, 0.85, 0.9))
	else:
		_hide_arena_bracket()
		_show_loading("LOADING %s" % expand_match_label(tourney_match_label),
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
	# State poll rides along (attribution: the reply logs the server's
	# mode/tag at every wait entry).
	brain_client.request_server_state()
	_arm_seq("load")

func _preload_next_match() -> void:
	# Sends the NEXT match's brains to the server's prepare slot while
	# a countdown or the 6 s review runs: the ~5-20 s disk+binding load
	# hides under the wait, so the next battle's official load becomes
	# an O(1) activation. Every call site has the director already
	# pointing at the next match (post-advance / post-switch), so
	# get_load_params IS the next match. Best-effort (no director /
	# missing paths -> no-op); never starts rounds, never touches the
	# watchdog.
	var director := _director()
	if director == null or not tournament_active:
		return
	var p: Dictionary = director.get_load_params()
	if str(p.get("alpha_path", "")) == "" or str(p.get("beta_path", "")) == "":
		return
	# Same match already held by the slot (ready or ack in flight):
	# no-op - a duplicate prepare would redo the 5-20 s server load.
	if str(_preload_params.get("match", "")) == str(p.get("match", "")) \
			and str(_preload_params.get("tournament_id", "")) == str(p.get("tournament_id", "")):
		return
	_preload_params = p.duplicate(true)
	_preload_ready = false
	brain_client.request_tournament_prepare(
		str(p.get("alpha_path", "")), str(p.get("beta_path", "")),
		str(p.get("tournament_id", "")), str(p.get("match", "")))
	print("[Arena] Preloading next match %s (%s vs %s)..." % [
		str(p.get("match", "")), str(p.get("a_name", "?")),
		str(p.get("b_name", "?"))])


func _on_prepared(reply_tid: String, reply_match: String) -> void:
	# The server finished loading the prepared match. Echo-checked
	# against what WE sent (a stale prepare ack from an earlier match
	# never marks readiness).
	if reply_tid != "" and reply_tid != str(_preload_params.get("tournament_id", "")):
		print("[Arena] Ignoring stale prepared ack (%s/%s)" % [reply_tid, reply_match])
		return
	_preload_ready = true
	print("[Arena] Next match preloaded and ready (%s)." % reply_match)


func _on_brains_loaded(_alpha_info: Dictionary, _beta_info: Dictionary,
		reply_tid: String = "", reply_match: String = "") -> void:
	if not tournament_active:
		return
	if not tourney_awaiting_load and _seq_context != "load":
		return
	# Match-echo validation: the reply must answer the CURRENT awaited
	# load (same tournament file + match label). A stale/late reply
	# from an earlier load is dropped loudly - it must never start a
	# round on the wrong brains (the server's load may still be queued
	# behind a 60 s battle bank). Old servers echo nothing: an empty
	# reply passes (the latch + single-starter rule still hold).
	if (reply_tid != "" or reply_match != "") \
			and _seq_last_load.get("tournament_id", "") != "" \
			and (reply_tid != str(_seq_last_load.get("tournament_id", ""))
				or reply_match != str(_seq_last_load.get("match", ""))):
		print("[Arena] Dropped stale brains_loaded (got %s/%s, want %s/%s)" % [
			reply_tid, reply_match,
			str(_seq_last_load.get("tournament_id", "")),
			str(_seq_last_load.get("match", ""))])
		_arena_log("dropped stale brains_loaded: got %s/%s want %s/%s" % [
			reply_tid, reply_match,
			str(_seq_last_load.get("tournament_id", "")),
			str(_seq_last_load.get("match", ""))])
		return
	_clear_seq()
	tourney_awaiting_load = false
	_arena_log("brains loaded: %s vs %s (%s)" % [
		str((_alpha_info as Dictionary).get("name", "?")),
		str((_beta_info as Dictionary).get("name", "?")),
		tourney_match_label])
	# A clean load resets the self-heal cap (each match gets fresh
	# recovery budget against server restarts) and consumes the
	# in-flight marker (recovery complete; later errors act again).
	_server_reloads = 0
	_recover_in_flight = false
	# Pending bank resend (recovery reload after a restart killed the
	# bank): do NOT start a round - the match is over, its battles are
	# tallied, and only the bank is missing. Re-arm from the STORED
	# report (same nonce, idempotent) and resend: the fresh server
	# banks it, or answers from disk if the old server finished the
	# bank before dying.
	if _pending_roundbank_resend and not _seq_last_round_report.is_empty():
		_pending_roundbank_resend = false
		var rr := _seq_last_round_report
		_tourney_awaiting_roundbank = true
		_seq_round_id = str(rr.get("round_nonce", ""))
		_seq_forgive_roundbank = {"tournament_id": str(rr.get("tournament_id", "")),
			"match": str(rr.get("match", "")), "battle": _seq_round_id}
		_hide_wait_bracket()
		_hide_loading()
		brain_client.request_round_report(_seq_round_id,
			str(rr.get("tournament_id", "")), str(rr.get("match", "")),
			(rr.get("matches", []) as Array), bool(rr.get("group", false)))
		_arm_seq("roundbank")
		print("[Arena] Resent stored round report %s after reload." % _seq_round_id)
		var rhead := _verdict_headline()
		if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
			_set_wait_header(str(rhead.get("text", "")),
				str(rhead.get("sub", "")) + "\nbanking the round (resend)...",
				rhead.get("color", Color(0.85, 0.85, 0.9)))
		# A group seal may be owed on top of the round: resend it after
		# the round (the round rebuilds the session the seal needs).
		# Either resend suppresses the normal round start below.
		_resend_stored_group_report()
		return
	if _resend_stored_group_report():
		return
	_hide_wait_bracket()
	_hide_loading()
	_update_tourney_status("READY")
	_reset_round()


func _resend_stored_group_report() -> bool:
	# Recovery reload after a restart killed the group bank: re-arm
	# from the STORED report (same nonce, idempotent) and resend: the
	# fresh server rebuilds from the inputs journal and seals, or
	# answers from disk if the old server finished before dying.
	# Returns true when it acted (caller must not start a round).
	if _pending_groupbank_resend and not _seq_last_group_report.is_empty():
		_pending_groupbank_resend = false
		var gr := _seq_last_group_report
		_tourney_awaiting_groupbank = true
		_seq_group_id = str(gr.get("group_nonce", ""))
		_seq_forgive_groupbank = {"tournament_id": str(gr.get("tournament_id", "")),
			"match": str(gr.get("match", "")), "battle": _seq_group_id}
		_hide_wait_bracket()
		_hide_loading()
		brain_client.request_group_report(_seq_group_id,
			str(gr.get("tournament_id", "")), str(gr.get("match", "")))
		_arm_seq("groupbank")
		print("[Arena] Resent stored group report %s after reload." % _seq_group_id)
		if is_instance_valid(status_label):
			status_label.text = "STALLED - RETRYING GROUP BANK ..."
		return true
	return false

func _on_match_ready() -> void:
	if not tournament_active:
		return
	if _seq_context != "reset":
		return
	# Stale-ack guard (Oct 2026 group-D phantom loop): a reset ack that
	# arrives after the director moved past the battle (complete/OOB)
	# must not start a ghost round. The director, not the seq context,
	# has the final say - a refused ack parks loud instead of fighting.
	var rdirector := _director()
	if rdirector == null or (rdirector.current_match() as Dictionary).is_empty():
		_arena_log("match_ready refused: director cannot place a battle (stale ack?) - parking loud")
		_clear_seq()
		_park_unplaceable_battle("", "stale-reset")
		return
	_clear_seq()
	_hide_wait_bracket()
	_hide_loading()
	_reset_round()

func _on_server_error(error: String) -> void:
	# An explicit server error explains any stall. If it hit an in-flight
	# battle report, retry once with the SAME battle id (the server answers
	# repeats from its stored verdict, so this cannot double-count).
	# Anything else stands the watchdog down so retry text never overwrites
	# the real reason; a late battle reply is dropped, never applied twice.
	_arena_log("server error: %s (awaiting %s)" % [error, _seq_context])
	if _seq_context == "battle" and _tourney_awaiting_battle \
			and not _seq_retried and not _seq_last_round.is_empty():
		_seq_retried = true
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("battle")
		var q := _seq_last_round
		print("[Arena] Battle report errored (%s); retrying same id=" % error,
			_seq_battle_id)
		if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
			_set_wait_header("BATTLE REPORT ERRORED - RETRYING",
				"Server error: %s. Re-sending the SAME report id %s " % [error, expand_battle_id(_seq_battle_id)]
				+ "(the server answers repeats from its stored verdict, no double count)...",
				Color(0.85, 0.85, 0.9))
		else:
			_show_loading("BATTLE REPORT ERRORED - RETRYING",
				"Server error: %s. Re-sending the SAME report id %s " % [error, expand_battle_id(_seq_battle_id)]
				+ "(the server answers repeats from its stored verdict, no double count)...")
		if is_instance_valid(status_label):
			status_label.text = "BATTLE ERROR - RETRYING %s ..." % expand_battle_id(_seq_battle_id)
		brain_client.reconnect()
		brain_client.send_round_over(q.get("stats_a", {}), q.get("stats_b", {}),
			bool(q.get("draw", false)), _seq_battle_id,
			str(q.get("tournament_id", "")), str(q.get("match", "")),
			q.get("flight_a", {}), q.get("flight_b", {}),
			bool(q.get("draw_penalty", false)),
			str(q.get("end_reason", "")), q.get("verdict", {}))
		return
	_tourney_awaiting_battle = false
	# Captured before _clear_seq wipes it (the recovery below needs it).
	var err_context := _seq_context
	_clear_seq()
	# General server error during a load: clear the load latch too -
	# a late reply must never silently start a round on this screen.
	tourney_awaiting_load = false
	# Self-healing reload BEFORE the fail-loud below: the server lost
	# its tournament brains mid-match (restart/crash - the gate error
	# the server sends for a brainless match_reset). Reloading the
	# CURRENT match continues it in ~5-20 s instead of killing the
	# tournament: the fresh load's _reset_round starts the next battle
	# and the arena's cached battles still bank at match over. Capped
	# (then the fail-loud below still lands).
	if err_context == "reset" and tournament_active \
			and error.begins_with("match_reset: no tournament brains loaded"):
		# Server lost its tournament brains mid-match (restart/crash):
		# the supervisor reloads the current match - the fresh load's
		# _reset_round starts the next battle and the cached battles
		# still bank at match over.
		if _recover_server_state("server brain loss"):
			return
	# Same self-heal for a round bank interrupted by a restart: the
	# fresh server refuses the report (FREE mode) with nothing banked.
	# Reload, then resend the STORED report (same nonce) on
	# brains_loaded - a new nonce here would risk double-banking if the
	# old server actually finished before dying. Flag set only when the
	# reload armed (a capped recovery leaves it clean for the fail-loud).
	# A round retry that lands after its group already sealed: the
	# round's learning is inside the group bank, so the round is
	# CONFIRMED, not lost - stand the latches down with no resend and
	# no recovery cycle.
	if error.begins_with("round_report: group already banked") \
			and tournament_active:
		print("[Arena] Round overtaken by its group bank - round confirmed, standing down.")
		_arena_log("round overtaken by group bank - confirmed, no resend")
		_tourney_awaiting_roundbank = false
		_round_bank_pending = false
		if _seq_context == "roundbank":
			_clear_seq()
		_seq_forgive_roundbank = {}
		return
	if err_context == "roundbank" and tournament_active \
			and error.begins_with("round_report while in FREE mode") \
			and not _seq_last_round_report.is_empty() \
			and not _pending_roundbank_resend:
		if _recover_server_state("round bank interrupted"):
			_pending_roundbank_resend = true
			return
	if err_context == "groupbank" and tournament_active \
			and error.begins_with("group_report: no pinned group session") \
			and not _seq_last_group_report.is_empty() \
			and not _pending_groupbank_resend:
		if _recover_server_state("group bank interrupted"):
			_pending_groupbank_resend = true
			return
	# A recovery load is already in flight (the state poll or a prior
	# error armed it): the refusal that motivated it can arrive now -
	# attribute it, never re-trigger or park loud mid-recovery.
	if _recover_in_flight:
		print("[Arena] Recovery in flight - error attributed, no action: ", error)
		return
	# ANY other server error: the quit+resume recipe runs in place
	# (fresh seq/latches/socket + re-issued load) before anything lands
	# loud. Only a persistently broken server (cap exhausted) parks on
	# the fail-loud screen.
	if tournament_active and _recover_server_state("server error: " + error):
		return
	_hide_wait_bracket()
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
		# Versus + score on their own centered row, below the round
		# line (the column labels are centered since arena entry).
		status_label.text = "%s %s:\n%s vs %s%s" % [expand_match_label(tourney_match_label), prefix,
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
	# Horizon ring baked into 5 MultiMeshes (was 1100 individual
	# nodes): identical pixels, a handful of draws. Buckets split
	# trunk/canopy by material (even/odd canopy hues). Distant trees
	# never fade or collide, so static instancing is exact.
	var h_buckets := {}
	var h_made := 0
	var h_tries := 0
	while h_made < HORIZON_TREE_COUNT and h_tries < HORIZON_TREE_COUNT * 20:
		h_tries += 1
		var hang = rng.randf_range(0.0, TAU)
		var hrad = HORIZON_RING_MIN + (HORIZON_RING_MAX - HORIZON_RING_MIN) * sqrt(rng.randf())
		var hp := Vector2(cos(hang) * hrad, sin(hang) * hrad)
		var hs = rng.randf_range(1.0, 2.2)
		var hrot := rng.randf_range(0.0, TAU)
		var tb := Basis(Vector3.UP, hrot).scaled(Vector3(hs, hs, hs))
		var tp := Vector3(hp.x, 0, hp.y)
		for spec in _tree_parts(decor, false):
			var sd := spec as Dictionary
			var pb: Basis = (sd["basis"] as Basis).scaled(sd["scl"] as Vector3)
			var mat: Material
			var key := str(sd.get("meshkey", "?"))
			if bool(sd.get("wood", true)):
				mat = bark_opaque
				key = "wood:" + key
			elif h_made % 2 == 0:
				mat = canopy_opaque_a
				key = "canA:" + key
			else:
				mat = canopy_opaque_b
				key = "canB:" + key
			if not h_buckets.has(key):
				h_buckets[key] = {"mesh": sd["mesh"], "mat": mat,
					"xforms": []}
			((h_buckets[key] as Dictionary)["xforms"] as Array).append(
				Transform3D(tb * pb, tp + tb * (sd["pos"] as Vector3)))
		h_made += 1
	for key in h_buckets.keys():
		var bd := h_buckets[key] as Dictionary
		_add_multimesh(forest_root, bd["mesh"] as Mesh,
			bd["mat"] as Material, bd["xforms"] as Array,
			AABB(Vector3(-200, -5, -200), Vector3(400, 45, 400)))
	print("[Arena] Horizon forest: ", h_made, " distant trees.")
	_build_underbrush(forest_root, decor, placed, spawn_a, spawn_b)


func _add_multimesh(parent: Node3D, mesh: Mesh, mat: Material,
		xforms: Array, bounds: AABB) -> void:
	# One draw call for a static crowd sharing mesh + material.
	# Explicit custom AABB: MultiMesh has no auto-bounds, and a wrong
	# one culls the whole crowd at some camera angles.
	if xforms.is_empty() or mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.custom_aabb = bounds
	if mat != null:
		mmi.material_override = mat
	parent.add_child(mmi)


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


func _tree_parts(decor: RandomNumberGenerator, full: bool) -> Array:
	# Shared tree layout math as ordered part specs (pname, meshkey,
	# mesh, pos, scl, basis, wood). _build_tree_visuals instantiates
	# them (combat trees, fadeable); the horizon ring bakes the same
	# specs into MultiMeshes instead. Decor draw ORDER is load-bearing
	# (layout stream bit-identity) - keep every draw in place.
	var parts: Array = []
	parts.append({"pname": "Roots", "meshkey": "flare",
		"mesh": _tree_mesh("flare"), "pos": Vector3(0, 0.9, 0),
		"scl": Vector3.ONE, "basis": Basis.IDENTITY, "wood": true})
	parts.append({"pname": "Trunk", "meshkey": "trunk_low",
		"mesh": _tree_mesh("trunk_low"), "pos": Vector3(0, 5.8, 0),
		"scl": Vector3.ONE, "basis": Basis.IDENTITY, "wood": true})
	var tilt_ang := decor.randf_range(0.0, 0.07)
	var tilt_az := decor.randf_range(0.0, TAU)
	var tilt_dir := Vector3(cos(tilt_az), 0.0, sin(tilt_az))
	var axis := Vector3.UP.cross(tilt_dir)
	if axis.length() < 0.01:
		axis = Vector3.RIGHT
	var top_basis := Basis(axis.normalized(), tilt_ang)
	var top_base := Vector3(0, 9.8, 0)
	parts.append({"pname": "TrunkTop", "meshkey": "trunk_top",
		"mesh": _tree_mesh("trunk_top"),
		"pos": top_base + top_basis * Vector3(0, 4.0, 0),
		"scl": Vector3.ONE, "basis": top_basis, "wood": true})
	var top_pos: Vector3 = top_base + top_basis * Vector3(0, 8.0, 0)
	# Main canopy blob (scaled half-height 1.98) tangent on the trunk top.
	var canopy_main := top_pos + Vector3(0, 1.98, 0)
	parts.append({"pname": "Canopy", "meshkey": "blob",
		"mesh": _tree_mesh("blob"), "pos": canopy_main,
		"scl": Vector3(1.15, 0.90, 1.15), "basis": Basis.IDENTITY,
		"wood": false})
	var a2 := decor.randf_range(0.0, TAU)
	var side_dir := Vector3(cos(a2), 0.0, sin(a2))
	parts.append({"pname": "Canopy2", "meshkey": "blob",
		"mesh": _tree_mesh("blob"),
		"pos": canopy_main + side_dir * 1.8 + Vector3(0, -1.0, 0),
		"scl": Vector3(0.72, 0.58, 0.72), "basis": Basis.IDENTITY,
		"wood": false})
	if full:
		# Crown blob (scaled half-height 1.35) tangent on the main mass.
		parts.append({"pname": "Canopy3", "meshkey": "blob_small",
			"mesh": _tree_mesh("blob_small"),
			"pos": canopy_main + tilt_dir * 0.2 + Vector3(0, 3.33, 0),
			"scl": Vector3(1.0, 0.90, 1.0), "basis": Basis.IDENTITY,
			"wood": false})
	return parts


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
	for spec in _tree_parts(decor, full):
		var sd := spec as Dictionary
		var mat = tmat if bool(sd.get("wood", true)) else cmat
		var mi := _add_tree_part(parent, str(sd.get("pname", "?")),
			sd["mesh"] as Mesh, sd["pos"] as Vector3, mat,
			sd["scl"] as Vector3)
		mi.basis = (sd["basis"] as Basis).scaled(sd["scl"] as Vector3)


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
	# MultiMesh instance transforms (one draw per crowd instead of one
	# per bush/rock/blade). Draw ORDER below is untouched.
	var bush_a_x: Array = []
	var bush_b_x: Array = []
	var rock_x: Array = []
	var grass_x: Array = []
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
		var brot := decor.randf_range(0.0, TAU)
		var bs := decor.randf_range(0.7, 1.5)
		var bsq := decor.randf_range(0.60, 0.80)
		var bxform := Transform3D(
			Basis(Vector3.UP, brot).scaled(Vector3(bs, bs * bsq, bs)),
			Vector3(bp.x, 0.55, bp.y))
		if made_bush % 2 == 0:
			bush_a_x.append(bxform)
		else:
			bush_b_x.append(bxform)
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
		var rrot := Vector3(decor.randf_range(-0.2, 0.2), decor.randf_range(0.0, TAU), decor.randf_range(-0.2, 0.2))
		var rscl := Vector3(decor.randf_range(0.8, 1.8), decor.randf_range(0.5, 0.8), decor.randf_range(0.8, 1.6))
		rock_x.append(Transform3D(
			Basis.from_euler(rrot).scaled(rscl),
			Vector3(rp.x, 0.25, rp.y)))
	var made_grass := 0
	for i in range(70):
		var gp := Vector2(decor.randf_range(-38.0, 38.0), decor.randf_range(-38.0, 38.0))
		if gp.distance_to(spawn_a) < 3.0 or gp.distance_to(spawn_b) < 3.0:
			continue
		made_grass += 1
		for b in range(3):
			var bpos := Vector3(gp.x + decor.randf_range(-0.4, 0.4), 0.45, gp.y + decor.randf_range(-0.4, 0.4))
			var brot := Vector3(decor.randf_range(-0.15, 0.15), decor.randf_range(0.0, TAU), decor.randf_range(-0.15, 0.15))
			var gs := decor.randf_range(0.7, 1.3)
			grass_x.append(Transform3D(
				Basis.from_euler(brot).scaled(Vector3(gs, gs, gs)), bpos))
	_add_multimesh(under, _tree_mesh("bush"), bush_mat_a, bush_a_x,
		AABB(Vector3(-45, -2, -45), Vector3(90, 12, 90)))
	_add_multimesh(under, _tree_mesh("bush"), bush_mat_b, bush_b_x,
		AABB(Vector3(-45, -2, -45), Vector3(90, 12, 90)))
	_add_multimesh(under, _tree_mesh("rock"), rock_mat, rock_x,
		AABB(Vector3(-45, -2, -45), Vector3(90, 12, 90)))
	_add_multimesh(under, _tree_mesh("grass"), grass_mat, grass_x,
		AABB(Vector3(-45, -2, -45), Vector3(90, 12, 90)))
	print("[Arena] Underbrush: ", made_bush, " bushes, ", made_rock, " rocks, ", made_grass, " grass tufts.")

func _seq_timeout_for(context: String) -> int:
	# The match bank replays every battle in order (dopamine per battle
	# + one save pair): same cost class as a single long battle report.
	# The group bank seals + saves every pinned brain: same class.
	if context == "battle" or context == "roundbank" \
			or context == "groupbank":
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
	_arena_log("watchdog fired: context=%s retry_sent=%s battle_id=%s" % [
		_seq_context, str(_seq_retried), _seq_battle_id])
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
			var retry_sub := "No confirmation for battle %s yet. Re-sending the SAME report id " % expand_battle_id(_seq_battle_id) \
				+ "(the server answers repeats from its stored verdict, no double count)..."
			if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
				_set_wait_header("STALLED - RETRYING BATTLE REPORT",
					retry_sub, Color(0.85, 0.85, 0.9))
			else:
				_show_loading("STALLED - RETRYING BATTLE REPORT", retry_sub)
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING BATTLE %s ..." % expand_battle_id(_seq_battle_id)
			# Heal a poisoned UDP socket before resending: the reply to
			# the first send may be chasing a dead port already.
			brain_client.reconnect()
			brain_client.send_round_over(q.get("stats_a", {}), q.get("stats_b", {}),
				bool(q.get("draw", false)), _seq_battle_id,
				str(q.get("tournament_id", "")), str(q.get("match", "")),
				q.get("flight_a", {}), q.get("flight_b", {}),
				bool(q.get("draw_penalty", false)),
				str(q.get("end_reason", "")), q.get("verdict", {}))
			return
		_tourney_awaiting_battle = false
		_clear_seq()
		# The battle was sent twice with no confirmation. In batch mode
		# this context cannot fire (battles carry no server round
		# trip); free/legacy paths recover via the supervisor before
		# parking loud (the reload re-plays the unbanked battle fresh).
		if tournament_active and _recover_server_state("battle unconfirmed"):
			return
		_hide_wait_bracket()
		_show_loading("SERVER SILENT - BATTLE NOT CONFIRMED",
			"Battle %s was sent twice but the server never confirmed. " % expand_match_label(tourney_match_label)
			+ "Nothing further will be re-sent. See server_log.txt, then QUIT TO MENU + RESUME.")
		if is_instance_valid(status_label):
			status_label.text = "SERVER SILENT - see server_log.txt - QUIT TO MENU + RESUME"
		return
	if not _seq_retried:
		_seq_retried = true
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for(_seq_context)
		if _seq_context == "roundbank" and not _seq_last_round_report.is_empty():
			# Same round nonce, idempotent: the server answers repeats
			# from the stored round verdict, never double-banks.
			var mr := _seq_last_round_report
			print("[Arena] Retrying round report id=", _seq_round_id,
				" (same id, idempotent)")
			if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
				_set_wait_header("STALLED - RETRYING ROUND BANK",
					"No confirmation for the round yet. Re-sending the SAME report id "
					+ "(the server answers repeats from its stored verdict, no double count)...",
					Color(0.85, 0.85, 0.9))
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING ROUND BANK ..."
			brain_client.reconnect()
			brain_client.request_round_report(
				str(mr.get("round_nonce", "")), str(mr.get("tournament_id", "")),
				str(mr.get("match", "")), (mr.get("matches", []) as Array),
				bool(mr.get("group", false)))
			return
		if _seq_context == "groupbank" and not _seq_last_group_report.is_empty():
			# Same group nonce, idempotent: the server answers repeats
			# from the stored group verdict, never double-banks.
			var gr := _seq_last_group_report
			print("[Arena] Retrying group report id=", _seq_group_id,
				" (same id, idempotent)")
			if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
				_set_wait_header("STALLED - RETRYING GROUP BANK",
					"No confirmation for the group yet. Re-sending the SAME report id "
					+ "(the server answers repeats from its stored verdict, no double count)...",
					Color(0.85, 0.85, 0.9))
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING GROUP BANK ..."
			brain_client.reconnect()
			brain_client.request_group_report(
				str(gr.get("group_nonce", "")), str(gr.get("tournament_id", "")),
				str(gr.get("match", "")))
			return
		if _seq_context == "load" and not _seq_last_load.is_empty():
			var p := _seq_last_load
			if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
				_set_wait_header("STALLED - RETRYING LOAD",
					"%s vs %s - brains loading (retry sent)..." % [tourney_a_name, tourney_b_name],
					Color(0.85, 0.85, 0.9))
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING LOAD %s vs %s ..." % [tourney_a_name, tourney_b_name]
			# Heal a poisoned socket before the retry (the first send's
			# reply may be chasing a dead port already).
			brain_client.reconnect()
			brain_client.request_tournament_load(
				str(p.get("alpha_path", "")), str(p.get("beta_path", "")),
				str(p.get("tournament_id", "")), str(p.get("match", "")),
				float(p.get("lr_scale", 0.5)))
		else:
			if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
				_set_wait_header("STALLED - RETRYING RESET",
					"waiting for server (match reset retry sent)...",
					Color(0.85, 0.85, 0.9))
			if is_instance_valid(status_label):
				status_label.text = "STALLED - RETRYING RESET ..."
			brain_client.request_match_reset(tourney_match_label)
		return
	# Second expiry: the quit+resume recipe runs in place before
	# anything parks loud (a wedged load/reset/roundbank un-wedges with
	# a fresh seq/socket + re-issued load; a late reply can never
	# silently start a round behind the recovery). Only a persistently
	# broken server (cap exhausted) lands the fail-loud screen.
	_clear_seq()
	tourney_awaiting_load = false
	if tournament_active and _recover_server_state("no server reply"):
		return
	_hide_wait_bracket()
	_show_loading("STALLED - NO SERVER REPLY",
		"See server_log.txt - QUIT TO MENU + RESUME. Nothing was re-sent.")
	if is_instance_valid(status_label):
		status_label.text = "STALLED - see server_log.txt - QUIT TO MENU + RESUME"

var _round_overtime := 1.0


func _reset_round() -> void:
	# New round waits for the landing ceremony (bounded inside).
	await _await_landing()
	current_round_time = round_time_limit
	_round_overtime = 1.0
	if tournament_active:
		var director := _director()
		if director != null:
			current_round_time = float(director.tourney.get("round_time", round_time_limit))
			# Overtime exactly once: the immediate replay after a DNF.
			# Later battles in the same match run base time even with
			# banked draws (no carry-over); new matches start clean.
			_round_overtime = director.replay_scale(director.current_match())
			current_round_time *= _round_overtime
	is_round_active = true
	stats_alpha = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
	stats_beta  = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 0.0, "tracking_time_s": 0.0, "tail_time_s": 0.0 }
	_end_reason = ""
	_ko_victim = ""
	_time_winner = ""
	_last_verdict = {}
	flight_alpha = {}
	flight_beta = {}
	bv_cad_n = 0
	bv_cad_dt_sum = 0.0
	bv_cad_tau_sum = 0.0
	bv_last_reply = -1.0
	# A lost final reply must not wedge the next round's first send;
	# the in-flight flag dies with the round (_ctrl_n stays
	# cumulative - see its declaration).
	_step_in_flight = false
	_step_timeouts = 0
	bv_stream_alpha.clear()
	bv_stream_beta.clear()
	if is_instance_valid(bv_raster_alpha):
		bv_raster_alpha.clear()
	if is_instance_valid(bv_raster_beta):
		bv_raster_beta.clear()

	# Head-on joust spawn: forward is -Z, so yaw -90 faces +X (toward beta)
	# and yaw +90 faces -X (toward alpha). Previously swapped (back-to-back).
	fly_alpha.reset_fly(Vector3(-14.0, 7.0, 0.0), deg_to_rad(-90.0))
	fly_beta.reset_fly(Vector3(14.0, 7.0, 0.0), deg_to_rad(90.0))
	# Overtime wander dock, gated on the same one-time replay scale:
	# the last DNF's drift converts into missing starting health
	# (farther ran = more docked), so the replay opens unequal and
	# ties almost never repeat. First battles, post-decisive battles
	# and free fights start whole.
	if tournament_active and _round_overtime > 1.0:
		var ddirector := _director()
		if ddirector != null:
			var dm: Dictionary = ddirector.current_match()
			var dock_a := _wander_dock(float(dm.get("drift_a", 0.0)))
			var dock_b := _wander_dock(float(dm.get("drift_b", 0.0)))
			if is_instance_valid(fly_alpha):
				fly_alpha.health = maxf(fly_alpha.health - dock_a, 1.0)
			if is_instance_valid(fly_beta):
				fly_beta.health = maxf(fly_beta.health - dock_b, 1.0)
	_set_combat(true)

	if is_instance_valid(status_label):
		status_label.text = "AERIAL JOUST IN PROGRESS"

func _physics_process(delta: float) -> void:
	# Watchdog runs even between rounds: that limbo is exactly where a
	# lost server reply would wedge the game.
	_check_seq_watchdog()
	_check_step_watchdog()
	if not is_round_active:
		return

	current_round_time -= delta
	# Timer rewritten only on decisecond change (per-tick string builds
	# and Label re-shapes were churn; 0.1 s granularity is the display).
	var tenths := int(maxf(current_round_time, 0.0) * 10.0)
	if is_instance_valid(timer_label) and tenths != _timer_last_tenths:
		_timer_last_tenths = tenths
		timer_label.text = "ROUND TIME: %04.1f s" % maxf(current_round_time, 0.0)
		if _round_overtime > 1.0:
			timer_label.text += " (OVERTIME x%.1f)" % _round_overtime

	_update_health_hud()

	var sens_a = fly_alpha.get_sensory_data(delta)
	var sens_b = fly_beta.get_sensory_data(delta)
	if sens_a.get("visual_target_visible", false):
		stats_alpha["tracking_time_s"] += delta
	if sens_b.get("visual_target_visible", false):
		stats_beta["tracking_time_s"] += delta
	# Ground-scrape accumulation (fitness demerit): floor-band seconds
	# per side, reported in the round stats.
	if fly_alpha.global_position.y <= FlyPhysicsScript.FLOOR_Y + 0.3:
		stats_alpha["scrape_time_s"] = float(stats_alpha.get("scrape_time_s", 0.0)) + delta
	if fly_beta.global_position.y <= FlyPhysicsScript.FLOOR_Y + 0.3:
		stats_beta["scrape_time_s"] = float(stats_beta.get("scrape_time_s", 0.0)) + delta
	# Rear-aspect chase: on the victim's tail and facing it. This is the
	# battle-level "who is winning the chase" score; evolution caps it so it
	# can only decide equal-kill bouts, never outscore a kill.
	if float(sens_a.get("tail_chase", 0.0)) > 0.5:
		stats_alpha["tail_time_s"] += delta
	if float(sens_b.get("tail_chase", 0.0)) > 0.5:
		stats_beta["tail_time_s"] += delta

	brain_tick_timer += delta
	if _should_send_step():
		brain_tick_timer = 0.0
		brain_client.send_sensory_step(sens_a, sens_b)
		_step_in_flight = true
		_step_deadline_msec = Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
		# Dopamine-replay inputs: the sens refs land at send time (the
		# dicts are fresh per step, so this is the last-sent context).
		_last_sens_a = sens_a
		_last_sens_b = sens_b

	if is_instance_valid(arena_camera):
		var midpoint = (fly_alpha.global_position + fly_beta.global_position) * 0.5
		var cam_dist = clampf((fly_alpha.global_position - fly_beta.global_position).length() * 0.9, 16.0, 38.0)
		var target_cam_pos = midpoint + Vector3(0, cam_dist * 0.45, cam_dist)
		arena_camera.global_position = arena_camera.global_position.lerp(target_cam_pos, delta * 3.0)
		arena_camera.look_at(midpoint + Vector3(0, 1.5, 0), Vector3.UP)

	_update_pip_throttled(sens_a, sens_b)

	if current_round_time <= 0.0:
		# Timeout decided by remaining health: most health wins no
		# matter what dented the loser (strikes, wing tears via prior
		# KO, tree rams, ground scrapes — bad flying is bad outcome).
		# Near-equal health is a tie for the DNF/overtime ladder.
		# Free battle: a tie rematches the SAME brains with no champion
		# and no evolution advance. Tournament: ties report as draws
		# (recorded, no dopamine) and replay; wins report for banking.
		# The arena decides; the server only records and trains.
		var decision := _timeout_winner(fly_alpha.health, fly_beta.health)
		if decision == "draw":
			_end_reason = "draw"
			_handle_draw()
		else:
			_end_reason = "time"
			_time_winner = decision
			_end_round()

func _should_send_step() -> bool:
	# Fires at most every BRAIN_TICK_DT of physics time AND only when
	# no reply is outstanding. The is_connected_server conjunct is
	# load-bearing: send_sensory_step drops silently when disconnected,
	# and flagging a dropped packet would wedge stepping until the
	# step watchdog fires. If stepping ever wedges (no sends and no
	# replies), check _step_in_flight/_step_deadline_msec here first.
	return brain_tick_timer >= BRAIN_TICK_DT \
		and not _step_in_flight \
		and brain_client.is_connected_server


func _check_step_watchdog() -> void:
	# Lost-reply recovery for paced steps. Deliberately SILENT (no
	# wait-bracket/modal): a missed step is routine and the next tick
	# sends fresh state. We clear the flag rather than resend because
	# fresh sensory state is strictly better than stale. Escalation
	# policy lives here too: only 5+ consecutive timeouts (~10 s with
	# zero control) earns status text, never a modal. To make step
	# loss fail LOUD instead, hook _step_timeouts here.
	if not _step_in_flight:
		return
	if not is_round_active:
		_step_in_flight = false
		return
	if Time.get_ticks_msec() < _step_deadline_msec:
		return
	_step_in_flight = false
	_step_timeouts += 1
	# Heal a poisoned UDP socket before the next send: the lost reply
	# may be chasing a dead port already (same pattern as the seq
	# retries).
	brain_client.reconnect()
	print("[Arena] Step watchdog: no control reply within %d ms (consecutive=%d)." % [STEP_TIMEOUT_MSEC, _step_timeouts])
	_arena_log("step watchdog fired: consecutive=%d" % _step_timeouts)
	if _step_timeouts >= 5 and is_instance_valid(status_label):
		status_label.text = "CONTROL LINK SLOW - reflex holding..."

const PIP_TICK_EVERY := 6
func _make_pip_stats(parent: Node, left_side: bool) -> Label:
	# Fly-stat card overlaying a PiP slot: name header in team color
	# plus a full-word stat body. Top edge lines up with the health
	# bar (y=8); same geometry both sides. A backing wash rect spans
	# the whole card (normally transparent) so strike flashes cover
	# the card area in team color, never just the text.
	var is_alpha := left_side
	var wash := ColorRect.new()
	if left_side:
		wash.set_anchors_preset(Control.PRESET_TOP_LEFT)
		wash.offset_left = 16.0
		wash.offset_right = 316.0
	else:
		wash.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		wash.anchor_left = 1.0
		wash.anchor_right = 1.0
		wash.offset_left = -316.0
		wash.offset_right = -16.0
	wash.offset_top = 8.0
	wash.offset_bottom = 320.0
	wash.color = Color(1.0, 1.0, 1.0, 0.0)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wash.visible = false
	parent.add_child(wash)
	if is_alpha:
		pip_flash_alpha = wash
	else:
		pip_flash_beta = wash
	var nm := Label.new()
	if left_side:
		nm.set_anchors_preset(Control.PRESET_TOP_LEFT)
		nm.offset_left = 16.0
		nm.offset_right = 316.0
	else:
		nm.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		nm.anchor_left = 1.0
		nm.anchor_right = 1.0
		nm.offset_left = -316.0
		nm.offset_right = -16.0
	nm.offset_top = 8.0
	nm.offset_bottom = 36.0
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.add_theme_font_size_override("font_size", 17)
	nm.add_theme_color_override("font_color",
		TEAM_ALPHA if is_alpha else TEAM_BETA)
	nm.clip_text = true
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.visible = false
	parent.add_child(nm)
	if is_alpha:
		pip_name_alpha = nm
	else:
		pip_name_beta = nm
	var l := Label.new()
	if left_side:
		l.set_anchors_preset(Control.PRESET_TOP_LEFT)
		l.offset_left = 16.0
		l.offset_right = 316.0
	else:
		l.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		l.anchor_left = 1.0
		l.anchor_right = 1.0
		l.offset_left = -316.0
		l.offset_right = -16.0
	l.offset_top = 38.0
	l.offset_bottom = 320.0
	l.add_theme_font_size_override("font_size", 12)
	# Tight rows: the stat card carries ~14 rows in 282 px, several
	# wrapping to two lines - default line spacing clipped the tail.
	l.add_theme_constant_override("line_spacing", 1)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	parent.add_child(l)
	# Bottom of the z-stack, card order kept (wash, name, body):
	# popups appended later (e.g. the bracket overlay) must cover stat
	# cards, never the reverse.
	var wash_node: ColorRect = pip_flash_alpha if is_alpha else pip_flash_beta
	if is_instance_valid(wash_node):
		parent.move_child(wash_node, 0)
	parent.move_child(nm, 1)
	parent.move_child(l, 2)
	return l


func _make_pip_motors(parent: Node, left_side: bool) -> void:
	# MOTORS-slot debug widgets in the same card rect: 4 bipolar
	# command bars (thrust 0..1, yaw/pitch/roll -1..+1) plus a scrolling
	# command-trace canvas below. Same geometry both sides; hidden
	# unless the PiP slot is MOTORS.
	var is_alpha := left_side
	var bars: Array = []
	var mins := [0.0, -1.0, -1.0, -1.0]
	var fills := [TEAM_ALPHA if is_alpha else TEAM_BETA, Color(1, 1, 1),
		Color(1.0, 0.85, 0.3), Color(0.35, 0.85, 1.0)]
	for i in range(4):
		var bar := ProgressBar.new()
		if left_side:
			bar.set_anchors_preset(Control.PRESET_TOP_LEFT)
			bar.offset_left = 16.0
			bar.offset_right = 316.0
		else:
			bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			bar.anchor_left = 1.0
			bar.anchor_right = 1.0
			bar.offset_left = -316.0
			bar.offset_right = -16.0
		bar.offset_top = 165.0 + float(i) * 20.0
		bar.offset_bottom = 181.0 + float(i) * 20.0
		bar.min_value = mins[i]
		bar.max_value = 1.0
		bar.value = 0.0
		bar.show_percentage = false
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0, 0, 0, 0.45)
		bar.add_theme_stylebox_override("background", bg)
		var fill := StyleBoxFlat.new()
		fill.bg_color = fills[i]
		bar.add_theme_stylebox_override("fill", fill)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.visible = false
		parent.add_child(bar)
		bars.append(bar)
	if is_alpha:
		pip_motor_bars_alpha = bars
	else:
		pip_motor_bars_beta = bars
	var trace := Control.new()
	if left_side:
		trace.set_anchors_preset(Control.PRESET_TOP_LEFT)
		trace.offset_left = 16.0
		trace.offset_right = 316.0
	else:
		trace.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		trace.anchor_left = 1.0
		trace.anchor_right = 1.0
		trace.offset_left = -316.0
		trace.offset_right = -16.0
	trace.offset_top = 246.0
	trace.offset_bottom = 316.0
	trace.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trace.visible = false
	parent.add_child(trace)
	# Opaque scope backing: the trace rect overlaps the brain side
	# panels - the dark card reads as a deliberate inset instead of
	# trace lines crossing pool text. Added after the trace so it sits
	# below it in z.
	var scope := PanelContainer.new()
	if left_side:
		scope.set_anchors_preset(Control.PRESET_TOP_LEFT)
		scope.offset_left = 16.0
		scope.offset_right = 316.0
	else:
		scope.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		scope.anchor_left = 1.0
		scope.anchor_right = 1.0
		scope.offset_left = -316.0
		scope.offset_right = -16.0
	scope.offset_top = 246.0
	scope.offset_bottom = 316.0
	var sbg := StyleBoxFlat.new()
	sbg.bg_color = Color(0.06, 0.06, 0.09, 0.94)
	sbg.set_border_width_all(1)
	sbg.border_color = Color(0.4, 0.4, 0.46)
	sbg.set_corner_radius_all(4)
	scope.add_theme_stylebox_override("panel", sbg)
	scope.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scope.visible = false
	parent.add_child(scope)
	parent.move_child(scope, trace.get_index())
	trace.draw.connect(_on_motor_trace_draw.bind("alpha" if is_alpha else "beta"))
	if is_alpha:
		pip_motor_trace_alpha = trace
		pip_motor_scope_alpha = scope
	else:
		pip_motor_trace_beta = trace
		pip_motor_scope_beta = scope
	# Z-order: these build lazily on first MOTORS entry, long after the
	# bracket overlay - without this they would draw ON TOP of it (the
	# stat cards avoid this via move_child 0/1/2 at build). Tuck every
	# widget just below the bracket overlay, which itself stays below
	# the WinnerOverlay callouts.
	if is_instance_valid(bracket_overlay):
		var below := bracket_overlay.get_index()
		for w in bars + [trace, scope]:
			if is_instance_valid(w):
				parent.move_child(w, below)


func _format_fighter_rows(rec: Dictionary, gp: Dictionary, lin: Dictionary,
		tr: Dictionary, parents: Dictionary, live: Dictionary,
		st: Dictionary, match_draws: int = 0) -> PackedStringArray:
	# Pure stat-row builder (no scene/director reads, so headless tests
	# can pin it): identical full-word row order for both flies. Career
	# figures ride the bracket snapshot (frozen at build, refreshed per
	# match load); live figures update on change.
	var lines := PackedStringArray()
	# Training score rides the ELO row: recent form (mean over the
	# last RECENT_EPISODES training episodes), so post-training
	# improvement shows instead of the lifetime average. 0.00 = no
	# stamped recent form yet (pre-ring brains populate on their next
	# training stamp); the Schooling row below carries context.
	lines.append("ELO %d | Training score %.2f/ep" % [
		int(rec.get("elo", 1200.0)), float(tr.get("recent_avg", 0.0))])
	lines.append("Battles: %d (Wins %d, Losses %d)" % [
		int(rec.get("battles", 0)), int(rec.get("wins", 0)),
		int(rec.get("losses", 0))])
	lines.append("Did not finish: %d" % [
		int(rec.get("draws", 0)) + maxi(match_draws, 0)])
	lines.append("Wandered: %d" % int(rec.get("wander", 0)))
	lines.append("Knockouts: %d (%d this match)" % [
		int(rec.get("ko", 0)), int(st.get("kills", 0))])
	lines.append("Matches: %d (Won %d), Titles: %d" % [
		int(rec.get("matches", 0)), int(rec.get("matches_won", 0)),
		int(rec.get("tournaments_won", 0))])
	lines.append("Schooling: %d episodes" % int(tr.get("episodes", 0)))
	var src := str(lin.get("source", "generated"))
	var peds: Array = lin.get("parent_ids", [])
	var ped := src
	if src.begins_with("clone:"):
		var pn := str(parents.get(str(peds[0]) if not peds.is_empty() else "", "?"))
		ped = "junior of %s (junior %d)" % [pn, int(lin.get("jr", 0))] \
			if int(lin.get("jr", 0)) > 0 \
			else "clone of %s" % pn
		if int(lin.get("kin", 0)) > 0 and int(lin.get("jr", 0)) <= 0:
			ped += " (kin %d)" % int(lin.get("kin", 0))
	elif src.begins_with("crossover:"):
		var an := str(parents.get(str(peds[0]) if peds.size() > 0 else "", "?"))
		var bn := str(parents.get(str(peds[1]) if peds.size() > 1 else "", "?"))
		ped = "crossover %s x %s" % [an, bn]
		if int(lin.get("jr", 0)) > 0:
			ped += " (junior %d)" % int(lin.get("jr", 0))
	elif src == "reference":
		ped = "reference stock"
	elif src == "evo-random" or src == "generated":
		ped = "wild" if src == "evo-random" else "generated"
	lines.append("Pedigree: %s" % ped)
	var gid := str(gp.get("genome_id", ""))
	if gid == "":
		var exp = gp.get("experiment", null)
		gid = "mix" if exp is Array else (str(exp) if exp != null and str(exp) != "" else "base")
	lines.append("Evasion: %.2f, Learning rate: %.4f, Wiring: %s" % [
		float(gp.get("evasion", 0.0)), float(gp.get("learning_rate", 0.0)), gid])
	lines.append("Speed: %.1f, Thrust: %.2f, Health: %.0f" % [
		float(live.get("spd", 0.0)), float(live.get("thr", 0.0)),
		float(live.get("hp", 0.0))])
	lines.append("Beyond arena: %.1f m" % float(live.get("drift", 0.0)))
	return lines


func _pip_stats_text(side: String) -> String:
	# Live fly stat card body (the name rides its own team-colored
	# label): record, traits, pedigree, and live flight numbers.
	# Record/traits ride the bracket snapshot (no vault shell-outs at
	# 10 Hz); row order/shape comes from _format_fighter_rows so both
	# flies always read identically.
	var fly: CharacterBody3D = fly_alpha if side == "alpha" else fly_beta
	var rec := {}
	var gp := {}
	var lin := {}
	var tr := {}
	var director := _director()
	var match_draws := 0
	if director != null:
		var m: Dictionary = director.current_match()
		match_draws = int(m.get("draws", 0))
		var pid := str(m.get("a_id" if side == "alpha" else "b_id", ""))
		for p in director.tourney.get("players", []):
			if str((p as Dictionary).get("id", "")) == pid:
				rec = (p as Dictionary).get("record", {})
				gp = (p as Dictionary).get("generator_params", {})
				lin = (p as Dictionary).get("lineage", {})
				tr = (p as Dictionary).get("training", {})
				break
	var parents := {}
	for ppid in (lin.get("parent_ids", []) as Array):
		parents[str(ppid)] = _nextgen_parent_name(str(ppid))
	var live := {"spd": 0.0, "thr": 0.0, "hp": 0.0, "drift": 0.0}
	if is_instance_valid(fly):
		live["spd"] = (fly as CharacterBody3D).velocity.length()
		var _t = fly.get("current_thrust")
		live["thr"] = float(_t) if _t != null else 0.0
		var _h = fly.get("health")
		live["hp"] = float(_h) if _h != null else 0.0
		var _flat := Vector2(
			(fly as CharacterBody3D).global_position.x,
			(fly as CharacterBody3D).global_position.z)
		live["drift"] = maxf(_flat.length() - ARENA_RING_R, 0.0)
	var st: Dictionary = stats_alpha if side == "alpha" else stats_beta
	return "\n".join(_format_fighter_rows(rec, gp, lin, tr, parents,
		live, st, match_draws))


func _park_pip_on_cloud(cam: Camera3D, cloud: Node3D) -> void:
	# Frame a spinning brain cloud in a PiP viewport (shared world, so
	# no reparenting: just point the existing eye camera at it).
	if is_instance_valid(cam) and is_instance_valid(cloud):
		var cp: Vector3 = (cloud as Node3D).global_position
		cam.global_transform = Transform3D(Basis(), cp + Vector3(0.6, 0.9, 2.6))
		cam.look_at(cp)


func _apply_pip_slot() -> void:
	# Immediate visibility/label/cloud work for a slot change (the
	# per-tick pump below handles cameras and stat refresh).
	var eyes := pip_slot_mode == "EYES"
	var brain := pip_slot_mode == "BRAIN"
	var motors := pip_slot_mode == "MOTORS"
	if pip_stats_alpha == null and is_instance_valid(pip_alpha_box):
		pip_stats_alpha = _make_pip_stats(pip_alpha_box.get_parent(), true)
	if pip_stats_beta == null and is_instance_valid(pip_beta_box):
		pip_stats_beta = _make_pip_stats(pip_beta_box.get_parent(), false)
	# STATS and MOTORS hide the viewport boxes outright (otherwise the
	# last eye frame sits frozen behind the cards).
	var show_views := perf_pip and pip_slot_mode != "STATS" and not motors
	for n in [pip_alpha_box, pip_beta_box]:
		if is_instance_valid(n):
			(n as Control).visible = show_views
	for n in [pip_alpha_label, pip_beta_label, pip_alpha_feat, pip_beta_feat]:
		if is_instance_valid(n):
			(n as Control).visible = perf_pip and eyes
	# STATS/MOTORS cards, name rows, and motor widgets are cheap
	# labels/canvas - they follow the slot mode even when eye renders
	# are disabled (render saver, not stats killer). Only the viewport
	# boxes and eye labels follow perf_pip.
	if is_instance_valid(pip_stats_alpha):
		pip_stats_alpha.visible = not eyes and (pip_slot_mode == "STATS" or motors)
	if is_instance_valid(pip_stats_beta):
		pip_stats_beta.visible = not eyes and (pip_slot_mode == "STATS" or motors)
	if is_instance_valid(pip_name_alpha):
		pip_name_alpha.visible = pip_stats_alpha.visible if is_instance_valid(pip_stats_alpha) else false
	if is_instance_valid(pip_name_beta):
		pip_name_beta.visible = pip_stats_beta.visible if is_instance_valid(pip_stats_beta) else false
	if is_instance_valid(pip_flash_alpha):
		pip_flash_alpha.visible = pip_stats_alpha.visible if is_instance_valid(pip_stats_alpha) else false
	if is_instance_valid(pip_flash_beta):
		pip_flash_beta.visible = pip_stats_beta.visible if is_instance_valid(pip_stats_beta) else false
	# Motor debug widgets (bars + trace per side): built lazily like
	# the stat cards, shown only in MOTORS mode.
	if pip_motor_bars_alpha.is_empty() and is_instance_valid(pip_alpha_box):
		_make_pip_motors(pip_alpha_box.get_parent(), true)
	if pip_motor_bars_beta.is_empty() and is_instance_valid(pip_beta_box):
		_make_pip_motors(pip_beta_box.get_parent(), false)
	for bar in pip_motor_bars_alpha + pip_motor_bars_beta:
		if is_instance_valid(bar):
			(bar as Control).visible = motors
	if is_instance_valid(pip_motor_trace_alpha):
		pip_motor_trace_alpha.visible = motors
	if is_instance_valid(pip_motor_trace_beta):
		pip_motor_trace_beta.visible = motors
	if is_instance_valid(pip_motor_scope_alpha):
		pip_motor_scope_alpha.visible = motors
	if is_instance_valid(pip_motor_scope_beta):
		pip_motor_scope_beta.visible = motors
	if eyes:
		if is_instance_valid(pip_alpha_label):
			pip_alpha_label.text = _slot_name("alpha") + " EYES - raw (pre-brain)"
		if is_instance_valid(pip_beta_label):
			pip_beta_label.text = _slot_name("beta") + " EYES - raw (pre-brain)"
	elif brain:
		if is_instance_valid(pip_alpha_label):
			pip_alpha_label.text = _slot_name("alpha") + " BRAIN 3D"
		if is_instance_valid(pip_beta_label):
			pip_beta_label.text = _slot_name("beta") + " BRAIN 3D"
	# Clouds: forced on in BRAIN mode, canonical layer visibility else.
	if brain:
		if is_instance_valid(bv_cloud_alpha):
			bv_cloud_alpha.visible = true
		if is_instance_valid(bv_cloud_beta):
			bv_cloud_beta.visible = true
	else:
		_apply_bv_layer(str(_director().brainview_layer) if _director() != null else "bars")


static func _motor_debug_text(ctrl: Dictionary, spike_rate: float, silent_n: int) -> String:
	# Pure builder for the MOTORS card text: command values with a sign
	# legend (+yaw=right, +pitch=climb, +roll=bank-right), spike rate,
	# and the silence badge once the quiet streak passes the threshold.
	# Unit-tested.
	var t := float(ctrl.get("thrust", 0.0))
	var y := float(ctrl.get("yaw_torque", 0.0))
	var p := float(ctrl.get("pitch_torque", 0.0))
	var r := float(ctrl.get("roll_torque", 0.0))
	var sp := float(ctrl.get("spear_thrust", 0.0))
	var ram := float(ctrl.get("ram_drive", 0.0))
	var ev := "EVADE" if bool(ctrl.get("emergency_evade", false)) else "-"
	var yd := "R" if y > 0.05 else ("L" if y < -0.05 else "")
	var text := "THR %.2f   SPK %.0f/s\nYAW %+.2f%s\nPITCH %+.2f\nROLL %+.2f\nSPEAR %.2f RAM %.1f %s\nY+:right P+:climb R+:bankR" % [
		t, spike_rate, y, yd, p, r, sp, ram, ev]
	if silent_n >= MOTOR_SILENT_REPLIES:
		text += "\nSILENT (reflex only)"
	return text


func _set_motor_bars(bars: Array, ctrl: Dictionary) -> void:
	# Pushes the latest command into the 4 bipolar meters (thrust 0..1,
	# yaw/pitch/roll -1..+1). Guards the build order.
	if bars.size() < 4:
		return
	var vals := [float(ctrl.get("thrust", 0.0)),
		float(ctrl.get("yaw_torque", 0.0)),
		float(ctrl.get("pitch_torque", 0.0)),
		float(ctrl.get("roll_torque", 0.0))]
	for i in range(4):
		var bar = bars[i]
		if is_instance_valid(bar):
			(bar as ProgressBar).value = clampf(vals[i],
				0.0 if i == 0 else -1.0, 1.0)


func _on_motor_trace_draw(side: String) -> void:
	# Scrolling command traces: thrust 0..1 (top-down) + yaw/pitch/roll
	# -1..+1 around the zero line, over the last MOTOR_TRACE_MAX
	# replies. Drawn only while the MOTORS slot shows the canvas.
	var trace_ctl: Control = pip_motor_trace_alpha if side == "alpha" else pip_motor_trace_beta
	if not is_instance_valid(trace_ctl):
		return
	var buf: Array = _motor_trace_alpha if side == "alpha" else _motor_trace_beta
	var w := trace_ctl.size.x
	var h := trace_ctl.size.y
	if w <= 0.0 or h <= 0.0 or buf.is_empty():
		return
	trace_ctl.draw_line(Vector2(0, h * 0.5), Vector2(w, h * 0.5),
		Color(1, 1, 1, 0.25))
	var cols := {"t": Color(0.45, 0.85, 0.5), "y": Color(1, 1, 1),
		"p": Color(1.0, 0.85, 0.3), "r": Color(0.35, 0.85, 1.0)}
	var n := buf.size()
	for key in ["t", "y", "p", "r"]:
		var pts := PackedVector2Array()
		for i in range(n):
			var v := float((buf[i] as Dictionary).get(key, 0.0))
			var yn := h - (v * h) if key == "t" else h * 0.5 - (v * h * 0.5)
			pts.append(Vector2(w * float(i) / float(maxi(n - 1, 1)),
				clampf(yn, 0.0, h)))
		if pts.size() > 1:
			trace_ctl.draw_polyline(pts, cols[key], 1.0)


func _push_motor_sample(side: String, ctrl: Dictionary, st: Dictionary) -> void:
	# Per-reply motor telemetry: command snapshot onto the trace ring,
	# silence streak + spike EMA for the badge/readout. A few floats
	# per reply - always on, drawing gated on MOTORS visibility.
	var trace: Array = _motor_trace_alpha if side == "alpha" else _motor_trace_beta
	trace.append({"t": float(ctrl.get("thrust", 0.0)),
		"y": float(ctrl.get("yaw_torque", 0.0)),
		"p": float(ctrl.get("pitch_torque", 0.0)),
		"r": float(ctrl.get("roll_torque", 0.0))})
	while trace.size() > MOTOR_TRACE_MAX:
		trace.pop_front()
	var spikes := int(st.get("spikes", 0))
	if side == "alpha":
		_motor_spike_ema_alpha = lerpf(_motor_spike_ema_alpha, float(spikes), 0.35)
		if spikes == 0:
			_motor_silent_alpha += 1
			if _motor_silent_alpha == MOTOR_SILENT_REPLIES \
					and is_instance_valid(status_label):
				status_label.text = "%s BRAIN SILENT (reflex only)" % _slot_name("alpha")
		else:
			_motor_silent_alpha = 0
	else:
		_motor_spike_ema_beta = lerpf(_motor_spike_ema_beta, float(spikes), 0.35)
		if spikes == 0:
			_motor_silent_beta += 1
			if _motor_silent_beta == MOTOR_SILENT_REPLIES \
					and is_instance_valid(status_label):
				status_label.text = "%s BRAIN SILENT (reflex only)" % _slot_name("beta")
		else:
			_motor_silent_beta = 0


func _update_motor_cards() -> void:
	# MOTORS slot refresh (10 Hz tick): debug text + bar values +
	# trace redraw per side. Silence badge state lives in the text.
	# Reply-rate guard mirrors _update_ctrl_label (no replies yet ->
	# 0 Hz, never an exploded rate).
	var hz := 0.0
	if bv_reply_ema > 0.001:
		hz = 1.0 / bv_reply_ema
	for side in ["alpha", "beta"]:
		var ctrl: Dictionary = _last_ctrl_a if side == "alpha" else _last_ctrl_b
		var ema := _motor_spike_ema_alpha if side == "alpha" else _motor_spike_ema_beta
		var silent := _motor_silent_alpha if side == "alpha" else _motor_silent_beta
		var body: Label = pip_stats_alpha if side == "alpha" else pip_stats_beta
		if is_instance_valid(body):
			body.text = _motor_debug_text(ctrl, ema * hz, silent)
		_set_motor_bars(pip_motor_bars_alpha if side == "alpha" else pip_motor_bars_beta, ctrl)
		var trace: Control = pip_motor_trace_alpha if side == "alpha" else pip_motor_trace_beta
		if is_instance_valid(trace):
			trace.queue_redraw()


func _refresh_pip_cards() -> void:
	# Cheap label pump shared by the perf-on tick and the perf-off
	# path: stat/motor cards stay live even when eye renders are
	# disabled. Render updates live with the callers, never here.
	if pip_slot_mode == "STATS":
		for v in [pip_alpha_view, pip_beta_view]:
			if is_instance_valid(v):
				(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
		if is_instance_valid(pip_stats_alpha):
			pip_stats_alpha.text = _pip_stats_text("alpha")
		if is_instance_valid(pip_stats_beta):
			pip_stats_beta.text = _pip_stats_text("beta")
		if is_instance_valid(pip_name_alpha):
			pip_name_alpha.text = _slot_name("alpha")
		if is_instance_valid(pip_name_beta):
			pip_name_beta.text = _slot_name("beta")
	elif pip_slot_mode == "MOTORS":
		for v in [pip_alpha_view, pip_beta_view]:
			if is_instance_valid(v):
				(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
		_update_motor_cards()


func _update_pip_throttled(sens_a: Dictionary, sens_b: Dictionary) -> void:
	# Eye views re-render the whole forest per viewport (scene + shadow
	# maps, twice): throttle to every 6th physics tick (~10 Hz, plenty
	# for eye views). Renders-off hides the heavy nodes once; the label
	# cards keep refreshing on their normal schedule either way.
	_pip_tick += 1
	if not perf_pip:
		if not _pip_hidden:
			_pip_hidden = true
			for n in [pip_alpha_box, pip_beta_box, pip_alpha_label,
					pip_beta_label, pip_alpha_feat, pip_beta_feat]:
				if is_instance_valid(n):
					(n as Control).visible = false
		if _pip_tick % PIP_TICK_EVERY == 0:
			_refresh_pip_cards()
		return
	if _pip_hidden:
		_pip_hidden = false
		_apply_pip_slot()
	if _pip_tick % PIP_TICK_EVERY == 0:
		if pip_slot_mode == "STATS" or pip_slot_mode == "MOTORS":
			_refresh_pip_cards()
		elif pip_slot_mode == "BRAIN":
			for v in [pip_alpha_view, pip_beta_view]:
				if is_instance_valid(v):
					(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
			_park_pip_on_cloud(pip_alpha_cam, bv_cloud_alpha)
			_park_pip_on_cloud(pip_beta_cam, bv_cloud_beta)
			if is_instance_valid(bv_cloud_alpha):
				bv_cloud_alpha.visible = true
			if is_instance_valid(bv_cloud_beta):
				bv_cloud_beta.visible = true
		elif pip_slot_mode == "MOTORS":
			for v in [pip_alpha_view, pip_beta_view]:
				if is_instance_valid(v):
					(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
			_update_motor_cards()
		else:
			for v in [pip_alpha_view, pip_beta_view]:
				if is_instance_valid(v):
					(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
			_update_pip_view(pip_alpha_cam, fly_alpha, sens_a, pip_alpha_feat)
			_update_pip_view(pip_beta_cam, fly_beta, sens_b, pip_beta_feat)
	else:
		for v in [pip_alpha_view, pip_beta_view]:
			if is_instance_valid(v):
				(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED


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
	# Health bars written every tick (bar re-shape churn); wing labels
	# only rebuilt on change. Change-gated on rounded health (the bar
	# itself is continuous; 1-point granularity is the display).
	var ha := int(fly_alpha.health)
	var hb := int(fly_beta.health)
	if ha != _health_last_a or hb != _health_last_b:
		_health_last_a = ha
		_health_last_b = hb
		alpha_health_bar.value = fly_alpha.health
		beta_health_bar.value = fly_beta.health
	var wing_now := "%d%d%d%d" % [int(fly_alpha.left_wing_intact),
		int(fly_alpha.right_wing_intact), int(fly_beta.left_wing_intact),
		int(fly_beta.right_wing_intact)]
	if wing_now != _wing_last_state:
		_wing_last_state = wing_now
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
	# Round time + wins + control cadence move to a centered top
	# strip, clear of the side brain-view panels (reparented scene
	# labels, same nodes) - stacked vertically, one readout per row.
	var hud: CanvasLayer = $HUD
	var strip := VBoxContainer.new()
	strip.name = "MatchStrip"
	strip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	strip.offset_left = -320.0
	strip.offset_right = 320.0
	strip.offset_top = 56.0
	strip.offset_bottom = 170.0
	strip.alignment = BoxContainer.ALIGNMENT_CENTER
	strip.add_theme_constant_override("separation", 4)
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
	# "raster" until a pool is selected — then the raster takes its
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


static func pip_slot_next(cur: String) -> String:
	# Pure slot rotation (unknown states reset to EYES).
	var i := PIP_SLOT_MODES.find(cur)
	return PIP_SLOT_MODES[(i + 1) % PIP_SLOT_MODES.size()] if i >= 0 else "EYES"


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
		# Panels already up: advance the PiP slot instead (EYES ->
		# BRAIN 3D -> fly STATS -> MOTORS debug). Diagram layers still
		# cycle on N.
		pip_slot_mode = pip_slot_next(pip_slot_mode)
		_apply_pip_slot()
		if is_instance_valid(status_label):
			status_label.text = "PiP slot: %s (BRAIN cycles, N diagrams)" % pip_slot_mode


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

func _flash_stats_label(lbl: Label, tint: Color) -> void:
	# Strike flash for HUD labels: instant tint, fade back to white
	# over 0.4 s (same timing as the old half-screen flash). The tween
	# starts only inside the tree, so headless tests can drive the
	# routing (tint lands synchronously either way). One tween per
	# label (previous killed on re-flash), so a KO clear can stop the
	# fade dead instead of leaving it running.
	if not is_instance_valid(lbl):
		return
	var old: Tween = _label_flash_tween.get(lbl)
	if old != null and old.is_valid():
		old.kill()
	lbl.modulate = tint
	if lbl.is_inside_tree():
		var tw := lbl.create_tween()
		tw.tween_property(lbl, "modulate", Color.WHITE, 0.4)
		_label_flash_tween[lbl] = tw


func _flash_card_wash(side: String, strength: float) -> void:
	# Team-color wash over the whole stat-card area (the strike flash
	# the viewer actually sees). Fades over 0.4 s; new strikes restart
	# it (previous tween killed, so flashes never stack and a KO clear
	# can stop the fade dead).
	if side != "alpha" and side != "beta":
		return
	var rect: ColorRect = pip_flash_alpha if side == "alpha" else pip_flash_beta
	if not is_instance_valid(rect):
		return
	var old: Tween = _pip_wash_tween.get(side)
	if old != null and old.is_valid():
		old.kill()
	var team: Color = TEAM_ALPHA if side == "alpha" else TEAM_BETA
	rect.color = Color(team.r, team.g, team.b, strength)
	if rect.is_inside_tree():
		var tw := rect.create_tween()
		tw.tween_property(rect, "color:a", 0.0, 0.4)
		_pip_wash_tween[side] = tw


func _clear_fighter_card(side: String) -> void:
	# Stops a side's card flash dead: wash tween + label tint tweens
	# killed, wash alpha zeroed, labels back to white, body glow zeroed
	# (flash_hit is max-only, so the clear sets flash_energy directly).
	# The KO presentation calls this for the surviving attacker: only
	# the fly that got hurt keeps flashing.
	if side != "alpha" and side != "beta":
		return
	var rect: ColorRect = pip_flash_alpha if side == "alpha" else pip_flash_beta
	var old: Tween = _pip_wash_tween.get(side)
	if old != null and old.is_valid():
		old.kill()
	if is_instance_valid(rect):
		rect.color = Color(rect.color.r, rect.color.g, rect.color.b, 0.0)
	var nm: Label = pip_name_alpha if side == "alpha" else pip_name_beta
	var body: Label = pip_stats_alpha if side == "alpha" else pip_stats_beta
	var row: Label = alpha_row_name if side == "alpha" else beta_row_name
	for lbl in [nm, body, row]:
		if is_instance_valid(lbl):
			var lt: Tween = _label_flash_tween.get(lbl)
			if lt != null and lt.is_valid():
				lt.kill()
			lbl.modulate = Color.WHITE
	var fly = fly_alpha if side == "alpha" else fly_beta
	if is_instance_valid(fly):
		fly.set("flash_energy", 0.0)


func _flash_fighter_card(side: String, tint: Color, strength: float = 0.5) -> void:
	# Strike flash that never blocks the central view: the fighter's
	# stat card area washes in team color plus a text tint when
	# visible, else the always-visible health-row name tints.
	# Unknown sides no-op.
	if side != "alpha" and side != "beta":
		return
	var nm: Label = pip_name_alpha if side == "alpha" else pip_name_beta
	var body: Label = pip_stats_alpha if side == "alpha" else pip_stats_beta
	var flashed := false
	for lbl in [nm, body]:
		if is_instance_valid(lbl) and (lbl as Label).visible:
			_flash_stats_label(lbl, tint)
			flashed = true
	if flashed:
		_flash_card_wash(side, strength)
		return
	var row: Label = alpha_row_name if side == "alpha" else beta_row_name
	_flash_stats_label(row, tint)


func _hit_feedback(attacker_id: String, victim_id: String, part: String) -> void:
	_flash_fighter_card(victim_id, Color(1.0, 0.35, 0.35), 0.5)
	_flash_body(fly_alpha if victim_id == "alpha" else fly_beta, 1.0)
	_flash_fighter_card(attacker_id, Color(1.0, 0.95, 0.75), 0.22)
	_flash_body(fly_alpha if attacker_id == "alpha" else fly_beta, 0.6)
	var victim := fly_alpha if victim_id == "alpha" else fly_beta
	if is_instance_valid(victim):
		_fire_burst(hit_bursts.get(victim_id, null), victim.global_position)
	# Don't clobber the KO/win message if the wing-loss already ended the round.
	if is_instance_valid(status_label) and is_round_active:
		if part == "spike_clash":
			status_label.text = "SPIKE CLASH! " + _slot_name(attacker_id) + " AND " \
				+ _slot_name(victim_id) + " spike each other!"
		else:
			status_label.text = _slot_name(attacker_id) + " STRIKES " + _slot_name(victim_id) + " (" + part + ")!"
	# Sound the blow: clash tick, wing-tear rip, everything else a
	# body thump (unknown parts fall through to thump - callers need
	# no audio awareness).
	_play_sfx("clash" if part == "spike_clash" else ("tear" if part == "wing_tear" else "thump"))



# Combat readability FX: ground-projected health rings (in-world health
# bars with seizure/KO states + KO shockwave) and per-fly ember bursts
# for hits and KOs. Each fly bleeds its own team color (orange/blue),
# so mid-clash hits read instantly. Visual only; sim state untouched.
const TEAM_ALPHA := Color(1.0, 0.55, 0.30)
const TEAM_BETA := Color(0.4, 0.75, 1.0)
var ring_alpha: MeshInstance3D
var ring_beta: MeshInstance3D
var ring_mat_alpha: ShaderMaterial
var ring_mat_beta: ShaderMaterial
var ring_shock_alpha := 0.0
var ring_shock_beta := 0.0
var hit_bursts := {"alpha": null, "beta": null}
var ko_bursts := {"alpha": null, "beta": null}


func _ring_material(team: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://scripts/health_ring.gdshader")
	m.set_shader_parameter("team_color", Vector3(team.r, team.g, team.b))
	return m


func _build_combat_fx() -> void:
	ring_mat_alpha = _ring_material(TEAM_ALPHA)
	ring_mat_beta = _ring_material(TEAM_BETA)
	for slot in [["alpha", ring_mat_alpha], ["beta", ring_mat_beta]]:
		var quad := QuadMesh.new()
		quad.size = Vector2(4.4, 4.4)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = slot[1]
		mi.rotation_degrees.x = -90.0
		mi.position = Vector3(0, 0.06, 0)
		add_child(mi)
		if str(slot[0]) == "alpha":
			ring_alpha = mi
		else:
			ring_beta = mi
	hit_bursts["alpha"] = _make_burst(14, 0.07, TEAM_ALPHA)
	hit_bursts["beta"] = _make_burst(14, 0.07, TEAM_BETA)
	ko_bursts["alpha"] = _make_burst(42, 0.10, TEAM_ALPHA.lightened(0.2))
	ko_bursts["beta"] = _make_burst(42, 0.10, TEAM_BETA.lightened(0.2))


func _make_burst(amount: int, size: float, color: Color) -> GPUParticles3D:
	# Glowing ember sparks: tiny unshaded spheres need no textures and
	# stay crisp on the Mobile renderer.
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 0.9
	p.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 8.0
	pm.gravity = Vector3(0, -6, 0)
	pm.damping_min = 1.0
	pm.damping_max = 2.0
	p.process_material = pm
	var spark := SphereMesh.new()
	spark.radius = size
	spark.height = size * 2.0
	spark.radial_segments = 6
	spark.rings = 4
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_color = color
	spark.material = sm
	p.draw_pass_1 = spark
	add_child(p)
	return p


func _fire_burst(p: GPUParticles3D, pos: Vector3) -> void:
	if not is_instance_valid(p):
		return
	p.global_position = pos
	p.restart()


func _update_combat_fx(delta: float) -> void:
	for slot in [["alpha", fly_alpha, ring_alpha, ring_mat_alpha, "ring_shock_alpha"],
			["beta", fly_beta, ring_beta, ring_mat_beta, "ring_shock_beta"]]:
		var fly: CharacterBody3D = slot[1]
		var mi: MeshInstance3D = slot[2]
		var mat: ShaderMaterial = slot[3]
		if not is_instance_valid(fly) or mi == null or mat == null:
			continue
		mi.global_position = Vector3(fly.global_position.x, 0.06, fly.global_position.z)
		mat.set_shader_parameter("hp", clampf(float(fly.get("health")) / 100.0, 0.0, 1.0))
		mat.set_shader_parameter("seizing", 1.0 if bool(fly.get("seizing")) else 0.0)
		mat.set_shader_parameter("ko", 1.0 if bool(fly.get("is_disabled")) else 0.0)
		var key := str(slot[4])
		var sh := float(get(key))
		if sh > 0.0:
			sh += delta * 1.5
			if sh >= 1.0:
				sh = 0.0
			set(key, sh)
		mat.set_shader_parameter("shock", sh)


func _build_vignette() -> void:
	# Cinematic frame: layer 0 sits under the HUD CanvasLayer (layer 1)
	# and above the 3D view, so labels and overlays stay undarkened.
	var layer := CanvasLayer.new()
	layer.layer = 0
	layer.name = "VignetteLayer"
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var smat := ShaderMaterial.new()
	smat.shader = preload("res://scripts/vignette.gdshader")
	rect.material = smat
	layer.add_child(rect)


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
	winner_label.custom_minimum_size = Vector2(1100, 0)
	winner_label.add_theme_font_size_override("font_size", CALLOUT_TITLE_FS)
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

static var _RX_MATCH: RegEx = null
static var _RX_BATTLE: RegEx = null


static func expand_match_label(code: String) -> String:
	# "R1M1" -> "Round 1, Match 1". Anything else (FREE, "", junk)
	# passes through untouched. Display only: wire ids, server keys,
	# logs and retry matching keep the compact form. RegEx compiled
	# once (called per status update / report / retry).
	if _RX_MATCH == null:
		_RX_MATCH = RegEx.new()
		_RX_MATCH.compile("^R(\\d+)M(\\d+)$")
	var m := _RX_MATCH.search(code.strip_edges())
	if m == null:
		return code
	return "Round %s, Match %s" % [m.get_string(1), m.get_string(2)]


static func expand_battle_id(code: String) -> String:
	# "R1M1-B1[-<msec>-<rand>]" -> "Round 1, Match 1, Battle 1".
	# Display only: the report nonce (uniqueness) strips here.
	if _RX_BATTLE == null:
		_RX_BATTLE = RegEx.new()
		_RX_BATTLE.compile("^(.*)-B(\\d+)(?:-\\d+-\\d+)?$")
	var m := _RX_BATTLE.search(code.strip_edges())
	if m == null:
		return expand_match_label(code)
	var inner := expand_match_label(m.get_string(1))
	if inner == "":
		return "Battle %s" % m.get_string(2)
	return "%s, Battle %s" % [inner, m.get_string(2)]


func _current_battle_id() -> String:
	# Globally unique per report: base R1M1-B7 plus msec + random nonce,
	# so group A's R1M1-B7 and group C's R1M1-B7 (or a QUIT+RESUME
	# replay) never share an id string. Retries resend the STORED id
	# (exact resend -> server dedups); a genuinely new report for the
	# same battle slot replays via the base triple (tournament, match,
	# base) server-side instead of double-banking. Display strips the
	# nonce (expand_battle_id); matcher compares full strings.
	return "%s-B%d-%d-%d" % [tourney_match_label, _battle_count() + 1,
		Time.get_ticks_msec(), randi() % 100000]

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

# -- Sound: clip-pack announcer + procedural battle SFX ------------
# The announcer is 14 pre-recorded voice clips (fixed orange/blue
# phrases, no names) under res://audio/voice: zero runtime synthesis,
# zero network, zero deadlock class (the Oct 2026 SAPI freeze is
# architecturally gone - local WAV playback cannot block). SFX are
# synthesized once at boot into AudioStreamWAV buffers. Render path
# untouched: buffers build once, playback engine-mixed, zero
# per-frame GDScript cost. To re-voice the pack, replace the WAVs
# (same names, mono) - no code changes.
const SFX_POOL := 4 # overlapping one-shot players (strike + KO +
	# beeps can coincide). Raise to 6 if fast exchanges audibly cut
	# each other; lower to 2 on thin audio drivers.
const SFX_GAIN_DB := -6.0 # master trim for all effects; per-effect
	# balance lives in the SfxSynth recipes, not here.
const VOICE_DIR := "res://audio/voice"
const VOICE_GAIN_DB := -3.0 # voice sits above the effects; trim here.
# Every announcer clip. Single source of truth: boot preloads exactly
# these, and the sound suite asserts each resolves to a real file.
const VOICE_CLIPS := ["knockout_orange", "knockout_blue",
	"battle_orange", "battle_blue", "match_orange", "match_blue",
	"exhibition_orange", "exhibition_blue", "exhibition",
	"champion_orange", "champion_blue", "champion",
	"event_champion", "generation_champion"]
# Preloaded (not class_name-referenced): a fresh script has no global
# class cache entry yet, and cache state varies per machine - preload
# resolves deterministically everywhere, including headless suites.
const SfxSynthLib = preload("res://scripts/SfxSynth.gd")
var _voice_on := true
var _sfx_on := true
var _sfx_palette := "classic" # SfxSynth.PALETTES; persisted [audio].
# Master mute (M key / MUTE button): overrides both toggles without
# destroying them - unmute restores voice/sfx exactly. Session-only,
# never persisted: boot always starts from the menu toggles, so a
# forgotten mute cannot mysteriously survive a restart.
var _sound_muted := false
var mute_button: Button
var _sfx_players: Array = []
var _sfx_streams := {}
var _voice_player: AudioStreamPlayer
var _voice_clips := {}


func _init_sound() -> void:
	# Boot wiring (called from _apply_beauty_pass, same place perf
	# video flags load). Order matters: toggles first (menu
	# persisted), then voice pack, then synth.
	var director := _director()
	if director != null and director.has_method("perf_get"):
		_voice_on = bool(director.call("perf_get", "voice"))
		_sfx_on = bool(director.call("perf_get", "sfx"))
	if director != null and director.has_method("audio_opt_get"):
		_sfx_palette = str(director.call("audio_opt_get", "sfx_palette", "classic"))
	_build_voice()
	_build_sfx()


func _set_muted(muted: bool) -> void:
	# Master mute flip: stops every player NOW (the current boom/line
	# cuts, not just future ones), updates the button, posts status.
	_sound_muted = muted
	if muted:
		for p in _sfx_players:
			if is_instance_valid(p):
				(p as AudioStreamPlayer).stop()
		if is_instance_valid(_voice_player):
			_voice_player.stop()
	if is_instance_valid(mute_button):
		mute_button.text = "UNMUTE" if muted else "MUTE"
	if is_instance_valid(status_label):
		status_label.text = "SOUND MUTED (M to unmute)" if muted else "SOUND ON"


func _on_mute_button() -> void:
	_set_muted(not _sound_muted)


func _build_voice() -> void:
	# Preload the whole clip pack at boot (~1 MB). Missing files log
	# and skip - a partial pack still announces what it has, never
	# crashes. Idempotent like _build_sfx (frees the old player first).
	if is_instance_valid(_voice_player):
		_voice_player.stop()
		(_voice_player as Node).queue_free()
	_voice_clips.clear()
	for key in VOICE_CLIPS:
		var stream := AudioStreamWAV.load_from_file("%s/%s.wav" % [VOICE_DIR, key])
		if stream == null:
			_arena_log("voice clip missing at boot: %s/%s.wav" % [VOICE_DIR, key])
			continue
		_voice_clips[key] = stream
	_voice_player = AudioStreamPlayer.new()
	_voice_player.volume_db = VOICE_GAIN_DB
	add_child(_voice_player)


func _announce_clip(clip: String) -> void:
	# Single announcer entry point: fixed-phrase clip pack, never live
	# synthesis. Latest wins via stop+play; a missing clip logs and
	# skips, never crashes. Errors and stalls stay visual-only by
	# policy: never announce them. To silence a single call site,
	# delete its call (never add per-site flags).
	if not _voice_on or _sound_muted:
		return
	if not _voice_clips.has(clip):
		_arena_log("announce clip missing: %s" % clip)
		return
	_arena_log("announce: %s" % clip)
	if is_instance_valid(_voice_player):
		_voice_player.stop()
		_voice_player.stream = _voice_clips[clip]
		_voice_player.play()


func _build_sfx() -> void:
	# (Re)builds every effect buffer from the active SfxSynth palette
	# plus a fresh player pool. Idempotent: frees the old pool first
	# so palette switches and test rebuilds never stack players.
	for p in _sfx_players:
		if is_instance_valid(p):
			(p as AudioStreamPlayer).stop()
			(p as Node).queue_free()
	_sfx_players.clear()
	_sfx_streams = SfxSynthLib.build(_sfx_palette)
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		p.volume_db = SFX_GAIN_DB
		add_child(p)
		_sfx_players.append(p)


func _play_sfx(sfx_name: String) -> void:
	# First free player wins; all busy = drop (a dropped blip beats a
	# cut-off boom). Unknown names no-op - callers need no guards.
	# Master mute silences here (toggle state untouched underneath).
	if not _sfx_on or _sound_muted or not _sfx_streams.has(sfx_name):
		return
	var stream: AudioStreamWAV = _sfx_streams[sfx_name]
	for p in _sfx_players:
		if not (p as AudioStreamPlayer).playing:
			(p as AudioStreamPlayer).stream = stream
			(p as AudioStreamPlayer).play()
			return


func _show_callout(title: String, title_color: Color, sub: String, countdown_prefix: String, auto_reset: bool) -> void:
	# Centered callout (win, draw, restart) with a 3-2-1 countdown. When
	# auto_reset is false the caller sequences the next step itself
	# (tournament battles wait for the server's match_reset instead).
	# Restore winner-callout sizes (loading states shrink them).
	if is_instance_valid(winner_label):
		winner_label.text = title
		winner_label.add_theme_font_size_override("font_size", CALLOUT_TITLE_FS)
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

	# Informational banners (empty prefix: GROUP COMPLETE, CHAMPION,
	# quick-battle) hold statically - only a real next step counts
	# down. An empty prefix used to play a phantom " IN 3... FIGHT!"
	# over the incoming bracket view.
	if countdown_prefix != "":
		for i in range(3, 0, -1):
			if is_instance_valid(countdown_label):
				countdown_label.text = "%s IN %d..." % [countdown_prefix, i]
			_play_sfx("beep")
			await get_tree().create_timer(1.0).timeout

		if is_instance_valid(countdown_label):
			countdown_label.text = "FIGHT!"
		_play_sfx("fight")
		await get_tree().create_timer(0.8).timeout
	else:
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
	# retry. Timeout winners arrive decided (_time_winner); legacy
	# undecided timeouts keep the empty slot and the old line.
	var v := {"end_reason": "draw" if draw else _end_reason,
		"winner_slot": "", "loser_slot": "", "blow_source": "",
		"blow_amount": 0.0, "time_left": maxf(current_round_time, 0.0),
		"dmg_a": float(stats_alpha.get("damage_dealt", 0.0)),
		"dmg_b": float(stats_beta.get("damage_dealt", 0.0)), "line": ""}
	if draw:
		v["line"] = "DNF - time expired, nobody bled (%.1f m / %.1f m off arena)" % [
			float((stats_alpha as Dictionary).get("center_drift", 0.0)),
			float((stats_beta as Dictionary).get("center_drift", 0.0))]
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
		if _time_winner == "alpha" or _time_winner == "beta":
			v["winner_slot"] = _time_winner
			v["loser_slot"] = "beta" if _time_winner == "alpha" else "alpha"
			v["line"] = "TIME - %s wins on health (damage %.0f-%.0f)" % [
				_slot_name(_time_winner), v["dmg_a"], v["dmg_b"]]
		else:
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
	# Numbered DNFs (did-not-finish timeout ties): the banked count
	# doesn't include the latest one yet, so +1 (a third DNF resolves
	# the match instead of replaying).
	var director := _director()
	var draws := 0
	if director != null:
		draws = int(director.current_match().get("draws", 0))
	return "DNF" if draws + 1 <= 1 else "DNF x%d" % (draws + 1)


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
		var twinner := str(_last_verdict.get("winner_slot", ""))
		if twinner == "alpha" or twinner == "beta":
			return {"text": "%s WINS ON HEALTH" % _slot_name(twinner),
				"sub": "Damage %.0f-%.0f" % [float(_last_verdict.get("dmg_a", 0.0)),
					float(_last_verdict.get("dmg_b", 0.0))],
				"color": Color(1.0, 0.55, 0.3) if twinner == "alpha" else Color(0.4, 0.75, 1.0)}
		return {"text": "TIME - SERVER DECIDES",
			"sub": "Damage %.0f-%.0f" % [float(_last_verdict.get("dmg_a", 0.0)),
				float(_last_verdict.get("dmg_b", 0.0))],
			"color": Color(0.78, 0.78, 0.85)}
	return {"text": _draw_title(),
		"sub": "Did not finish - nobody bled",
		"color": Color(0.78, 0.78, 0.82)}


func _report_battle(draw: bool, draw_penalty: bool = false) -> void:
	# Single choke point for tournament battle reports: stamps the same
	# (tournament, match, battle) id used as the server's idempotency key,
	# keeps a copy for one safe retry, and arms the battle watchdog.
	# draw_penalty marks a 3rd draw so the server docks both ELOs.
	_seq_battle_id = _current_battle_id()
	_tourney_awaiting_battle = true
	_seq_forgive_match = {"tournament_id": _tourney_id(),
		"match": tourney_match_label, "battle": _seq_battle_id}
	var fa := _flight_summary(flight_alpha, fly_alpha)
	var fb := _flight_summary(flight_beta, fly_beta)
	_last_verdict = _compose_verdict(draw)
	_seq_last_round = {
		"stats_a": stats_alpha.duplicate(), "stats_b": stats_beta.duplicate(),
		"draw": draw, "draw_penalty": draw_penalty,
		"tournament_id": _tourney_id(), "match": tourney_match_label,
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
	# reporting detail sits beneath in smaller type. Shown squeezed
	# into the bracket (same strings/colors); fullscreen only when no
	# bracket can render.
	var head := _verdict_headline()
	var head_text := str(head.get("text", ""))
	var head_sub := "%s\n%s - battle %s sent, waiting for server..." % [
		str(head.get("sub", "")), expand_match_label(tourney_match_label), expand_battle_id(_seq_battle_id)]
	var head_color: Color = head.get("color", Color(0.85, 0.85, 0.9))
	# Live-card preview: the just-decided winner reads on its bracket
	# card during the report wait (draws bank nothing - skip them).
	if not draw and is_instance_valid(arena_bracket):
		var pslot := str(_last_verdict.get("winner_slot", ""))
		if pslot == "alpha" or pslot == "beta":
			var rdir := _director()
			if rdir != null:
				arena_bracket.live_preview = {"round": int(rdir.tourney.get("current_round", 0)),
					"match": int(rdir.tourney.get("current_match", 0)),
					"winner_slot": pslot}
	if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
		_set_wait_header(head_text, head_sub, head_color)
	else:
		_show_loading(head_text, head_sub, head_color)
	if is_instance_valid(status_label):
		status_label.text = "%s - %s (%s REPORTING)" % [
			str(head.get("text", "")), str(head.get("sub", "")),
			expand_match_label(tourney_match_label)]

func _handle_draw() -> void:
	# Wander reading (positions valid until landing below): meters
	# past the arena ring per fly, gated on separation (a chase out
	# past the ring is engagement, not wandering). Rides stats_alpha/
	# beta to the server (career wander mark) and into the match record
	# (the overtime health dock reads the freshest pair).
	var drift_a := _wander_overshoot(fly_alpha)
	var drift_b := _wander_overshoot(fly_beta)
	var gated := _gate_drift(drift_a, drift_b, _flat_separation())
	drift_a = float(gated[0])
	drift_b = float(gated[1])
	stats_alpha["center_drift"] = drift_a
	stats_beta["center_drift"] = drift_b
	print("[Arena] DNF! Time expired with zero damage - did not finish, rematch same brains. (drift A %.1f m / B %.1f m past arena)" % [drift_a, drift_b])
	is_round_active = false
	_set_combat(false)
	# Both walk away: land upright for the rematch.
	_begin_landing("")
	if tournament_active:
		# Batched match reporting: cache this draw and continue locally
		# (_battle_done_local -> _battle_post_sequence); the draw banks
		# with the rest of the match at match over. A draw reported
		# while two are already banked is the 3rd: flag it so the
		# server docks both ELOs for stalling the match out.
		var third := false
		var director := _director()
		if director != null:
			third = int(director.current_match().get("draws", 0)) >= 2
		_battle_done_local(true, third)
		return
	_show_winner_and_countdown(
		"DNF",
		Color(0.78, 0.78, 0.82),
		"TIME UP - NOBODY BLED - REMATCH",
		"REMATCH")

# ── Dynamic tree fade ──────────────────────────────────────────────────
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
	# the bottom-left status line. No-ops unless evo is active. New
	# worker spawns wait for open air between battles (process boot
	# spikes frame pacing); adoptions run any time.
	var wdirector := _director()
	if wdirector != null:
		# Queue pumps (trains/scores) only boot workers in open air,
		# in every arena mode; the flag clears itself here every tick
		# batch, plus on quit. Evo breeds pipeline independently.
		wdirector.hold_spawns = is_round_active
		wdirector.pump_train_queue()
		wdirector.pump_score_queue()
	if not _evo_active():
		if is_instance_valid(evo_status_line):
			evo_status_line.visible = false
		return
	_evo_adopt_finished()
	var director := _director()
	if director != null and not evo_waiting and director.pending_async.is_empty() \
			and not is_round_active:
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
	if _event_active():
		_event_drain_done_to_pool()
		_event_maintain_pool()
		_event_topup_tick()
	_update_evo_status_line()


func _event_topup_tick() -> void:
	# Automatic top-up trainer: when the TRAINING slot is idle, school
	# the least-trained bench brain toward POOL_TRAIN_TARGET (own
	# stored wiring/rates + school curriculum, same as a menu school
	# retrain). Throttled to every 30 s. Breeds (pending_async) and
	# score probes (score_job) no longer gate it: they are separate
	# workers on isolated cores (affinity + BelowNormal + single-thread
	# BLAS), so schooling runs parallel to them and to live battles —
	# the old all-slots-idle gate starved the bench for entire events
	# whenever a breed was running. Boot spikes stay fenced by
	# hold_spawns in the pump; running workers are never touched. The
	# queue naturally rotates through the bench as each graduate
	# outgrows the bottom slot.
	if not _event_active():
		return
	_event_topup_cd += EVO_STATUS_EVERY
	if _event_topup_cd < EVENT_TOPUP_EVERY:
		return
	var director := _director()
	if director == null:
		return
	_event_topup_cd = 0.0
	if not (director.train_queue as Array).is_empty():
		return
	if not (director.active_job as Dictionary).is_empty():
		return
	var pick: Dictionary = director.event_topup_pick(_event_id(), POOL_TRAIN_TARGET)
	if not bool(pick.get("ok", false)):
		return
	var worst := str(pick.get("id", ""))
	var worst_eps := int(pick.get("episodes", 0))
	var deficit := int(pick.get("deficit", 0))
	var worst_rec := {}
	for b in director.list_brains_cached():
		if str((b as Dictionary).get("id", "")) == worst:
			worst_rec = b as Dictionary
			break
	if (worst_rec as Dictionary).is_empty():
		return
	var gp: Dictionary = (worst_rec as Dictionary).get("generator_params", {})
	var params := {}
	for k in ["variant", "seed", "learning_rate", "dist_gain", "evasion",
			"align_bonus", "experiment", "genome", "genome_id",
			"mapping", "yaw_bias"]:
		if gp.has(k):
			params[k] = gp[k]
	params["curriculum"] = {}
	director.enqueue_training(worst, str(worst_rec.get("name", "?")), deficit, params)
	director.pump_train_queue()
	print("[Arena] Event top-up: schooling %s +%d eps (had %d)" % [
		str(worst_rec.get("name", "?")), deficit, worst_eps])


func _train_queue_parts(queue: Array, job: Dictionary, done: Array,
		ep: int, total: int) -> Array:
	# Pure builder for the training half of the EVO status line: active
	# job, queue head (+N overflow), most recent DONE. Narrow caps keep
	# the joined line inside its 800 px band.
	var out: Array = []
	if not job.is_empty():
		var aname := str(job.get("name", job.get("brain_id", "?")))
		if ep >= 0 and total > 0:
			out.append("TRAIN %s %d/%d" % [aname.left(14), ep, total])
		else:
			out.append("TRAIN %s warming up" % aname.left(14))
	if not queue.is_empty():
		var head: Dictionary = queue[0] if queue[0] is Dictionary else {}
		var qp := "QUEUED %s" % str(head.get("name", "?")).left(14)
		if queue.size() > 1:
			qp += " +%d" % (queue.size() - 1)
		out.append(qp)
	if not done.is_empty():
		var last := done[done.size() - 1] as Dictionary
		if last != null and not last.is_empty():
			out.append("DONE %s +%dep" % [str(last.get("name", "?")).left(14),
				int(last.get("episodes", 0))])
	return out


func _on_train_progress(ep: int, total: int) -> void:
	# Instant half of the training HUD: progress bar + last-known
	# counts (the text line refreshes immediately - 4 Hz max, same cost
	# class as the menu's job_bar).
	_train_prog_ep = ep
	_train_prog_total = total
	if is_instance_valid(train_prog_bar):
		train_prog_bar.max_value = maxi(1, total)
		train_prog_bar.value = ep
		train_prog_bar.visible = true
	_update_evo_status_line()


func _on_train_queue_changed() -> void:
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
	# Fresh job (or none): drop stale counts from the previous one so a
	# new train reads "warming up" instead of the old ep/total.
	var job_id := str(director.active_job.get("brain_id", ""))
	if job_id != _train_prog_job:
		_train_prog_job = job_id
		_train_prog_ep = -1
		_train_prog_total = -1
		if is_instance_valid(train_prog_bar):
			train_prog_bar.value = 0.0
	# Visibility sweep on ground truth: a crashed job never emits its
	# final progress, so the 5 s tick clears a bar the handler left up.
	if is_instance_valid(train_prog_bar):
		train_prog_bar.visible = not director.active_job.is_empty()
	# The awaited spec is detached from pending: without the fallback
	# this line flatlines for the whole (long) await, same as the strip.
	for spec in _evo_pending() + [evo_await_spec]:
		var s := spec as Dictionary
		if s.is_empty():
			continue
		var label := str(s.get("name", ""))
		if label == "":
			label = "wild"
		var smode := str(s.get("mode", ""))
		if smode != "":
			label += " [%s]" % smode
		if bool(s.get("launched", false)):
			var prog := _evo_poll_file(str(s.get("progress", "")))
			if prog.is_empty():
				parts.append("%s warming up" % label)
			else:
				parts.append("%s ep %d/%d" % [label,
					int(prog.get("episode", 0)), int(_prog_total(prog))])
		else:
			parts.append("%s queued" % label)
	for kind in (evo.get("done", {}) as Dictionary).keys():
		parts.append("%s done" % _evo_done_name(str(kind)))
	parts.append_array(_train_queue_parts(director.train_queue,
		director.active_job, director.completed_trains,
		_train_prog_ep, _train_prog_total))
	if parts.is_empty():
		evo_status_line.visible = false
		return
	evo_status_line.text = "CONTINUOUS G%d • %s" % [gen, " • ".join(parts)]
	evo_status_line.visible = true


var _shot_path := ""
var _shot_frames := 0
var _shot_done := false
var _shot_scanned := false
var _timer_last_tenths := -1
var _health_last_a := -1
var _health_last_b := -1
var _wing_last_state := ""


const HITCH_SECS := 0.15
func _log_hitch(delta: float) -> void:
	# Frame-spike census: slow frames log which tracked workers were
	# alive, so hitch reports point at CPU contention (or exonerate
	# it toward GPU). Fires rarely by construction.
	if delta < HITCH_SECS:
		return
	var director := _director()
	var busy := PackedStringArray()
	if director != null:
		for slot in ["active_job", "score_job", "pending_async"]:
			var job = director.get(slot)
			if job is Dictionary and not (job as Dictionary).is_empty():
				var pid := int((job as Dictionary).get("pid", 0))
				var alive := pid > 0 and OS.is_process_running(pid)
				busy.append("%s:%d(%s)" % [slot, pid, "alive" if alive else "gone"])
	print("[Arena] Frame hitch %.0f ms (tracked workers: %s)" % [
		delta * 1000.0, ", ".join(busy) if not busy.is_empty() else "none"])


func _process(delta: float) -> void:
	_log_hitch(delta)
	_update_combat_fx(delta)
	# Dev screenshot hook: `--shot=C:/path/out.png` saves one viewport
	# frame ~1 s after boot. Untouched in normal runs. Cmdline scanned
	# once (per-frame user-args scans were churn).
	if not _shot_done:
		if _shot_path == "" and not _shot_scanned:
			_shot_scanned = true
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
	# Next-gen waiting room ticks (gallery rotation + training strip).
	if nextgen_visible or _event_gallery_active:
		nextgen_gallery_tick += delta
		if nextgen_gallery_tick >= NEXTGEN_GALLERY_EVERY:
			nextgen_gallery_tick = 0.0
			_gallery_advance()
	if nextgen_visible:
		nextgen_strip_tick += delta
		if nextgen_strip_tick >= NEXTGEN_STRIP_EVERY:
			nextgen_strip_tick = 0.0
			_update_nextgen_strip()
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
		# Skip the material writes at rest (per-frame lerpf writes on
		# ~40 materials were churn when nothing moves).
		if absf((entry["trunk_mats"][0] as StandardMaterial3D).albedo_color.a - target) < 0.003 \
				and absf((entry["canopy_mats"][0] as StandardMaterial3D).albedo_color.a - target) < 0.003:
			continue
		for tm in entry["trunk_mats"]:
			(tm as StandardMaterial3D).albedo_color.a = lerpf((tm as StandardMaterial3D).albedo_color.a, target, k)
		for cm in entry["canopy_mats"]:
			(cm as StandardMaterial3D).albedo_color.a = lerpf((cm as StandardMaterial3D).albedo_color.a, target, k)

# ──────────────────────────────────────────────────────────────────

func _update_ctrl_label() -> void:
	if not is_instance_valid(ctrl_label):
		return
	var hz := 0.0
	if bv_reply_ema > 0.001:
		hz = 1.0 / bv_reply_ema
	# HUD shows applied pairs (n) vs server-integrated steps (srv):
	# srv - n == replies lost in flight. To shorten this label, drop
	# srv (keep n + t); srv stays in the flight log line regardless.
	ctrl_label.text = "CTRL %.1fHz n=%d srv=%d t%.2f" % [hz, _ctrl_n, _ctrl_srv_seq, bv_shared_tau]


func _on_motor_controls(ctrl_alpha: Dictionary, ctrl_beta: Dictionary, gen: int, stats: Dictionary = {}) -> void:
	# A reply landed: the link is free for the next step. Cleared
	# first (before any application below) so a slow frame can never
	# leave the flag set past the reply that frees it.
	_step_in_flight = false
	_step_timeouts = 0
	# Cumulative control pairs applied (both sides per reply, by
	# construction - a single reply carries both dicts, so per-side
	# counters could never diverge; what CAN diverge is applied (n)
	# vs server-integrated (srv) when a reply is lost). Reset policy:
	# cumulative per session to match the server's cumulative
	# step_count; do NOT reset per round or srv-n drifts by the
	# round's step count.
	_ctrl_n += 1
	_ctrl_srv_seq = int(stats.get("step_seq", 0))
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
	# Dopamine-replay inputs: the reply's ctrl dicts are exactly what
	# the server used to capture per battle (last_ctrl); storing refs
	# here is one assignment per reply, no copies.
	_last_ctrl_a = ctrl_alpha
	_last_ctrl_b = ctrl_beta
	_push_motor_sample("alpha", ctrl_alpha, stats.get("alpha", {}))
	_push_motor_sample("beta", ctrl_beta, stats.get("beta", {}))
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
	# n/srv are session link totals (not per-round): the post-hoc
	# link-quality record for this battle's control pairing.
	print("[Arena] Flight %s: alt mean %.1f [%.1f-%.1f] thrust %.2f pitch %+.3f yaw|.| %.3f evade %.1f%% ram %.1f%% spear_max %.2f lunges %d (%d samples) ctrl %.1fHz t%.3f n=%d srv=%d" % [
		slot, float(f.get("alt_mean", 0.0)), float(f.get("alt_min", 0.0)),
		float(f.get("alt_max", 0.0)), float(f.get("thrust_mean", 0.0)),
		float(f.get("pitch_mean", 0.0)), float(f.get("yaw_abs_mean", 0.0)),
		100.0 * float(f.get("evade_frac", 0.0)), 100.0 * float(f.get("ram_frac", 0.0)),
		float(f.get("spear_max", 0.0)), int(f.get("lunges", 0)), int(f.get("samples", 0)),
		float(f.get("ctrl_hz", 0.0)), float(f.get("tau", 0.0)), _ctrl_n, _ctrl_srv_seq])


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
	_flash_fighter_card(fly_id, Color(1.0, 0.3, 0.3), 0.6)
	_flash_body(fly_alpha if fly_id == "alpha" else fly_beta, 1.0)
	if is_instance_valid(status_label):
		status_label.text = _slot_name(fly_id) + " LOST " + side.to_upper() + " WING!"

func _on_fly_knocked_out(victim_id: String) -> void:
	if not is_round_active:
		return
	_end_reason = "ko"
	_ko_victim = victim_id

	# Draw the final state (health floor, torn wing) BEFORE the winner text.
	_update_health_hud()
	_flash_fighter_card(victim_id, Color(1.0, 0.25, 0.25), 0.75)
	_flash_body(fly_alpha if victim_id == "alpha" else fly_beta, 1.0)
	# Single-sided KO read: the killing strike's _hit_feedback already
	# flashed the attacker (cream wash + body glow). The KO shows ONLY
	# the fly that got hurt - the attacker's card flash and glow are
	# cleared dead here (tween killed, not left fading).
	_clear_fighter_card("beta" if victim_id == "alpha" else "alpha")
	var victim := fly_alpha if victim_id == "alpha" else fly_beta
	if is_instance_valid(victim):
		_fire_burst(ko_bursts.get(victim_id, null), victim.global_position)
		if victim_id == "alpha":
			ring_shock_alpha = 0.01
		else:
			ring_shock_beta = 0.01

	if victim_id == "alpha":
		stats_beta["kills"] += 1
		if is_instance_valid(status_label):
			status_label.text = _ko_text("beta")
	else:
		stats_alpha["kills"] += 1
		if is_instance_valid(status_label):
			status_label.text = _ko_text("alpha")
	# Sound the finish before the landing ceremony unfolds behind the
	# banner: cannon boom + fixed-phrase winner clip (scores and names
	# stay visual-only - the battle callout follows seconds later).
	_play_sfx("boom")
	var ko_winner := "beta" if victim_id == "alpha" else "alpha"
	_announce_clip("knockout_orange" if ko_winner == "alpha" else "knockout_blue")

	# Landing ceremony instead of a frozen frame: loser drops
	# belly-up, winner lowers onto its feet (runs behind the banner).
	_begin_landing("beta" if victim_id == "alpha" else "alpha")
	# Damage gates close now (no corpse hits during the replay), then
	# the slow-motion finish plays before the round is banked.
	_set_combat(false)
	await _play_slowmo_finish()
	_end_round()


func _play_slowmo_finish() -> void:
	# Quarter-speed beat on the final blow: clean fight view, landing
	# unfolding slowly. Restores, holds one real second, and returns;
	# the caller then banks the round and the winner text lands.
	# Re-entry safe (a second KO inside the window is a no-op wait).
	if _slowmo_active:
		return
	_slowmo_active = true
	Engine.time_scale = SLOWMO_SCALE
	await get_tree().create_timer(SLOWMO_SECS, true, false, true).timeout
	_restore_timescale()
	await get_tree().create_timer(WINNER_BEAT_SECS, true, false, true).timeout


func _restore_timescale() -> void:
	# Timescale is global: any early exit (quit, stop, new load) must
	# leave it at 1.0 or the whole game runs in slow motion.
	_slowmo_active = false
	Engine.time_scale = 1.0


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


func _set_combat(on: bool) -> void:
	# Opens/closes the flies' damage gate alongside the round flag.
	# Every is_round_active=false site below must call _set_combat(false)
	# or intermission clinches bleed into the next round's health bars.
	for fly in [fly_alpha, fly_beta]:
		if is_instance_valid(fly) and fly.has_method("set_combat_enabled"):
			fly.call("set_combat_enabled", on)


func _close_round_for_wait() -> void:
	# Bracket-countdown safety: every pre-battle wait view (tip-off,
	# resume, between groups, before the final, pool wait) opens with
	# the round CLOSED. The scene default is_round_active=true would
	# otherwise run the full round pipeline behind the countdown -
	# steps go out, the 0 s timer times out on the first tick, and a
	# phantom battle is reported before the official start.
	# brains_loaded -> _reset_round is the only official starter.
	is_round_active = false
	_set_combat(false)


func _end_round() -> void:
	is_round_active = false
	# Paced stepping ends with the round: a late reply after this
	# clears an already-false flag (harmless), and the next round
	# re-arms from clean state in _reset_round.
	_step_in_flight = false
	_set_combat(false)
	_check_speed_violations()
	print("[Arena] Round concluded! Sending battle stats to evolution engine...")
	if tournament_active:
		# Batched match reporting: cache this battle and run the
		# post-battle sequence locally - matches accumulate into the
		# round cache, and the whole round banks once at the round
		# boundary. No per-battle bank wait.
		_battle_done_local(false)
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

func _forgivable_reply(battle_id: String) -> bool:
	# True when a post-fail-loud reply is the still-owed battle (same
	# full nonce id, same tournament file, same match label, still in
	# a tournament): applying it heals a false-positive SERVER SILENT.
	# Pure (unit-tested).
	if _seq_forgive_match.is_empty():
		return false
	if battle_id != str(_seq_forgive_match.get("battle", "")):
		return false
	if str(_seq_forgive_match.get("tournament_id", "")) != _tourney_id():
		return false
	if str(_seq_forgive_match.get("match", "")) != tourney_match_label:
		return false
	return tournament_active


func _on_battle_progress(battle_id: String) -> void:
	# Server proof-of-life while banking: extend the deadline a full
	# window from each heartbeat instead of firing a duplicate report
	# that doubles the server's work. Stray ids never move it. In
	# roundbank context the server heartbeats the ROUND nonce (per
	# match stage) - matched against _seq_round_id, not battle ids.
	# Group banks heartbeat the GROUP nonce the same way.
	if _seq_context == "battle" and battle_id != "" \
			and battle_id == _seq_battle_id:
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("battle")
	elif _seq_context == "roundbank" and battle_id != "" \
			and battle_id == _seq_round_id:
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("roundbank")
	elif _seq_context == "groupbank" and battle_id != "" \
			and battle_id == _seq_group_id:
		_seq_deadline_msec = Time.get_ticks_msec() + _seq_timeout_for("groupbank")


func _on_tournament_battle(battle_winner: String, _fit_a: float, _fit_b: float, _battle_id: String) -> void:
	# (Retired for tournaments in batch mode: per-battle replies no
	# longer fire; kept as a safe fallback - unmatched echoes drop with
	# a log, matched echoes still apply the sequence.)
	if not _tourney_awaiting_battle:
		if _battle_id != "" and _forgivable_reply(_battle_id):
			print("[Arena] Forgiving late tournament_battle (id=",
				_battle_id, "): banked but unconfirmed, applying now.")
		else:
			print("[Arena] Ignoring late/duplicate tournament_battle (id=",
				_battle_id, ")")
			return
	var bdirector := _director()
	if bdirector != null and bdirector.has_method("invalidate_brains_cache"):
		bdirector.call("invalidate_brains_cache")
	if _battle_id != "" and _seq_battle_id != "" and _battle_id != _seq_battle_id:
		print("[Arena] Ignoring tournament_battle id mismatch: got ", _battle_id,
			" want ", _seq_battle_id)
		return
	_battle_post_sequence(battle_winner)


func _battle_accepted(res: Dictionary) -> bool:
	# Only these director actions advance a battle. Anything else
	# (idle = unplaceable, broken, unknown) must park loud, never
	# loop: feeding idle into match_reset spun ~300 phantom battles
	# across 5 hours once (Oct 2026 group-D: every idle response
	# reads 0-0 and re-arms the next reset).
	return str(res.get("action", "")) in ["next_battle", "replay", "match_over"]


func _log_battle(winner: String, res: Dictionary) -> void:
	# One arena-log line per battle (action + score + label): the
	# signature the group-D investigation was missing - an idle loop
	# reads as repeated 0-0s here and diagnoses in minutes.
	_arena_log("battle: winner=%s action=%s score=%d-%d (%s)" % [winner,
		str(res.get("action", "?")), int(res.get("score_a", 0)),
		int(res.get("score_b", 0)), expand_match_label(tourney_match_label)])


func _park_unplaceable_battle(battle_winner: String, action: String) -> void:
	# A finished battle the director cannot place (tournament
	# complete, pointer past end, desync): drop it - never cache,
	# never count, never reset - and park LOUD on the bracket. Only
	# a human decision (QUIT TO MENU + RESUME) is safe from here;
	# anything automatic risks the phantom loop.
	_arena_log("phantom battle dropped: winner=%s action=%s (%s)" % [
		battle_winner, action, expand_match_label(tourney_match_label)])
	print("[Arena] STALLED - battle unplaceable (director %s); phantom dropped, no reset sent." % action)
	_hide_loading()
	_show_arena_bracket("STALLED - BATTLE UNPLACEABLE (director %s)" % action)
	if is_instance_valid(status_label):
		status_label.text = "STALLED - %s result unplaceable (director %s) - QUIT TO MENU + RESUME" % [
			expand_match_label(tourney_match_label), action]


func _battle_done_local(draw: bool, draw_penalty: bool = false) -> void:
	# Batched match reporting, battle-end choke point: cache the
	# battle's sync payload (the whole match banks once at match over)
	# and run the post-battle sequence LOCALLY - the arena owns every
	# outcome (KO victim, health-timeout, draws), so no server round
	# trip is needed between battles. Between battles only the ms
	# match_reset runs; battles flow back-to-back on identical weights.
	# The director is consulted BEFORE caching: an unplaceable battle
	# (idle) is dropped + parked here, never cached (banking a phantom
	# later would corrupt records), never counted, never reset.
	_last_verdict = _compose_verdict(draw)
	var wslot := str(_last_verdict.get("winner_slot", ""))
	var winner := "draw" if draw else (wslot if (wslot == "alpha" or wslot == "beta") else "alpha")
	var director := _director()
	var res := {}
	if not draw and director != null:
		res = director.on_battle_result(winner,
			_flight_summary(flight_alpha, fly_alpha),
			_flight_summary(flight_beta, fly_beta),
			_bv_stream_packet(),
			int((stats_alpha as Dictionary).get("kills", 0)),
			int((stats_beta as Dictionary).get("kills", 0)))
		_log_battle(winner, res)
		if not _battle_accepted(res):
			_park_unplaceable_battle(winner, str(res.get("action", "idle")))
			return
	_match_battle_cache.append({
		"battle_id": _current_battle_id(),
		"draw": draw, "draw_penalty": draw_penalty,
		"end_reason": str(_last_verdict.get("end_reason", "")),
		"verdict": _last_verdict.duplicate(),
		"stats_a": stats_alpha.duplicate(), "stats_b": stats_beta.duplicate(),
		"sens_a": _last_sens_a.duplicate(), "sens_b": _last_sens_b.duplicate(),
		"ctrl_a": _last_ctrl_a.duplicate(), "ctrl_b": _last_ctrl_b.duplicate()})
	# Tripwire bound: a real match never exceeds single-digit battles.
	# An unbounded cache means phantom flow - cap it LOUD instead of
	# growing memory and a future giant bank replay.
	while _match_battle_cache.size() > 200:
		_match_battle_cache.pop_front()
		_arena_log("match cache over 200 - dropping oldest battle (phantom flow?)")
	print("[Arena] Battle cached for match bank: %s (%d cached)" % [
		str(_last_verdict.get("line", "")), _match_battle_cache.size()])
	_battle_post_sequence(winner, res)


func _battle_post_sequence(battle_winner: String, res: Dictionary = {}) -> void:
	# The post-battle sequence, run locally at battle end in batch mode
	# (and by any accepted battle reply): clears the wait, tallies the
	# win, shows the verdict callout, advances the bracket, and queues
	# the next battle (ms match_reset) or the match report.
	# res rides along from _battle_done_local (single director consult
	# per battle); the legacy server-reply entry passes none and it is
	# computed below. Either way only an ACCEPTED response proceeds -
	# idle parks loud via the same guard as the cache path.
	_tourney_awaiting_battle = false
	_clear_seq()
	_seq_forgive_match = {}
	if arena_bracket != null:
		arena_bracket.live_preview = {}
	_hide_loading()
	var director := _director()
	if director == null:
		return
	_update_health_hud()
	if battle_winner == "draw":
		var draw_title := _draw_title()
		if is_instance_valid(status_label):
			status_label.text = "%s %s - REPLAYING" % [expand_match_label(tourney_match_label), draw_title]
		_begin_landing("")
		# Replay preview: the banked draw about to land makes the next
		# battle overtime — show its scale and wander dock up front so
		# the viewer knows why health will differ.
		var _next_draws := 1
		if director != null:
			_next_draws = int(director.current_match().get("draws", 0)) + 1
		var _scale := 1.5
		if director != null:
			_scale = director.overtime_scale(_next_draws)
		var _da := float((stats_alpha as Dictionary).get("center_drift", 0.0))
		var _db := float((stats_beta as Dictionary).get("center_drift", 0.0))
		_show_callout(draw_title, Color(0.78, 0.78, 0.82),
			"%s STALEMATE - REPLAY  •  OVERTIME x%.1f: %s -%d HP (%.1f m), %s -%d HP (%.1f m)" % [
				expand_match_label(tourney_match_label), _scale,
				_slot_name("alpha"), int(_wander_dock(_da)), _da,
				_slot_name("beta"), int(_wander_dock(_db)), _db],
			"REMATCH", false)
		await get_tree().create_timer(5.0).timeout
		var draw_adv: Dictionary = director.on_battle_result("draw",
			_flight_summary(flight_alpha, fly_alpha),
			_flight_summary(flight_beta, fly_beta),
			_bv_stream_packet(),
			int((stats_alpha as Dictionary).get("kills", 0)),
			int((stats_beta as Dictionary).get("kills", 0)),
			float((stats_alpha as Dictionary).get("center_drift", -1.0)),
			float((stats_beta as Dictionary).get("center_drift", -1.0)))
		# Third draw resolves the match outright (higher ELO advances)
		# instead of replaying forever.
		_log_battle("draw", draw_adv)
		if str(draw_adv.get("action", "")) == "match_over":
			var draw_score := "%d - %d" % [int(draw_adv.get("score_a", 0)), int(draw_adv.get("score_b", 0))]
			_on_match_over(str(draw_adv.get("match_winner", "alpha")), draw_score)
			return
		if not _battle_accepted(draw_adv):
			_park_unplaceable_battle("draw", str(draw_adv.get("action", "idle")))
			return
		var rhead := _verdict_headline()
		if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
			_set_wait_header(str(rhead.get("text", "")),
				str(rhead.get("sub", "")) + "\nwaiting for server (match reset)...",
				rhead.get("color", Color(0.85, 0.85, 0.9)))
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")
		return
	var winner_name := tourney_a_name if battle_winner == "alpha" else tourney_b_name
	# Legacy server-reply entry passes no response: consult once here
	# (the _battle_done_local entry already did and passes it in).
	# Either way the response is validated before anything advances.
	var res_here := res
	if res_here.is_empty() and battle_winner != "draw":
		res_here = director.on_battle_result(battle_winner,
			_flight_summary(flight_alpha, fly_alpha),
			_flight_summary(flight_beta, fly_beta),
			_bv_stream_packet(),
			int((stats_alpha as Dictionary).get("kills", 0)),
			int((stats_beta as Dictionary).get("kills", 0)))
		_log_battle(battle_winner, res_here)
	if not _battle_accepted(res_here):
		_park_unplaceable_battle(battle_winner, str(res_here.get("action", "idle")))
		return
	# Session wins tally: tournament/quick battle wins move the WINS
	# label, but ONLY for director-accepted battles - phantom wins
	# once inflated it for hours. Draws record nothing (no winner).
	if battle_winner == "alpha" or battle_winner == "beta":
		_record_win(battle_winner)
	var action := str(res_here.get("action", "next_battle"))
	print("[Arena] Battle result: winner=", battle_winner, " action=", action,
		" verdict=", str(_last_verdict.get("line", "")))
	var score := "%d - %d" % [int(res_here.get("score_a", 0)), int(res_here.get("score_b", 0))]
	if action == "match_over":
		var match_winner := str(res_here.get("match_winner", battle_winner))
		_on_match_over(match_winner, score)
	else:
		var sub := "%s  BATTLE %d" % [expand_match_label(tourney_match_label), _battle_count() + 1]
		var vshort := _verdict_short()
		if vshort != "":
			sub += "  |  " + vshort
		_show_callout("%s TAKES BATTLE (%s)" % [winner_name, score],
			Color(1.0, 0.55, 0.3) if battle_winner == "alpha" else Color(0.4, 0.75, 1.0),
			sub, "NEXT BATTLE", false)
		_announce_clip("battle_orange" if battle_winner == "alpha" else "battle_blue")
		await get_tree().create_timer(5.0).timeout
		_update_tourney_status("BATTLE %d" % (_battle_count() + 1))
		var whead := _verdict_headline()
		if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
			_set_wait_header(str(whead.get("text", "")),
				str(whead.get("sub", "")) + "\nwaiting for server (match reset)...",
				whead.get("color", Color(0.85, 0.85, 0.9)))
		brain_client.request_match_reset(tourney_match_label)
		_arm_seq("reset")

func _on_match_over(match_winner: String, score: String) -> void:
	# Round-batch reporting: this match's battles join the round cache
	# (no server send); the bracket advances LOCALLY right away; only a
	# round boundary sends the ONE round_report, and the next round
	# overlaps the bank (intermission first, loads gate on the ack).
	# A drawn split (group play) banks no title-side slot: the batch
	# carries the draw ELO, no match winner is credited.
	_last_match_winner = match_winner
	_last_match_score = score
	var director := _director()
	if director == null:
		return
	var round_before := int(director.tourney.get("current_round", 0))
	_round_match_cache.append(_current_match_entry(match_winner))
	_match_battle_cache.clear()
	var adv: Dictionary = director.advance_after_match()
	var round_after := int(director.tourney.get("current_round", 0))
	# Advance synchronously BEFORE the overlay wait: advance_after_match
	# is pure logic + save, while the 6 s await below dies with the scene
	# if the user quits to menu mid-overlay - which used to swallow the
	# title request (and the evo chain) after the match was already
	# banked. Banking requests are fire-and-forget; only the ack display
	# below is allowed to depend on the wait.
	_preload_next_match()
	# The bracket overlay carries the result: gold connectors show the
	# path, the loser is grayed out, next lineup is visible. A drawn
	# split announces the shared point instead of a winner.
	if match_winner == "draw":
		_show_arena_bracket("%s DRAW %s  (point split)" % [expand_match_label(tourney_match_label), score])
	else:
		var match_name := tourney_a_name if match_winner == "alpha" else tourney_b_name
		_show_arena_bracket("%s TAKES %s  (%s)" % [match_name, expand_match_label(tourney_match_label), score])
		# Decisive matches get the voice; drawn splits stay silent
		# (no winner to name - the bracket shows the shared point).
		_announce_clip("match_orange" if match_winner == "alpha" else "match_blue")
	await get_tree().create_timer(6.0).timeout
	_hide_arena_bracket()
	# Round boundary: the current round's index moved, or the file
	# completed (group_complete / tournament_end). Mid-round matches
	# just flow to the next load; the bank waits for the boundary.
	var round_ended := round_after != round_before \
		or str(adv.get("action", "")) != "next_match"
	if round_ended:
		# Review FIRST: the finished round's bracket goes up before
		# any banking or loading, and the bank runs under it.
		# Wait-bracket ownership carries the sequence: the bank ack
		# auto-hides the review, then the parked load shows its own
		# LOADING view - no moment shows an empty arena, no moment
		# banks or loads unseen.
		if _show_wait_bracket("%s  %s vs %s" % [expand_match_label(tourney_match_label), tourney_a_name, tourney_b_name]):
			_set_wait_header("ROUND COMPLETE - REVIEWING BRACKET",
				"banking the finished round - next round loads on the ack...",
				Color(0.85, 0.85, 0.9))
		else:
			_show_loading("ROUND COMPLETE - REVIEWING BRACKET",
				"banking the finished round...")
		_send_round_report()
	_handle_advance_result(adv)


func _current_match_entry(match_winner: String) -> Dictionary:
	# One round-cache entry for the just-finished (or in-progress)
	# match: winner (or "pending" for the quit-flush strays), fighter
	# ids + vault paths for the round-end reloads, and the cached
	# battles. Read BEFORE advance_after_match (current position is
	# still this match).
	var director := _director()
	var cm: Dictionary = director.current_match() if director != null else {}
	var aid := str(cm.get("a_id", ""))
	var bid := str(cm.get("b_id", ""))
	return {"match_id": _current_match_nonce(),
		"match_winner": match_winner,
		"alpha_id": aid, "beta_id": bid,
		"alpha_path": director.brain_path(aid) if director != null else "",
		"beta_path": director.brain_path(bid) if director != null else "",
		"battles": _match_battle_cache.duplicate(true)}


func _current_match_nonce() -> String:
	# Unique id per reported match (fresh nonce per report; retries
	# resend the STORED round nonce, never a new one).
	return "%s-M%d-%d" % [tourney_match_label,
		Time.get_ticks_msec(), randi() % 100000]


func _send_round_report() -> void:
	# ONE bank per round: every cached match rides one message; the
	# server replays matches in order (per-match vault reload, battles in
	# order, ELO chains, records), then journals once + saves each brain
	# once. The bank runs UNDER the intermission/review (pipelined);
	# loads gate on the ack, never on the send. Group files flag the
	# report: the server pins brains in RAM and journals without
	# saving (the group seal saves once at group completion).
	if _round_match_cache.is_empty():
		return
	_seq_round_id = "RND-%d-%d" % [Time.get_ticks_msec(), randi() % 100000]
	_tourney_awaiting_roundbank = true
	_round_bank_pending = true
	_seq_forgive_roundbank = {"tournament_id": _tourney_id(),
		"match": tourney_match_label, "battle": _seq_round_id}
	var group_mode := _tourney_is_group()
	_seq_last_round_report = {"tournament_id": _tourney_id(),
		"match": tourney_match_label, "round_nonce": _seq_round_id,
		"matches": _round_match_cache.duplicate(true),
		"group": group_mode}
	brain_client.request_round_report(_seq_round_id, _tourney_id(),
		tourney_match_label, _round_match_cache, group_mode)
	_round_match_cache.clear()
	_arm_seq("roundbank")


func _tourney_is_group() -> bool:
	# True when the live tournament file runs group round-robin (the
	# only format that banks per group instead of per round).
	var director := _director()
	if director == null:
		return false
	return str(director.tourney.get("format", "bracket")) == "groups"


func _send_group_report() -> void:
	# ONE bank per group (group files only): the server seals the
	# journal and saves each pinned brain once. Sent at group
	# completion; runs UNDER the group-to-final intermission while
	# final loads gate on the ack. Same nonce/verdict contract as
	# round reports (exact resend, forgive window, watchdog).
	_seq_group_id = "GRP-%d-%d" % [Time.get_ticks_msec(), randi() % 100000]
	_tourney_awaiting_groupbank = true
	_group_bank_pending = true
	_seq_forgive_groupbank = {"tournament_id": _tourney_id(),
		"match": tourney_match_label, "battle": _seq_group_id}
	_seq_last_group_report = {"tournament_id": _tourney_id(),
		"group_nonce": _seq_group_id, "match": tourney_match_label}
	brain_client.request_group_report(_seq_group_id, _tourney_id(),
		tourney_match_label)
	_arm_seq("groupbank")
	_arena_log("group report sent: %s (%s)" % [_seq_group_id, tourney_match_label])


func _forgivable_groupbank(group_nonce: String) -> bool:
	# Group-level twin of _forgivable_roundbank: a post-fail-loud bank
	# ack applies only for the still-owed group (same nonce id, same
	# tournament file, still in a tournament). Pure (unit-tested).
	if _seq_forgive_groupbank.is_empty():
		return false
	if group_nonce != str(_seq_forgive_groupbank.get("battle", "")):
		return false
	if str(_seq_forgive_groupbank.get("tournament_id", "")) != _tourney_id():
		return false
	return tournament_active


func _forgivable_roundbank(round_nonce: String) -> bool:
	# Round-level twin of _forgivable_reply: a post-fail-loud bank ack
	# applies only for the still-owed round (same nonce id, same
	# tournament file, still in a tournament). Pure (unit-tested).
	if _seq_forgive_roundbank.is_empty():
		return false
	if round_nonce != str(_seq_forgive_roundbank.get("battle", "")):
		return false
	if str(_seq_forgive_roundbank.get("tournament_id", "")) != _tourney_id():
		return false
	return tournament_active


func _on_group_banked(group_nonce: String, tid: String) -> void:
	# The server sealed the whole group (journal sealed, every pinned
	# brain saved once, records flushed). Guards mirror the round
	# reply; then: clear the pending flag, refresh the roster cache,
	# fire any load parked on the gate, and run a deferred final
	# build. Round acks never touch group waits (separate state).
	if not _tourney_awaiting_groupbank:
		if group_nonce != "" and _forgivable_groupbank(group_nonce):
			print("[Arena] Forgiving late group_banked (id=",
				group_nonce, "): banked but unconfirmed, applying now.")
		else:
			print("[Arena] Ignoring late/duplicate group_banked (id=",
				group_nonce, ")")
			return
	var bdirector := _director()
	if bdirector != null and bdirector.has_method("invalidate_brains_cache"):
		bdirector.call("invalidate_brains_cache")
	if group_nonce != "" and _seq_group_id != "" and group_nonce != _seq_group_id:
		print("[Arena] Ignoring group_banked id mismatch: got ", group_nonce,
			" want ", _seq_group_id)
		return
	_tourney_awaiting_groupbank = false
	_group_bank_pending = false
	_clear_seq()
	# Consuming the owed ack closes the forgive window.
	_seq_forgive_groupbank = {}
	_hide_wait_bracket()
	_hide_loading()
	if not _pending_final_group.is_empty():
		var fgev := _pending_final_group
		_pending_final_group = {}
		print("[Arena] Group banked - building the queued final now.")
		if _event_build_final(fgev):
			_event_gallery_update()
		_show_arena_bracket("EVENT %s · FINAL" % str(fgev.get("id", "")))
	if _load_gated_on_bank:
		_load_gated_on_bank = false
		_request_current_battle_load()


func _on_round_banked(round_nonce: String, tid: String, match_label: String) -> void:
	# The server banked the whole round (replays, records, weights, one
	# save set). Guards mirror the per-battle reply; then: clear the
	# pending flag, refresh the roster cache, fire any load parked on
	# the gate, run a deferred final-build, and run a deferred
	# tournament-end chain.
	if not _tourney_awaiting_roundbank:
		if round_nonce != "" and _forgivable_roundbank(round_nonce):
			print("[Arena] Forgiving late round_banked (id=",
				round_nonce, "): banked but unconfirmed, applying now.")
		else:
			print("[Arena] Ignoring late/duplicate round_banked (id=",
				round_nonce, ")")
			return
	var bdirector := _director()
	if bdirector != null and bdirector.has_method("invalidate_brains_cache"):
		bdirector.call("invalidate_brains_cache")
	if round_nonce != "" and _seq_round_id != "" and round_nonce != _seq_round_id:
		print("[Arena] Ignoring round_banked id mismatch: got ", round_nonce,
			" want ", _seq_round_id)
		return
	_tourney_awaiting_roundbank = false
	_round_bank_pending = false
	_clear_seq()
	# Consuming the owed ack closes the forgive window.
	_seq_forgive_roundbank = {}
	_hide_wait_bracket()
	_hide_loading()
	if not _pending_advance.is_empty():
		# Stashed tournament-end chain (review already shown pre-ack):
		# the crown + handoff need the banked vault, available now.
		var pa := _pending_advance
		_pending_advance = {}
		_handle_advance_result(pa)
	if not _pending_final_ev.is_empty():
		var fev := _pending_final_ev
		_pending_final_ev = {}
		print("[Arena] Banked - building the queued final now.")
		if _event_build_final(fev):
			_event_gallery_update()
		_show_arena_bracket("EVENT %s · FINAL" % str(fev.get("id", "")))
	if not _pending_advance.is_empty():
		var pa := _pending_advance
		_pending_advance = {}
		_handle_advance_result(pa)
	if _load_gated_on_bank:
		_load_gated_on_bank = false
		_request_current_battle_load()


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
	if action == "group_complete":
		await _event_group_done(res)
		return
	if action == "tournament_end":
		var champ_id := str(res.get("champion_id", ""))
		if director.is_quick():
			# Single exhibition battle: no title, no extra server call (the
			# battle + match are already recorded). Show winner, go home.
			var quick_name: String = director.champion_name()
			_show_callout("%s WINS THE QUICK BATTLE" % quick_name,
				Color(1.0, 0.85, 0.3), "EXHIBITION COMPLETE", "MENU", false)
			var qslot := _slot_of(champ_id)
			_announce_clip("exhibition_orange" if qslot == "alpha"
				else ("exhibition_blue" if qslot == "beta" else "exhibition"))
			await get_tree().create_timer(5.0).timeout
			director.quit_to_menu()
			return
		if _round_bank_pending:
			# Bank still running: review NOW (display-only bracket),
			# crown + handoff proceed on the ack (_on_round_banked
			# re-dispatches the stashed chain). The crown loads the
			# champion BY ID from the vault, which turns post-round only
			# when the bank's saves land.
			_pending_advance = res.duplicate(true)
			_hide_wait_bracket()
			_hide_loading()
			winner_overlay.visible = false
			_show_arena_bracket("CHAMPION: %s - REVIEWING BRACKET (banking round...)" % director.champion_name())
			if is_instance_valid(status_label):
				status_label.text = "TOURNAMENT COMPLETE - banking round, crown follows..."
			return
		var champ_slot := _slot_of(champ_id)
		_tourney_close_ack = false
		brain_client.request_tournament_end(champ_slot, champ_id)
		var champ_name: String = director.champion_name()
		# Continuous mode: skip the review-wait and breed the next
		# generation instead (champion display happens inside).
		if _evo_active():
			if _event_active():
				await _run_event_handoff()
			else:
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
		_hide_wait_bracket()
		_hide_loading()
		winner_overlay.visible = false
		_show_arena_bracket("CHAMPION: %s - REVIEWING BRACKET" % champ_name)
		_save_bracket_record(true)
		if is_instance_valid(status_label):
			status_label.text = "TOURNAMENT COMPLETE - CHAMPION %s%s - review, then QUIT TO MENU" % [champ_name, last_line]
		_announce_clip("champion_orange" if champ_slot == "alpha"
			else ("champion_blue" if champ_slot == "beta" else "champion"))
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
				var champ_id := str(director.tourney.get("champion_id", ""))
				_evo_queue_clone(gen + 1, champ_id, champ_name,
					_evo_clone_parent2(gen + 1, champ_id))
				_update_evo_status_line()
				if is_instance_valid(status_label):
					status_label.text = "CONTINUOUS GEN %d begun - training %s + wild in background..." % [gen + 1, director.kin_base_name(champ_name)]
			await get_tree().create_timer(3.0).timeout
			_hide_arena_bracket()
		_request_current_battle_load()

func _evo_active() -> bool:
	var director := _director()
	if director == null:
		return false
	return bool(director.tourney.get("evo", {}).get("active", false))


# ── Group-stage events (evolution size-16) ──────────────────────────
# One event = group files A-D + final, chained by the event manifest.
# Brackets are fixed at event start; bred offspring stock the manifest
# pool bench and never enter a live bracket directly.


func _event_id() -> String:
	var director := _director()
	if director == null:
		return ""
	return str(director.tourney.get("event_id", ""))


func _event_active() -> bool:
	return _evo_active() and _event_id() != ""


func _event_manifest() -> Dictionary:
	var director := _director()
	if director == null:
		return {}
	return director.event_load(_event_id())


func _event_evo_carry() -> Dictionary:
	# Pipeline continuity across brackets of one event: pending specs
	# keep training (absolute result paths), done entries keep their
	# dedup. Fresh dicts only at event boundaries (see handoff).
	var director := _director()
	if director == null:
		return {"active": true, "generation": 1, "episodes": EVO_EPISODES,
			"mutate_traits": 1, "pending": [], "done": {}}
	return (director.tourney.get("evo", {}) as Dictionary).duplicate(true)


func _on_intermission_skip() -> void:
	_event_skip = true


func _on_intermission_stop() -> void:
	_on_evo_stop()


func _standings_text() -> String:
	var director := _director()
	if director == null:
		return ""
	var group := str(director.tourney.get("group", "?"))
	var lines := PackedStringArray()
	lines.append("GROUP %s — top 2 advance" % group)
	var rows: Array = director.group_standings()
	# Booster marks banked at group completion (manifest): show the tag
	# when reviewing a recorded group; live tables show DNF counts only.
	var booster: Array = []
	if _event_active():
		var gev: Dictionary = director.event_load_cached(_event_id())
		booster = ((gev.get("groups", {}) as Dictionary).get(group, {}) as Dictionary).get("booster", [])
	var top_w := -1.0
	var top_k := -1
	for row in rows:
		var rd := row as Dictionary
		top_w = maxf(top_w, float(rd.get("wins", 0)))
		top_k = maxi(top_k, int(rd.get("kos", 0)))
	var i := 0
	for row in rows:
		i += 1
		var rd := row as Dictionary
		var w := float(rd.get("wins", 0))
		var played := int(rd.get("matches", 0))
		var mark := "★" if i <= 2 else " "
		var tags := ""
		if w >= top_w and top_w > 0.0:
			tags += "  •  WINS LEADER"
		if int(rd.get("kos", 0)) >= top_k and top_k > 0:
			tags += "  •  KO LEADER"
		if str(rd.get("id", "")) in booster:
			tags += "  •  BOOSTER"
		lines.append("%s%d. %s  —  Wins: %s, Losses: %s, Knockouts: %d, DNF: %d%s" % [mark, i,
			str(rd.get("name", "?")),
			director._fmt_wins(w), director._fmt_wins(float(played) - w),
			int(rd.get("kos", 0)), int(rd.get("dnf", 0)), tags])
	return "\n".join(lines)


func _refresh_standings() -> void:
	var director := _director()
	if director == null or not is_instance_valid(standings_label):
		return
	if _event_active():
		# The 2x2 overview carries per-group tables; the strip label
		# would just duplicate them.
		standings_label.visible = false
		return
	if str(director.tourney.get("format", "bracket")) == "groups":
		standings_label.text = _standings_text()
		standings_label.visible = true
	else:
		standings_label.visible = false


func _pool_text(ev: Dictionary) -> String:
	var director := _director()
	var names := PackedStringArray()
	if director != null:
		var by_id := {}
		for b in director.list_brains_cached():
			by_id[str((b as Dictionary).get("id", ""))] = str((b as Dictionary).get("name", "?"))
		for pid in (ev.get("pool", []) as Array):
			names.append(str(by_id.get(str(pid), str(pid))))
	return "POOL: " + (", ".join(names) if names.size() > 0 else "empty")


const POOL_MIN_TRAIN := 50

func _event_maintain_pool() -> void:
	# Breed-ahead: keep wilds training toward the bench while the
	# event plays (clones need the champion, so they queue post-final).
	# Qualified bench + pipeline below target queues another wild.
	# Round-guarded (mirrors _event_topup_tick): the qualified-count
	# shells the roster when the cache is cold, and that refresh must
	# never fire mid-fight. Per-battle invalidation (see
	# _on_tournament_battle) keeps the next gap tick fresh instead.
	if not _event_active():
		return
	if is_round_active:
		return
	var director := _director()
	if director == null:
		return
	var eid := _event_id()
	var ev: Dictionary = director.event_load_cached(eid)
	if ev.is_empty():
		return
	var evo: Dictionary = director.tourney.get("evo", {})
	var gen := int(evo.get("generation", 1))
	var st: Dictionary = ev.get("settings", {})
	var q: Dictionary = director.event_pool_qualified(eid, POOL_MIN_TRAIN,
		float(st.get("elo_cutoff", 0.0)))
	var busy := (q.get("qualified", []) as Array).size()
	for spec in _evo_pending():
		var sk := str((spec as Dictionary).get("kind", ""))
		if sk == "wild" or sk == "clone":
			busy += 1
	for kind in (evo.get("done", {}) as Dictionary).keys():
		if str(kind) == "wild" or str(kind) == "clone":
			busy += 1
	if busy < EVENT_POOL_TARGET and not _evo_has_kind("wild"):
		_evo_queue_wild(gen + 1)


func _event_drain_done_to_pool() -> void:
	# Banked offspring belong on the bench, not in a bracket. Runs on
	# every watcher tick, so it stays silent unless the bench actually
	# gains a brain (otherwise the log drowns in repeats).
	if not _event_active():
		return
	var director := _director()
	if director == null:
		return
	var bench: Array = director.event_load_cached(_event_id()).get("pool", [])
	var ids: Array = []
	for kind in ["clone", "wild"]:
		var bid := _evo_done_id(kind)
		if bid != "" and not (bid in bench):
			ids.append(bid)
	if ids.is_empty():
		return
	var res: Dictionary = director.event_pool_add(_event_id(), ids)
	if bool(res.get("ok", false)):
		print("[Arena] Event pool stocked: ", str(res.get("pool", [])))


static func _gallery_cache_key(eid: String, target: String) -> String:
	# Gallery cache keys carry the event id: chained generations reuse
	# group letters ("B" this event is not "B" last event).
	return eid + ":" + target


func _event_gallery_update(all_fighters: bool = false) -> void:
	# Bracket-view gallery: every fighter pre-event, else the next
	# pending group's cards (hidden once nothing is pending, e.g. the
	# final). Records refetch only when the target changes; rotation
	# rides the shared gallery tick.
	var director := _director()
	if director == null:
		return
	var eid := _event_id()
	if eid == "":
		return
	var ev: Dictionary = director.event_load(eid)
	if ev.is_empty():
		return
	# Keyed by event: chained generations reuse group letters, so a
	# bare letter would serve the previous event's cards forever.
	var key := _gallery_cache_key(eid, "ALL")
	var ids: Array = []
	if all_fighters:
		for g in (ev.get("group_order", []) as Array):
			var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(str(g), {})
			for pid in (gd.get("players", []) as Array):
				if not (str(pid) in ids):
					ids.append(str(pid))
	else:
		# Upcoming bracket's fighters, from the loaded tourney (the
		# switch/build already ran): group letter for group files,
		# FINAL for the final. The old event_next_group routing showed
		# the group-after-next (B-intermission galleried C) — never
		# the bout about to be fought.
		var tplayers: Array = director.tourney.get("players", [])
		if tplayers.is_empty():
			_event_gallery_active = false
			if is_instance_valid(gallery_box):
				gallery_box.visible = false
			return
		var tkey := "FINAL"
		if str(director.tourney.get("format", "")) == "groups":
			tkey = str(director.tourney.get("group", ""))
			if tkey == "":
				tkey = "UNGROUPED"
		key = _gallery_cache_key(eid, tkey)
		for p in tplayers:
			if not (p is Dictionary):
				continue
			var ps := str((p as Dictionary).get("id", ""))
			if ps != "" and not (ps in ids):
				ids.append(ps)
	if key == _event_gallery_key and _event_gallery_active:
		if is_instance_valid(gallery_box):
			gallery_box.visible = true
		return
	_event_gallery_key = key
	var by_id := {}
	for b in director.list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	nextgen_brains.clear()
	var cards: Array = []
	for pid in ids:
		if by_id.has(pid):
			var bd := by_id[pid] as Dictionary
			nextgen_brains[pid] = bd
			cards.append({"id": pid, "name": str(bd.get("name", "?"))})
	if cards.is_empty():
		_event_gallery_active = false
		return
	_event_gallery_active = true
	# Right column in event mode (the legacy waiting room keeps left).
	if not _event_gallery_moved and is_instance_valid(bracket_row) \
			and is_instance_valid(gallery_box):
		bracket_row.move_child(gallery_box, 1)
		_event_gallery_moved = true
	if is_instance_valid(gallery_box):
		gallery_box.visible = true
	_build_gallery_entries(cards)


func _event_resume_intermission() -> bool:
	# Relaunch into a live event: same bracket wait as live play (60 s
	# groups, 120 s final) with the upcoming fighters in the gallery —
	# resumes never jump straight into battle. SKIP/STOP keep their
	# usual meaning; false means quit to menu.
	var director := _director()
	if director == null:
		return false
	var eid := _event_id()
	var is_final := str(director.tourney.get("format", "")) != "groups"
	var label := "final" if is_final else str(director.tourney.get("group", "?"))
	var title := "EVENT %s · %s" % [eid, "FINAL" if is_final else "GROUP " + label]
	_event_gallery_update()
	var wait_secs := EVENT_FINAL_SECS if is_final else EVENT_INTERMISSION_SECS
	return await _event_intermission(title, _event_preview_sub(label), wait_secs, true)


func _event_pre_showcase() -> void:
	# Brand-new event tip-off (runs once): 30 s bracket overview with
	# all sixteen fighters rotating through the gallery, then Group A
	# loads normally below.
	var director := _director()
	if director == null:
		return
	_event_gallery_update(true)
	var eid := _event_id()
	if not await _event_intermission("EVENT %s · TIP-OFF" % eid,
			"Group A starts in", EVENT_PREVIEW_SECS, true):
		director.quit_to_menu()
		return


func _event_next_phase(ev: Dictionary) -> String:
	for g in (ev.get("group_order", []) as Array):
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(str(g), {})
		if not bool(gd.get("done", false)):
			return str(g)
	return "final"


func _event_build_group(ev: Dictionary, letter: String) -> bool:
	var director := _director()
	if director == null:
		return false
	var carry := _event_evo_carry()
	var g: Dictionary = (ev.get("groups", {}) as Dictionary).get(letter, {})
	var by_id := {}
	for b in director.list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	var dicts: Array = []
	for pid in (g.get("players", []) as Array):
		if not by_id.has(str(pid)):
			_evo_abort("event short: %s missing from vault" % str(pid))
			return false
		dicts.append(by_id[str(pid)])
	var st: Dictionary = ev.get("settings", {})
	var res: Dictionary = director.build_group_bracket(dicts, letter,
		str(ev.get("id", "")), int(st.get("best_of", 7)),
		float(st.get("lr_scale", 0.5)), float(st.get("round_time", 40.0)))
	if not bool(res.get("ok", false)):
		_evo_abort("next group failed: " + str(res.get("error", "?")))
		return false
	director.tourney["evo"] = carry
	director.save_state()
	director.event_note_bracket(str(ev.get("id", "")), letter,
		str(director.tourney.get("id", "")))
	director.event_set_phase(str(ev.get("id", "")), "groups_" + letter)
	return true


func _event_build_all_groups(ev: Dictionary) -> bool:
	# Fixtures for the whole event up front: every quadrant renders
	# real versus cards from the first minute (no "No tournament"
	# panels). The chain only switches between prebuilt files after.
	for letter in (ev.get("group_order", []) as Array):
		if not _event_build_group(ev, str(letter)):
			return false
	return true


func _event_switch_group(ev: Dictionary, letter: String) -> bool:
	# Enter a prebuilt group file: ghost-check the roster, load it,
	# carry the pipeline evo over. Falls back to building when no
	# file was recorded (older events).
	var director := _director()
	if director == null:
		return false
	var eid := str(ev.get("id", ""))
	var g: Dictionary = (ev.get("groups", {}) as Dictionary).get(letter, {})
	var by_id: Dictionary = {}
	for b in director.list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	for pid in (g.get("players", []) as Array):
		if not by_id.has(str(pid)):
			_evo_abort("event short: %s missing from vault" % str(pid))
			return false
	var carry: Dictionary = _event_evo_carry()
	var bid := str(g.get("bracket_id", ""))
	if bid == "":
		return _event_build_group(ev, letter)
	if not director.load_state_file(director.tournament_dir.path_join(bid + ".json")):
		_evo_abort("event file missing: " + bid)
		return false
	if not director.tournament_active():
		_evo_abort("event file not running: " + bid)
		return false
	director.tourney["evo"] = carry
	director.save_state()
	director.event_set_phase(eid, "groups_" + letter)
	return true


func _event_build_final(ev: Dictionary) -> bool:
	var director := _director()
	if director == null:
		return false
	var eid := str(ev.get("id", ""))
	var adv: Dictionary = director.event_advancers(eid)
	if not bool(adv.get("ok", false)):
		_evo_abort("finalists undecided: " + str(adv.get("error", "?")))
		return false
	var by_id := {}
	for b in director.list_brains_cached():
		by_id[str((b as Dictionary).get("id", ""))] = b
	for pid in (adv.get("advancers", []) as Array):
		if not by_id.has(str(pid)):
			_evo_abort("event short: finalist %s missing" % str(pid))
			return false
	var carry := _event_evo_carry()
	var st: Dictionary = ev.get("settings", {})
	var res: Dictionary = director.build_final_bracket(adv.get("advancers", []), eid,
		int(st.get("best_of", 7)), float(st.get("lr_scale", 0.5)),
		float(st.get("round_time", 40.0)))
	if not bool(res.get("ok", false)):
		_evo_abort("final failed: " + str(res.get("error", "?")))
		return false
	director.tourney["evo"] = carry
	director.save_state()
	var ev2: Dictionary = director.event_load(eid)
	ev2["final_id"] = str(director.tourney.get("id", ""))
	director.event_save(ev2)
	director.event_set_phase(eid, "final")
	return true


func _event_preview_sub(upcoming: String) -> String:
	# One glance at what's next: group card or final QF pairs + bench.
	# Group fighters render side-by-side in one row (a vertical stack
	# squeezed the bracket); final QF pairings keep one line per pair
	# (short, structured).
	var director := _director()
	if director == null:
		return ""
	var ev: Dictionary = _event_manifest()
	var lines := PackedStringArray()
	if upcoming == "final":
		var adv: Dictionary = director.event_advancers(str(ev.get("id", "")))
		var qf: Array = adv.get("advancers", []) if bool(adv.get("ok", false)) else []
		var names := {}
		for b in director.list_brains_cached():
			names[str((b as Dictionary).get("id", ""))] = str((b as Dictionary).get("name", "?"))
		var i := 0
		while i + 1 < qf.size():
			lines.append("QF: %s v %s" % [str(names.get(str(qf[i]), "?")),
				str(names.get(str(qf[i + 1]), "?"))])
			i += 2
	else:
		var g: Dictionary = (ev.get("groups", {}) as Dictionary).get(upcoming, {})
		var by_id := {}
		for b in director.list_brains_cached():
			var bd := b as Dictionary
			by_id[str(bd.get("id", ""))] = "%s (%d)" % [str(bd.get("name", "?")),
				int((bd.get("record", {}) as Dictionary).get("elo", 1200.0))]
		var row := _preview_group_row(
			(g.get("players", []) as Array), by_id)
		if row != "":
			lines.append(row)
	lines.append(_pool_text(ev))
	return "\n".join(lines)


static func _preview_group_row(players: Array, by_id: Dictionary) -> String:
	# One horizontal roster row for the intermission header: every
	# fighter side-by-side ("Name (elo) | ..."), never stacked. Pure
	# (unit-tested); unknown ids pass through raw like before.
	var row := PackedStringArray()
	for pid in players:
		row.append(str(by_id.get(str(pid), str(pid))))
	return " | ".join(row)


func _event_is_fresh() -> bool:
	# Brand-new event tip-off: group A file untouched (0,0, no battles
	# banked) AND no group done anywhere in the manifest. The manifest
	# clause matters: quitting during a later group's intermission (or
	# before its first battle banks) leaves a fresh-looking group file,
	# and without it the resume would play the 30 s tip-off (mislabeled
	# "Group A starts in") instead of the 60 s resume intermission for
	# the right group.
	var director := _director()
	if director == null or not _event_active():
		return false
	if str(director.tourney.get("format", "")) != "groups":
		return false
	if int(director.tourney.get("current_round", -1)) != 0 \
			or int(director.tourney.get("current_match", -1)) != 0:
		return false
	var ev := _event_manifest()
	for g in (ev.get("group_order", []) as Array):
		var gd: Dictionary = (ev.get("groups", {}) as Dictionary).get(str(g), {})
		if bool(gd.get("done", false)):
			return false
	var m: Dictionary = director.current_match()
	return int(m.get("battles", 0)) == 0


func _event_intermission(title: String, sub: String, secs: float = EVENT_INTERMISSION_SECS, gallery_all: bool = false) -> bool:
	# Bracket preview + standings + 60 s countdown between event
	# brackets. SKIP starts now; STOP aborts the event (quit to menu
	# follows in the caller). Returns true when the next bracket may
	# start (the file is already built, so quit/resume always lands).
	var director := _director()
	if director == null:
		return false
	_event_skip = false
	# The countdown is a wait view: no round may run behind it, even
	# one left live by an unexpected entry path.
	_close_round_for_wait()
	bracket_title.text = title
	if _event_active() and str(director.tourney.get("format", "bracket")) == "groups":
		var ov: Dictionary = director.event_overview_data(_event_id())
		arena_bracket.render_event_groups(ov, str(ov.get("current", "")))
		if not gallery_all:
			_event_gallery_update()
	else:
		arena_bracket.render_bracket(director.tourney, 0, 0)
	_refresh_standings()
	intermission_label.text = sub
	intermission_row.visible = true
	# Preload under the countdown: the director points at the next
	# match's file (post-switch/post-advance) - the ~5-20 s load hides
	# inside the 30/60/120 s wait, so the post-countdown load is an
	# O(1) activation.
	_preload_next_match()
	if is_instance_valid(bracket_scroll):
		bracket_scroll.scroll_horizontal = 0
		bracket_scroll.scroll_vertical = 0
	bracket_overlay.visible = true
	_sync_bracket_button()
	# Countdown provenance: title carries the caller (TIP-OFF / GROUP
	# A..D / FINAL), so any "wrong length" report is attributable.
	print("[Arena] Intermission '%s' for %ds" % [title, int(secs)])
	_arena_log("intermission '%s' for %ds" % [title, int(secs)])
	var left := secs
	while left > 0.0 and not _event_skip:
		if not _event_active():
			print("[Arena] Intermission '%s' broke early (%.0fs left): event inactive" % [title, left])
			break
		intermission_label.text = "%s\nNext bracket in %d s — SKIP to start now" % [sub, int(ceil(left))]
		await get_tree().create_timer(1.0).timeout
		left -= 1.0
	intermission_row.visible = false
	if not _event_active():
		_sync_bracket_button()
		return false
	bracket_overlay.visible = false
	_sync_bracket_button()
	return true


func _event_group_done(res: Dictionary) -> void:
	var director := _director()
	if director == null:
		return
	var eid := _event_id()
	var group := str(res.get("group", "?"))
	var rec: Dictionary = director.event_record_group(eid, group)
	if not bool(rec.get("ok", false)):
		_evo_abort("event record failed: " + str(rec.get("error", "?")))
		return
	# Group record: keep the finished bracket up and AWAIT the capture.
	# Un-awaited, the record's 2-frame PNG delay resumed AFTER the
	# intermission raised the countdown overlay and its auto-hide
	# yanked it - leaving a text-only screen for the whole 60 s wait
	# (and the PNG captured the wrong view). Pre-showing makes
	# showed=false (no auto-hide possible); awaiting lands the capture
	# before group B re-renders. The callout below plays over the live
	# bracket, so the view runs seamlessly into the intermission.
	_show_arena_bracket("GROUP %s COMPLETE - FINAL RECORD" % group)
	await _save_bracket_record(true)
	var _bset: Array = (rec.get("booster", []) as Array)
	var _bsub := "STANDINGS BANKED"
	if not _bset.is_empty():
		_bsub += "  •  BOOSTER: %d (post-event +50 school)" % _bset.size()
		print("[Arena] Group %s booster-marked: %s" % [group, str(_bset)])
	_show_callout("GROUP %s COMPLETE" % group, Color(0.6, 0.85, 1.0),
		_bsub, "", false)
	var ev: Dictionary = director.event_load(eid)
	var nxt := _event_next_phase(ev)
	if nxt == "":
		_evo_abort("event chain broken after group " + group)
		return
	var title := "EVENT %s · %s" % [eid, "FINAL" if nxt == "final" else "GROUP " + nxt]
	var sub := _event_preview_sub(nxt)
	var wait_secs := EVENT_FINAL_SECS if nxt == "final" else EVENT_INTERMISSION_SECS
	# Group seal first: it runs UNDER the intermission while final
	# loads gate on its ack (vault files turn post-group only when
	# the seal's saves land). Round reports already acked fast (they
	# only journal); the seal carries the weights.
	_send_group_report()
	if _round_bank_pending:
		print("[Arena] Bank %s still owed at intermission - countdown runs under it; loads gate on the ack." % _seq_round_id)
	# The final's player ELO snapshots must come post-bank: stash the
	# build while EITHER bank is owed and let the group ack build it.
	# (Round acks never consume this stash - only _on_group_banked.
	# Separate var from _pending_final_ev for exactly that reason.)
	if nxt == "final" and (_round_bank_pending or _group_bank_pending):
		_pending_final_group = ev.duplicate(true)
		title += " (banking round...)"
		_event_gallery_update()
		if not await _event_intermission(title, sub, wait_secs, true):
			director.quit_to_menu()
			return
	else:
		var built := _event_build_final(ev) if nxt == "final" else _event_switch_group(ev, nxt)
		if not built:
			return
		# Gallery primed before the wait (the intermission renders it):
		# upcoming bracket's fighters in both cases, final included.
		_event_gallery_update()
		if not await _event_intermission(title, sub, wait_secs, true):
			director.quit_to_menu()
			return
	_request_current_battle_load()


func _event_pool_ready_count() -> int:
	# Promotion-ready brains vault-wide (schooled + above the demotion
	# line, outside the current event): the draw pool, not the bench.
	var director := _director()
	if director == null:
		return 0
	var ev: Dictionary = director.event_load(_event_id())
	if ev.is_empty():
		return 0
	var st: Dictionary = ev.get("settings", {})
	var q: Dictionary = director.event_draw_candidates(_event_id(),
		POOL_MIN_TRAIN, float(st.get("elo_cutoff", 0.0)))
	return (q.get("qualified", []) as Array).size() if bool(q.get("ok", false)) else 0


func _event_pool_wait() -> String:
	# Rare fallback: bench short at handoff. Waits on the FINAL review
	# screen (bracket visible, queue status live) while the background
	# queue works - never a bare progress bar. STOP aborts. Returns ""
	# when the bench filled, else the reason (the caller parks on
	# FINAL REVIEW with it, never a bare return).
	var director := _director()
	if director == null:
		return "no director"
	_close_round_for_wait()
	_show_arena_bracket("FINAL REVIEW - PROMOTION READY (%d/%d qualified)" % [
		_event_pool_ready_count(), EVENT_POOL_TARGET])
	var waited := 0.0
	while _evo_active() and waited < EVO_AWAIT_TIMEOUT:
		await get_tree().create_timer(5.0).timeout
		waited += 5.0
		_evo_adopt_finished()
		_event_drain_done_to_pool()
		_event_maintain_pool()
		var ready := _event_pool_ready_count()
		if is_instance_valid(status_label):
			status_label.text = "Promotion-ready %d/%d - queue breeding..." % [ready, EVENT_POOL_TARGET]
		if ready >= EVENT_POOL_TARGET:
			_hide_arena_bracket()
			return ""
	# Failure paths leave FINAL REVIEW up for the caller's failure
	# view (hiding into nothing was the bare-arena stall).
	if not _evo_active():
		return "stopped by user"
	_evo_abort("pool short - refusing a short-bench event")
	return "pool short - refusing a short-bench event"


func _arena_log(msg: String) -> void:
	# Persistent client-side session log (user://arena_log.txt): the
	# wedge/recovery timeline stdout never captures (the game window
	# owns it). Rare events only - open/append/close per line.
	var path := "user://arena_log.txt"
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE
	var f := FileAccess.open(path, mode)
	if f == null:
		return
	f.seek_end()
	f.store_line("%s  %s" % [
		Time.get_datetime_string_from_system().replace("T", " "), msg])
	f.close()


func _recover_server_state(reason: String) -> bool:
	# The quit+resume recipe, in place (no scene change): fresh
	# seq/latches, fresh UDP socket, re-issued load from the current
	# director position. Stored payloads resend under their SAME nonce
	# where one is owed (callers set the pending-resend flag BEFORE
	# calling; consumed in _on_brains_loaded). Capped: MAX_SERVER_RELOADS
	# between clean loads; past the cap the caller parks loud (a
	# persistently broken server is not automatable). Status line only
	# - silent healing otherwise.
	if tournament_active and _server_reloads >= MAX_SERVER_RELOADS:
		_arena_log("RECOVERY CAP EXHAUSTED: %s (reloads %d/%d)" % [reason,
			_server_reloads, MAX_SERVER_RELOADS])
		return false
	_server_reloads += 1
	_arena_log("AUTO-RECOVER (%s): reloading %s (attempt %d/%d)" % [reason,
		tourney_match_label, _server_reloads, MAX_SERVER_RELOADS])
	_restore_timescale()
	_clear_seq()
	tourney_awaiting_load = false
	_tourney_awaiting_battle = false
	_tourney_awaiting_roundbank = false
	_seq_forgive_match = {}
	_seq_forgive_roundbank = {}
	_hide_wait_bracket()
	_hide_loading()
	brain_client.reconnect()
	print("[Arena] AUTO-RECOVER (%s): reloading %s (attempt %d/%d)..." % [
		reason, expand_match_label(tourney_match_label),
		_server_reloads, MAX_SERVER_RELOADS])
	if is_instance_valid(status_label):
		status_label.text = "RECOVERING: %s - reloading %s..." % [reason,
			expand_match_label(tourney_match_label)]
	_recover_in_flight = true
	_request_current_battle_load()
	return true


func _on_server_state(mode: bool, tid: String, match_label: String) -> void:
	# State-poll reply: attribution log at every wait, and one proactive
	# recovery - a FREE-mode server while a match bank is owed means it
	# restarted mid-bank: reload + stored-report resend NOW instead of
	# after the 240 s watchdog cycle.
	print("[Arena] Server state: mode=%s tourney=%s match=%s (awaiting %s)" % [
		mode, tid, match_label, _seq_context])
	_arena_log("server state poll: mode=%s tourney=%s match=%s (awaiting %s)" % [
		mode, tid, match_label, _seq_context])
	if _seq_context == "roundbank" and not mode and tournament_active \
			and not _recover_in_flight and not _pending_roundbank_resend \
			and not _seq_last_round_report.is_empty():
		# FREE-mode server while a bank is owed: it restarted mid-bank.
		# Arm the stored-report resend and reload NOW - the in-flight
		# report is about to be refused anyway, and this skips the whole
		# 240 s watchdog cycle. (The refusal error that follows is
		# attributed silently: recovery already in flight.)
		if _recover_server_state("round bank interrupted (state poll)"):
			_pending_roundbank_resend = true


func _show_handoff_failure(title: String, reason: String) -> void:
	# Handoff/start_next failures park here, never on a bare arena:
	# freeze like an abort, then raise FINAL REVIEW carrying the reason.
	# Callers quit to menu after a short review (show-then-quit), so the
	# viewer reads what broke instead of staring at an empty field.
	_evo_abort(reason)
	_show_arena_bracket(title)


func _run_event_handoff() -> void:
	# Final's tournament_end: the title request already went out above.
	# Bank the record, eliminate two, queue the next bench generation,
	# and chain the next event WITHOUT blocking on training: breeds
	# ride the background queue (their specs carry into the new event
	# file, so no verdict ever orphans). Only a short bench parks on
	# the review screen until the queue delivers.
	var director := _director()
	if director == null:
		return
	var eid := _event_id()
	var champ_id := str(director.tourney.get("champion_id", ""))
	# The handoff runs bracket-first: every build/queue step below shows
	# on FINAL REVIEW, so a stall or failure never strands the viewer on
	# a bare arena. Awaited capture: an un-awaited record's delayed
	# hide would yank a later overlay (same race as group intermissions).
	_show_arena_bracket("EVENT %s - BUILDING NEXT EVENT" % eid)
	await _save_bracket_record(true)
	_show_arena_bracket("EVENT %s - BUILDING NEXT EVENT" % eid)
	_show_callout("EVENT %s CHAMPION: %s" % [eid, director.champion_name()],
		Color(1.0, 0.85, 0.3), "ELIMINATION + BREEDING", "", false)
	_announce_clip("event_champion")
	_event_drain_done_to_pool()
	var ev0: Dictionary = director.event_load(eid)
	var st0: Dictionary = ev0.get("settings", {})
	# Booster schooling first (marked brains train +50 with school
	# curriculum): elimination archives brains out of the vault, so
	# queueing after it would ghost-skip the eliminated. Best-effort,
	# never blocks the handoff.
	var boost: Dictionary = director.event_booster_queue(eid)
	if not (boost.get("queued", []) as Array).is_empty():
		print("[Arena] Event %s booster schooling queued: %s" % [
			eid, str(boost.get("queued", []))])
	var elim: Dictionary = director.event_eliminate(eid,
		int(st0.get("min_matches", EVENT_MIN_MATCHES)),
		float(st0.get("elo_cutoff", 0.0)))
	# Green-roster tolerance: fewer than 2 career-eligible brains means
	# nobody has the matches to demote, so elimination is WAIVED this
	# generation (the green-protection promise holds; the event simply
	# refights without fresh blood) instead of aborting the chain.
	# Loud, never silent - a stalled composition must read somewhere.
	var gone: Array = []
	if not bool(elim.get("ok", false)):
		if str(elim.get("error", "")) == "fewer than 2 eligible brains":
			print("[Arena] Event %s: green roster, elimination waived (no fresh blood this generation)." % eid)
			if is_instance_valid(status_label):
				status_label.text = "EVENT %s: GREEN ROSTER - NO ELIMINATION THIS GENERATION" % eid
		else:
			_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
				"elimination failed: " + str(elim.get("error", "?")))
			await get_tree().create_timer(8.0).timeout
			director.quit_to_menu()
			return
	else:
		gone = elim.get("eliminated", [])
		print("[Arena] Event %s eliminated %s" % [eid, str(gone)])
	director.event_finish(eid, champ_id)
	var ev: Dictionary = director.event_load(eid)
	var gen := int(ev.get("generation", 1))
	if not _evo_has_kind("clone"):
		_evo_queue_clone(gen + 1, champ_id, director.champion_name(),
			_evo_clone_parent2(gen + 1, champ_id))
	if not _evo_has_kind("wild"):
		_evo_queue_wild(gen + 1)
	_event_drain_done_to_pool()
	if _event_pool_ready_count() < EVENT_POOL_TARGET:
		var why := await _event_pool_wait()
		if why != "":
			_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid, why)
			await get_tree().create_timer(8.0).timeout
			director.quit_to_menu()
			return
	_event_start_next(ev, gone)


func _event_start_next(ev_old: Dictionary, gone: Array) -> void:
	var director := _director()
	if director == null:
		return
	var eid := str(ev_old.get("id", ""))
	var gen := int(ev_old.get("generation", 1)) + 1
	var st: Dictionary = ev_old.get("settings", {})
	var survivors: Array = []
	for g in (ev_old.get("group_order", []) as Array):
		var gd: Dictionary = (ev_old.get("groups", {}) as Dictionary).get(str(g), {})
		for pid in (gd.get("players", []) as Array):
			if not (str(pid) in gone) and not (str(pid) in survivors):
				survivors.append(str(pid))
	# Normally 14 (16 minus 2 eliminated); a waived elimination leaves
	# 15-16 and the draw shrinks to fit - the roster still lands on 16.
	# Anything else is a corrupt manifest, not a stall: show it, quit.
	var need := 16 - survivors.size()
	if need < 0 or need > 2:
		_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
			"event survivors %d (need 14-16)" % survivors.size())
		await get_tree().create_timer(8.0).timeout
		director.quit_to_menu()
		return
	var draw: Dictionary = director.event_draw_pool(eid, need,
		POOL_MIN_TRAIN, float(st.get("elo_cutoff", 0.0)))
	if not bool(draw.get("ok", false)) \
			or (draw.get("drawn", []) as Array).size() != need:
		_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
			"pool draw failed: " + str(draw.get("error", "short bench")))
		await get_tree().create_timer(8.0).timeout
		director.quit_to_menu()
		return
	var roster: Array = survivors + (draw.get("drawn", []) as Array)
	var beg: Dictionary = director.event_begin(roster, st, gen)
	if not bool(beg.get("ok", false)):
		_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
			"next event failed: " + str(beg.get("error", "?")))
		await get_tree().create_timer(8.0).timeout
		director.quit_to_menu()
		return
	var new_eid := str(beg.get("event_id", ""))
	# Bench remainder rides into the new event; in-flight breed specs
	# ride along too (absolute result paths), so no verdict ever
	# orphans across the boundary. Banked done entries stay behind:
	# they already drained into the old pool.
	var carried: Array = []
	for spec in _evo_pending():
		carried.append((spec as Dictionary).duplicate(true))
	director.event_pool_add(new_eid,
		(director.event_load(eid).get("pool", []) as Array))
	var ev_new: Dictionary = director.event_load(new_eid)
	# Full four-group setup at start (menu parity): every bracket file
	# built + noted now, so the overview renders real fixtures for all
	# quadrants from the first minute. The old single-A build left B/C/D
	# lazy - the next event's overview showed unpopulated groups.
	# Switch back to A after: the build loop leaves the last-built
	# file (D) and its phase loaded.
	if not _event_build_all_groups(ev_new):
		_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
			"next event brackets failed to build")
		await get_tree().create_timer(8.0).timeout
		director.quit_to_menu()
		return
	if not _event_switch_group(ev_new, "A"):
		_show_handoff_failure("FINAL REVIEW - EVENT %s" % eid,
			"next event group A failed to load")
		await get_tree().create_timer(8.0).timeout
		director.quit_to_menu()
		return
	director.tourney["evo"] = {"active": true, "generation": gen,
		"episodes": EVO_EPISODES,
		"mutate_traits": int(st.get("mutate_traits", 1)),
		"pending": carried, "done": {}}
	director.save_state()
	if not await _event_intermission("EVENT %s · GROUP A (GEN %d)" % [new_eid, gen],
			_event_preview_sub("A"), EVENT_INTERMISSION_SECS):
		director.quit_to_menu()
		return
	_request_current_battle_load()


const EVO_EPISODES := 50
# Legacy regime default: every breed's training recipe (episode total,
# stage split, weight noise, structural changes) now inherits ± a delta
# from its parent (wilds draw fresh), so EVO_EPISODES is only the
# display fallback. MAX_EVO_EPISODES mirrors TRAINING_RANGES upstairs.
const MAX_EVO_EPISODES := 80
# Await/slot-wait ceiling: two-stage breeds (25+25 eps) run ~40+ min on
# this hardware (single-stage wild already took 22 min). The old fixed
# 20-min timeout aborted generations mid-training while the worker was
# still legitimately burning CPU - the log showed only the banner
# (buffered) and the verdict never landed. Episodes-proportional to the
# recipe cap: 80 eps x 80 s + loader headroom.
const EVO_AWAIT_TIMEOUT := MAX_EVO_EPISODES * 80.0
# Two-step evo breeding: half the episodes pre-train, half Advanced
# Flight School (default school curriculum; school code selects stages).
# NOTE: this JSON must NEVER ride argv (--params2): Godot strips embedded
# double-quotes when joining argv on Windows, corrupting it exactly like
# the old empty --name bug. _evo_params2_file writes it to disk and the
# spawns pass --params2-file instead (same pattern as generate_brain_async).
const EVO_SCHOOL_PARAMS := '{"curriculum": {}}'


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
# Training-queue HUD state: background-fill bar under the EVO line plus
# last-known progress counts (the director's job_progress signal feeds
# both; the 5 s EVO tick re-derives visibility from ground truth).
var train_prog_bar: ProgressBar
var _train_prog_ep := -1
var _train_prog_total := -1
var _train_prog_job := ""
var evo_status_tick := 0.0
var _adopt_last_sweep := 0.0
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
	evo_status_line.clip_text = true
	# Training progress: same rect as the status line, drawn UNDER the
	# text as a subtle green wash - zero new chrome, so it can never
	# collide with the menubar below or StatusCorner above.
	train_prog_bar = ProgressBar.new()
	train_prog_bar.name = "TrainProgBar"
	train_prog_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	train_prog_bar.offset_left = -400.0
	train_prog_bar.offset_right = 400.0
	train_prog_bar.offset_top = -74.0
	train_prog_bar.offset_bottom = -50.0
	train_prog_bar.min_value = 0.0
	train_prog_bar.max_value = 100.0
	train_prog_bar.show_percentage = false
	var prog_bg := StyleBoxFlat.new()
	prog_bg.bg_color = Color(0, 0, 0, 0)
	train_prog_bar.add_theme_stylebox_override("background", prog_bg)
	var prog_fill := StyleBoxFlat.new()
	prog_fill.bg_color = Color(0.45, 0.85, 0.5, 0.18)
	prog_fill.set_corner_radius_all(4)
	train_prog_bar.add_theme_stylebox_override("fill", prog_fill)
	train_prog_bar.visible = false
	hud.add_child(train_prog_bar)
	hud.move_child(train_prog_bar, evo_status_line.get_index())
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
	# The next-gen waiting room owns the screen while visible: phase
	# popups would hide underneath the bracket overlay, so their
	# progress lives in the strip instead (status_label keeps updating).
	if nextgen_visible:
		return
	if is_instance_valid(evo_title):
		evo_title.text = title
	_update_evo_phase(status, -1.0)
	if is_instance_valid(evo_panel):
		evo_panel.visible = true


func _update_evo_phase(status: String, pct: float) -> void:
	if nextgen_visible:
		return
	if is_instance_valid(evo_status):
		evo_status.text = status
	if is_instance_valid(evo_bar) and pct >= 0.0:
		evo_bar.value = clampf(pct, 0.0, 100.0)


func _hide_evo_phase() -> void:
	if is_instance_valid(evo_panel):
		evo_panel.visible = false


func _on_evo_async(op: String, result: Dictionary) -> void:
	# Catches breed completions for the continuous tournament loop (only while a
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


func _prog_total(prog: Dictionary) -> float:
	# Per-breed episode total from its progress file (recipes vary the
	# regime per child); legacy EVO_EPISODES as the fallback.
	return maxf(float(prog.get("total", EVO_EPISODES)), 1.0)


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
	var display := brain_name if brain_name != "" else "wild"
	# No --episodes/--episodes2/--noise: the breeder deals each child a
	# recipe inherited ± a delta from its parent (fresh for wilds).
	var args := ["breed", "--strategy", strategy,
		"--seed", str(seed),
		"--progress", progress_path,
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
		"Spawning worker (attempt %d)... dealing training recipe" % attempt)
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
					int(last.get("episode", 0)), int(_prog_total(last))])
			evo_waiting = false
			break
		var prog := _evo_poll_file(progress_path)
		if not prog.is_empty():
			var pct := 100.0 * float(prog.get("episode", 0)) / maxf(float(prog.get("total", EVO_EPISODES)), 1.0)
			_show_evo_phase("BREEDING " + display,
				"Training ep %d/%d ..." % [int(prog.get("episode", 0)), int(_prog_total(prog))])
			_update_evo_phase("Training ep %d/%d ..." % [int(prog.get("episode", 0)), int(_prog_total(prog))], pct)
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


# Exploration rotation for wilds: graft -> shuffle -> novelty across
# generations (crossover rides the clone slot every 4th gen instead).
const WILD_MODE_CYCLE := ["graft", "shuffle", "novelty"]


func _evo_queue_spec(kind: String, brain_name: String, parent_id: String,
		seed: int, target_gen: int, mode: String = "") -> void:
	var pending := _evo_pending()
	for spec in pending:
		if str((spec as Dictionary).get("kind", "")) == kind:
			return
	var paths := _evo_spec_paths(kind, target_gen)
	pending.append({"kind": kind, "name": brain_name, "parent": parent_id,
		"seed": seed, "gen": target_gen, "progress": paths[0],
		"result": paths[1], "pid": 0, "launched": false, "mode": mode})
	_evo_save_queue(pending, _evo_done())


func _evo_wild_mode(target_gen: int) -> String:
	return WILD_MODE_CYCLE[(maxi(target_gen, 1) - 1) % WILD_MODE_CYCLE.size()]


func _evo_pool_threshold() -> int:
	# Smart-pool threshold: new wilds/breed-kins queue only while the
	# pool (whole vault roster) sits below this. Menu-settable
	# (tournament page, default 25); <= 0 disables the gate (legacy
	# always-breed). Carried across generations in the evo dict.
	var director := _director()
	if director == null:
		return 25
	return int((director.tourney.get("evo", {}) as Dictionary).get("pool_threshold", 25))


func _evo_pool_size() -> int:
	# The pool is the whole vault roster: everyone eligible to fight.
	var director := _director()
	if director == null:
		return 0
	return (director.list_brains_cached() as Array).size()


func _evo_breeding_wanted() -> bool:
	# Instance wrapper: pool size and threshold off the live director.
	var director := _director()
	var threshold := 25
	var pool := 0
	if director != null:
		threshold = int((director.tourney.get("evo", {}) as Dictionary).get("pool_threshold", 25))
		pool = (director.list_brains_cached() as Array).size()
	return _evo_pool_wants_breeding(pool, threshold)


static func _evo_pool_wants_breeding(pool_size: int, threshold: int) -> bool:
	# Central gate (pure, unit-tested): every present and future queue
	# site inherits it. Strictly below threshold breeds; at/above
	# fights the pool as-is; threshold <= 0 disables the gate (legacy
	# always-breed).
	if threshold <= 0:
		return true
	return pool_size < threshold


func _evo_queue_wild(target_gen: int, mode: String = "") -> void:
	# Random needs nothing but a generation: name "" lets Python
	# christen it deterministically (wild_name from seed).
	if _evo_has_kind("wild"):
		return
	if not _evo_breeding_wanted():
		print("[Arena] Pool %d/%d - wild breed skipped (pool at threshold)." % [
			_evo_pool_size(), _evo_pool_threshold()])
		return
	if mode == "":
		mode = _evo_wild_mode(target_gen)
	_evo_queue_spec("wild", "", "", randi(), target_gen, mode)


func _evo_pool_fill(roster: Array, gone: Array, size: int) -> Array:
	# Complete a short bracket from the pool (established fighters
	# first). Pure roster math (no breeding, no saves) - the caller
	# builds the bracket from the result.
	var director := _director()
	if director == null or not director.has_method("evo_ranking"):
		return roster
	return _evo_pool_fill_ranked(roster, gone, size,
		director.evo_ranking())


static func _evo_pool_fill_ranked(roster: Array, gone: Array, size: int,
		ranking: Array) -> Array:
	# ranking arrives worst-first (evo_ranking's order): draft from
	# the best end so brackets fill with proven fighters. Skips ids
	# already fighting and freshly archived losers.
	var filled: Array = roster.duplicate()
	for i in range(ranking.size() - 1, -1, -1):
		if filled.size() >= size:
			break
		var id := str(ranking[i])
		if id != "" and not (id in filled) and not (id in gone):
			filled.append(id)
	return filled


func _evo_queue_clone(target_gen: int, champ_id: String, champ_name: String,
		parent2_id: String = "") -> void:
	if champ_id == "" or _evo_has_kind("clone"):
		return
	if not _evo_breeding_wanted():
		print("[Arena] Pool %d/%d - kin breed skipped (pool at threshold)." % [
			_evo_pool_size(), _evo_pool_threshold()])
		return
	# Spec carries the pedigree BASE for display; the worker appends
	# -kin/-jr with the lineage counters at banking (counters are
	# never parsed). --name is withheld at spawn so the worker
	# auto-composes from the parent record.
	var director := _director()
	var base := champ_name
	if director != null:
		base = director.kin_base_name(champ_name)
	_evo_queue_spec("clone", base, champ_id, randi(), target_gen, "")
	if parent2_id != "":
		# Crossover child: same clone slot/done-key, second parent noted.
		for spec in _evo_pending():
			var s := spec as Dictionary
			if str(s.get("kind", "")) == "clone":
				s["parent2"] = parent2_id
				break
		_evo_save_queue(_evo_pending(), _evo_done())


func _evo_crossover_partner(champ_id: String) -> String:
	# Highest-ELO crossable roster rival (director owns the bearing
	# check; base/legacy/multi-mix parents would fail breeding and
	# abort the generation, so they never qualify here).
	var director := _director()
	if director == null or not director.has_method("is_genome_bearing"):
		return ""
	var best := ""
	var best_elo := -1.0
	for p in director.tourney.get("players", []):
		if not (p is Dictionary):
			continue
		var pd := p as Dictionary
		var pid := str(pd.get("id", ""))
		if pid == "" or pid == champ_id:
			continue
		if not bool(director.call("is_genome_bearing", pid)):
			continue
		var rec = pd.get("record", {})
		var elo := 1200.0
		if rec is Dictionary:
			elo = float((rec as Dictionary).get("elo", 1200.0))
		if elo > best_elo:
			best_elo = elo
			best = pid
	return best


func _evo_clone_parent2(target_gen: int, champ_id: String) -> String:
	# Crossover every 4th generation: champion x strongest crossable
	# rival - but only when the CHAMPION itself can cross (a
	# base/legacy/multi-mix champion killed gen 4 this way). Anything
	# else clones asexually as before.
	if target_gen % 4 != 0:
		return ""
	var director := _director()
	if director == null or not director.has_method("is_genome_bearing"):
		return ""
	if not bool(director.call("is_genome_bearing", champ_id)):
		return ""
	return _evo_crossover_partner(champ_id)


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
	var parent2 := str(spec.get("parent2", ""))
	var strategy := "random"
	if kind == "clone":
		strategy = "crossover" if parent2 != "" else "clone"
	# No --episodes/--episodes2/--noise: the breeder deals each child a
	# recipe inherited ± a delta from its parent (fresh for wilds).
	var args := ["breed", "--strategy", strategy,
		"--seed", str(int(spec.get("seed", 0))),
		"--progress", str(spec.get("progress", "")),
		"--gen", str(int(spec.get("gen", 1))),
		"--explore-mode", str(spec.get("mode", "")) if str(spec.get("mode", "")) != "" else "graft",
		"--log-file", log_path]
	if parent2 != "":
		args += ["--parent2", parent2]
	var p2 := _evo_params2_file(rf)
	if p2 != "":
		args += ["--params2-file", p2]
	# Kin trait mutation rides the tournament's evo settings (menu
	# toggle at START CONTINUOUS, preserved across generations).
	var evod: Dictionary = director.tourney.get("evo", {})
	args += ["--mutate-traits", str(int(evod.get("mutate_traits", 1)))]
	# Never emit an empty argv element: Godot drops it on Windows, so
	# `--name ""` arrives as a bare `--name` and argparse aborts the
	# worker (this killed every wild breed). Empty = auto-compose:
	# wilds christen from stems, clones/crossovers from the parent
	# record (base + lineage counters + mutation outcome). Explicit
	# spec names forward only for other strategies.
	var sname := str(spec.get("name", ""))
	if sname != "" and not (kind in ["clone", "crossover"]):
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


func _evo_adopt_finished(force: bool = false) -> Dictionary:
	# Sweeps queued specs for completed result files: banks {kind: id},
	# drops failed specs (re-bred at tournament end), cleans litter.
	# Returns ids adopted this sweep. Throttled (per-frame result-file
	# re-opens were churn); rescue paths pass force=true so a just-
	# landed verdict is never missed and a finished breed never aborted.
	var now := Time.get_ticks_msec() / 1000.0
	if not force and now - _adopt_last_sweep < 1.0:
		return {}
	_adopt_last_sweep = now
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
						int(last.get("episode", 0)), int(_prog_total(last)),
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
	# Tournament-end handoff for the continuous tournament loop. Adopts any breeds
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
	_show_callout("CONTINUOUS GEN %d CHAMPION: %s" % [gen, champ_name],
		Color(1.0, 0.85, 0.3), "BREEDING NEXT GENERATION", "", false)
	_announce_clip("generation_champion")
	_show_evo_phase("CONTINUOUS GENERATION %d" % [gen + 1],
		"Champion %s - ranking bottom two..." % champ_name)
	if is_instance_valid(status_label):
		status_label.text = "CONTINUOUS gen %d champion %s - ranking bottom two..." % [gen, champ_name]
	# --- Archive bottom two ---
	var bottom: Dictionary = director.evo_bottom_two()
	var last_id := str((bottom.get("last", {}) as Dictionary).get("id", ""))
	var second_id := str((bottom.get("second", {}) as Dictionary).get("id", ""))
	var via := str((bottom.get("last", {}) as Dictionary).get("via", "ranking"))
	if via == "ranking" and is_instance_valid(status_label):
		status_label.text = "CONTINUOUS gen %d: no consolation ran - bottom two by ranking fallback." % gen
	if last_id == "":
		_evo_abort("no loser found - bracket empty?")
		return
	for pair in [[last_id, "biggest loser"], [second_id, "second-last"]]:
		if str(pair[0]) == "":
			continue
		var ares: Dictionary = director.evo_archive(
			str(pair[0]), "continuous gen %d %s (%s)" % [gen, str(pair[1]), via])
		if not bool(ares.get("ok", false)):
			_evo_abort("archive failed: %s" % str(ares.get("error", "?")))
			return
		print("[Arena] CONTINUOUS gen %d: archived %s %s" % [gen, str(pair[1]), str(pair[0])])
	# --- Next-gen waiting room: preview bracket + gallery + strip ---
	# Survivor context is frozen here; offspring cards refresh live as
	# breeds adopt (synthetic "training" names until then).
	var target_gen := gen + 1
	nextgen_gen = target_gen
	nextgen_size = int(director.tourney.get("size", 8))
	nextgen_gone = [last_id, second_id]
	nextgen_survivors = []
	for p in director.tourney.get("players", []):
		var pid := str((p as Dictionary).get("id", ""))
		if pid != "" and not (pid in nextgen_gone):
			nextgen_survivors.append(pid)
	nextgen_champ_id = champ_id
	nextgen_champ_name = champ_name
	nextgen_clone_name = director.kin_base_name(champ_name)
	nextgen_brains = {}
	for b in director.list_brains_cached():
		var bd := b as Dictionary
		nextgen_brains[str(bd.get("id", ""))] = bd
	_show_nextgen_overlay("NEXT GENERATION %d" % target_gen)
	# --- Adopt background breeds + await stragglers ---
	_evo_adopt_finished()
	_refresh_nextgen_preview()
	var id1 := _evo_done_id("clone")
	var id2 := _evo_done_id("wild")
	# Queue missing specs under the pool gate (watcher will launch
	# them when the slot is free); a full pool skips breeding
	# entirely and the bracket refills from established fighters.
	# _evo_queue_* no-op internally when the gate is shut.
	var want_breed := _evo_breeding_wanted()
	if not want_breed:
		print("[Arena] Pool %d/%d - generation %d breeds no replacements." % [
			_evo_pool_size(), _evo_pool_threshold(), target_gen])
	if id1 == "" and not _evo_has_kind("clone"):
		_evo_queue_clone(target_gen, champ_id, champ_name,
			_evo_clone_parent2(target_gen, champ_id))
	if id2 == "" and not _evo_has_kind("wild"):
		_evo_queue_wild(target_gen)
	# Tournament is over: show whatever is left in training before
	# blocking on stragglers (names for the done, ep counts for the
	# live, queued for the rest).
	_show_evo_phase("CONTINUOUS GENERATION %d" % target_gen,
		_evo_offspring_summary(target_gen))
	if is_instance_valid(status_label):
		status_label.text = "CONTINUOUS gen %d over - breeding gen %d..." % [gen, target_gen]
	# Await any still-pending specs one by one via the shared slot.
	# done is re-read between awaits: the watcher may bank the wild
	# breed while the clone await is in flight.
	if id1 == "" and _evo_has_kind("clone"):
		id1 = await _evo_await_queued("clone")
		if id1 == "":
			# Last-chance rescue: a verdict adopted by a concurrent
			# sweep between the await's last tick and this line.
			_evo_adopt_finished(true)
			id1 = _evo_done_id("clone")
		if id1 == "" and _evo_active():
			_evo_abort("clone breeding failed - %s" % _evo_spawn_why())
			return
		_refresh_nextgen_preview()
	if id2 == "":
		id2 = _evo_done_id("wild")
	if id2 == "" and _evo_has_kind("wild"):
		id2 = await _evo_await_queued("wild")
		if id2 == "":
			_evo_adopt_finished(true)
			id2 = _evo_done_id("wild")
		if id2 == "" and _evo_active():
			_evo_abort("random breeding failed - %s" % _evo_spawn_why())
			return
		_refresh_nextgen_preview()
	# STOP/quit during the handoff must freeze the loop, never emit a
	# short bracket: the 15-roster cascade came from an empty id
	# appended after a stop, then reactivated at rebuild below.
	# A missing offspring on a live loop is equally fatal: abort
	# instead of a TBA bracket (7 round-0 losers can never start
	# consolation, so the shortness would self-perpetuate).
	if not _evo_active():
		return
	# Offspring required only when the gate bred (or found) them: a
	# full pool plays on without replacements instead of aborting on
	# young it never asked for.
	if want_breed and (id1 == "" or id2 == ""):
		_evo_abort("missing offspring - refusing a short bracket")
		return
	# --- Rebuild bracket at constant roster size ---
	# Survivors plus adopted offspring (if the gate bred any); a full
	# pool completes from established fighters by ranking instead of
	# breeding newcomers for the slot.
	var size := int(director.tourney.get("size", 8))
	var gone := [last_id, second_id]
	var present: Array = director.evo_vault_ids()
	var roster: Array = []
	for p in director.tourney.get("players", []):
		var pid := str((p as Dictionary).get("id", ""))
		if pid != "" and not (pid in gone) and pid in present:
			roster.append(pid)
	for oid in [id1, id2]:
		if str(oid) != "" and not (str(oid) in roster):
			roster.append(str(oid))
	roster = _evo_pool_fill(roster, gone, size)
	# Self-heal for short rosters the pool cannot fill (weird configs
	# like bracket size above pool size, or a vanished vault file):
	# breed wild top-ups until the bracket is full. Bounded; failure
	# aborts instead of a TBA bracket. This is necessity breeding,
	# not pipeline breeding - the threshold gate yields to it.
	var topups := 0
	while roster.size() < size and topups < 2 and _evo_active():
		var tkind := "topup%d" % topups
		_evo_queue_spec(tkind, "", "", randi(), target_gen)
		_show_evo_phase("CONTINUOUS GENERATION %d" % target_gen,
			"Short roster (%d/%d) - breeding top-up %d..." % [roster.size(), size, topups + 1])
		var tid := await _evo_await_queued(tkind)
		if tid == "" or tid in roster:
			_evo_abort("top-up breeding failed - %s" % _evo_spawn_why())
			return
		roster.append(tid)
		topups += 1
		_refresh_nextgen_preview()
	if roster.size() < size:
		_evo_abort("roster still short after top-ups - refusing a TBA bracket")
		return
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
	# The evo dict rebuilds from scratch each generation: carry the
	# pool threshold forward or the gate silently resets to default.
	var carried := director.tourney.get("evo", {}) as Dictionary
	director.tourney["evo"] = {"active": true, "generation": gen + 1,
		"episodes": EVO_EPISODES,
		"pool_threshold": int(carried.get("pool_threshold", 25)),
		"mutate_traits": int(carried.get("mutate_traits", 1))}
	director.save_state()
	# Pipeline: kick off the next generation's wild breed immediately
	# (gated: a full pool skips it and plays on).
	_evo_queue_wild(gen + 2)
	_show_evo_phase("CONTINUOUS GENERATION %d" % [gen + 1],
		"Roster ready (%d fighters, pool %d/%d) - loading first battle..." % [
			roster.size(), _evo_pool_size(), _evo_pool_threshold()])
	if is_instance_valid(status_label):
		status_label.text = "CONTINUOUS gen %d ready (%d fighters, pool %d/%d)." % [
			gen + 1, roster.size(), _evo_pool_size(), _evo_pool_threshold()]
	await get_tree().create_timer(2.0).timeout
	_hide_nextgen()
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
				label = "wild"
			if bool(s.get("launched", false)):
				var prog := _evo_poll_file(str(s.get("progress", "")))
				if prog.is_empty():
					lines.append("%s - warming up" % label)
				else:
					lines.append("%s - training ep %d/%d" % [label,
						int(prog.get("episode", 0)), int(_prog_total(prog))])
			else:
				lines.append("%s - queued" % label)
		if not found:
			lines.append("%s - queued" % kind)
	# Top-up heals (short-roster repair) ride the same queue machinery.
	for spec in _evo_pending():
		var sk := str((spec as Dictionary).get("kind", ""))
		if sk != "" and not (sk in ["clone", "wild"]):
			lines.append("%s - training (top-up)" % sk)
	for dk in _evo_done().keys():
		if not (str(dk) in ["clone", "wild"]):
			lines.append("%s - done" % _evo_done_name(str(dk)))
	return "\n".join(lines)


func _evo_spawn_why() -> String:
	# Human-readable cause for the last spawn failure, defaulting to
	# the log pointer when the breed died mid-flight instead.
	if evo_last_spawn_error != "":
		return evo_last_spawn_error
	return "check brains/jobs log"


# ── Next-generation waiting room ────────────────────────────────
# Preview bracket + rotating fighter gallery + training strip shown
# during the handoff wait. Display-only throughout: the real bracket
# is built later by the existing rebuild path (never-TBA guarantee
# untouched), and the overlay closes on first-battle load.


func _nextgen_wild_label(target_gen: int) -> String:
	return "wild (training)"


func _nextgen_offspring_slots() -> Array:
	# [{key, id, kind, name, elo, placeholder}] for clone/wild/topups
	# from live done state; the unbred ride stable "offspring:<kind>"
	# placeholder keys (never bare "" twice) so the bracket, gallery
	# and strip all address the same training card until adoption.
	var out: Array = []
	var cid := _evo_done_id("clone")
	if cid != "":
		var rec: Dictionary = nextgen_brains.get(cid, {})
		out.append({"key": cid, "id": cid, "kind": "clone",
			"name": str(rec.get("name", _evo_done_name("clone"))),
			"elo": float((rec.get("record", {}) as Dictionary).get("elo", 1200.0)),
			"placeholder": false})
	else:
		var champ_elo := 1200.0
		var director := _director()
		if director != null:
			for p in director.tourney.get("players", []):
				var pd := p as Dictionary
				if str(pd.get("id", "")) == nextgen_champ_id:
					champ_elo = float((pd.get("record", {}) as Dictionary).get("elo", 1200.0))
		out.append({"key": "offspring:clone", "id": "offspring:clone",
			"kind": "clone", "name": nextgen_clone_name, "elo": champ_elo,
			"placeholder": true})
	var wid := _evo_done_id("wild")
	if wid != "":
		var wrec: Dictionary = nextgen_brains.get(wid, {})
		out.append({"key": wid, "id": wid, "kind": "wild",
			"name": str(wrec.get("name", _evo_done_name("wild"))),
			"elo": float((wrec.get("record", {}) as Dictionary).get("elo", 1200.0)),
			"placeholder": false})
	else:
		out.append({"key": "offspring:wild", "id": "offspring:wild",
			"kind": "wild", "name": _nextgen_wild_label(nextgen_gen),
			"elo": 1200.0, "placeholder": true})
	for kind in _evo_done().keys():
		var ks := str(kind)
		if ks.begins_with("topup"):
			var tid := _evo_done_id(ks)
			if tid != "":
				var trec: Dictionary = nextgen_brains.get(tid, {})
				out.append({"key": tid, "id": tid, "kind": ks,
					"name": str(trec.get("name", _evo_done_name(ks))),
					"elo": float((trec.get("record", {}) as Dictionary).get("elo", 1200.0)),
					"placeholder": false})
	return out


func _build_nextgen_preview() -> Dictionary:
	var director := _director()
	if director == null or nextgen_survivors.is_empty():
		return {}
	var names := {}
	for p in director.tourney.get("players", []):
		var pd := p as Dictionary
		names[str(pd.get("id", ""))] = pd
	var entries: Array = []
	for pid in nextgen_survivors:
		var spid := str(pid)
		if spid in nextgen_gone:
			continue
		var rec: Dictionary = nextgen_brains.get(spid, {})
		if rec.is_empty() and names.has(spid):
			var npd: Dictionary = names[spid]
			entries.append({"id": spid, "name": str(npd.get("name", spid)),
				"record": npd.get("record", {})})
		elif not rec.is_empty():
			entries.append({"id": spid, "name": str(rec.get("name", spid)),
				"record": rec.get("record", {})})
		# Vault-missing survivors drop out (rebuild trims/aborts the same).
	for off in _nextgen_offspring_slots():
		var od := off as Dictionary
		entries.append({"id": str(od.get("id", "")),
			"name": str(od.get("name", "?")),
			"record": {"elo": float(od.get("elo", 1200.0))}})
	while entries.size() > nextgen_size:
		# Degenerate overshoot (second-last missing, trim territory):
		# drop the lowest-ELO non-champion, mirroring the rebuild trim
		# instead of blindly popping offspring off the end.
		var drop := -1
		var drop_elo := INF
		for i in range(entries.size()):
			var ed := entries[i] as Dictionary
			if str(ed.get("id", "")) == nextgen_champ_id:
				continue
			var e := float((ed.get("record", {}) as Dictionary).get("elo", 1200.0))
			if e < drop_elo:
				drop_elo = e
				drop = i
		if drop < 0:
			break
		entries.remove_at(drop)
	if entries.size() < 2:
		return {}
	return director.preview_bracket(entries, nextgen_size,
		bool(director.tourney.get("random_draw", false)))


func _show_nextgen_overlay(title_text: String) -> void:
	nextgen_visible = true
	nextgen_gallery_tick = 0.0
	nextgen_strip_tick = NEXTGEN_STRIP_EVERY
	if is_instance_valid(gallery_box):
		gallery_box.visible = true
	if is_instance_valid(strip_box):
		strip_box.visible = true
	_refresh_nextgen_preview()
	if is_instance_valid(bracket_title):
		bracket_title.text = title_text
	if is_instance_valid(bracket_overlay):
		bracket_overlay.visible = true
	_sync_bracket_button()
	_hide_evo_phase()


func _hide_nextgen() -> void:
	nextgen_visible = false
	if is_instance_valid(arena_bracket):
		arena_bracket.clear_spotlight()
		arena_bracket.clear_showcase()
	if is_instance_valid(gallery_box):
		gallery_box.visible = false
	if is_instance_valid(strip_box):
		strip_box.visible = false
	if is_instance_valid(bracket_overlay):
		bracket_overlay.visible = false
	_sync_bracket_button()


func _refresh_nextgen_preview() -> void:
	# Re-fetch vault records (adoptions land new files), rebuild the
	# preview, gallery and strip. Rare by design: handoff milestones
	# only, never the per-frame path (list_brains shells out).
	if not nextgen_visible:
		return
	var director := _director()
	if director != null:
		var fresh := {}
		for b in director.list_brains_cached():
			var bd := b as Dictionary
			fresh[str(bd.get("id", ""))] = bd
		if not fresh.is_empty():
			nextgen_brains = fresh
	nextgen_preview = _build_nextgen_preview()
	if director == null or not is_instance_valid(arena_bracket):
		return
	if nextgen_preview.is_empty():
		return
	arena_bracket.render_bracket(nextgen_preview, -1, -1)
	if is_instance_valid(bracket_scroll):
		bracket_scroll.scroll_horizontal = 0
		bracket_scroll.scroll_vertical = 0
	_build_gallery_entries(nextgen_preview.get("players", []))
	_update_nextgen_strip()


func _offspring_kind_title(kind: String, pname: String) -> String:
	# Placeholder cards announce themselves as the incoming breed, so
	# the queue reads "new breed / new wild is here" at a glance.
	if kind == "clone":
		return "NEW BREED — %s" % pname
	if kind == "wild":
		return "NEW WILD — %s" % pname
	if kind.begins_with("topup"):
		return "TOP-UP — %s" % pname
	return pname


func _gallery_card(pid: String, pname: String) -> Dictionary:
	var rec: Dictionary = nextgen_brains.get(pid, {}) if pid != "" else {}
	if rec.is_empty():
		# Training card: ep progress from the matching pending spec
		# (or the awaited-detached one, same blind spot as the strip).
		# Placeholders arrive under "offspring:<kind>" keys, so kind
		# matching is exact; name matching stays as legacy fallback.
		var want := ""
		if pid.begins_with("offspring:"):
			want = pid.trim_prefix("offspring:")
		var detail := "queued"
		var found_kind := want
		for spec in _evo_pending() + [evo_await_spec]:
			var s := spec as Dictionary
			if s.is_empty():
				continue
			var sk := str(s.get("kind", ""))
			var m := (want != "" and sk == want) \
				or (str(s.get("name", "")) != "" and str(s.get("name", "")) == pname) \
				or (sk == "wild" and (pname == "wild" or pname.begins_with("wild ")))
			if not m and not (sk.begins_with("topup") and pname == sk):
				continue
			found_kind = sk
			if bool(s.get("launched", false)):
				var prog := _evo_poll_file(str(s.get("progress", "")))
				if prog.is_empty():
					detail = "warming up"
				else:
					detail = "ep %d/%d" % [int(prog.get("episode", 0)), int(_prog_total(prog))]
			else:
				detail = "queued"
			detail += " [%s]" % sk if sk != "" else detail
			break
		return {"key": pid, "title": _offspring_kind_title(found_kind, pname),
			"elo": "--", "rows": "training...\n%s" % detail}
	var r: Dictionary = rec.get("record", {})
	var gp: Dictionary = rec.get("generator_params", {})
	var t: Dictionary = rec.get("training", {})
	var wiring := str(gp.get("genome_id", ""))
	if wiring == "":
		var exp = gp.get("experiment", null)
		if exp is Array:
			var parts := PackedStringArray()
			for e in (exp as Array):
				parts.append(str(e))
			wiring = "mix " + "+".join(parts) if parts.size() > 0 else "base"
		elif exp != null and str(exp) != "":
			wiring = str(exp)
		else:
			wiring = "base"
	else:
		wiring = "genome " + wiring
	wiring += " · " + str(gp.get("explore_mode", "legacy"))
	var mp = gp.get("mapping", null)
	if mp is Array:
		wiring += " · %d rules" % (mp as Array).size()
	var traits := "evasion %s · dist_gain %s · lr %s" % [
		_fmt_stat(gp.get("evasion", 0.0)), _fmt_stat(gp.get("dist_gain", 0.0)),
		_fmt_stat(gp.get("learning_rate", 0.0))]
	var yb = gp.get("yaw_bias", null)
	if yb != null:
		traits += " · yaw %s" % _fmt_bias(yb)
	# Evolved reflex authority: only deviations from the legacy
	# operating point (mirrors sensory_motor.BLEND_DEFAULTS).
	var bldefs := {"yaw_blend": 0.3, "evade_backup": 1.0,
		"flow_authority": 1.0, "search_blend": 0.5, "pitch_blend": 1.0}
	var blnames := {"yaw_blend": "yaw", "evade_backup": "evbk",
		"flow_authority": "flow", "search_blend": "srch",
		"pitch_blend": "ptch"}
	var blparts := PackedStringArray()
	for bk in bldefs.keys():
		var bv := float(gp.get(bk, bldefs[bk]))
		if absf(bv - float(bldefs[bk])) > 0.001:
			blparts.append("%s %.2f" % [str(blnames[bk]), bv])
	if blparts.size() > 0:
		traits += " · ctl " + " ".join(blparts)
	var teps := int(t.get("episodes", 0))
	var tscore := float(t.get("score", 0.0))
	var fights := "Battles %d (W%d L%d D%d) · Matches %d (W%d L%d) · Titles %d · Wandered %d" % [
		int(r.get("battles", 0)), int(r.get("wins", 0)),
		int(r.get("losses", 0)), int(r.get("draws", 0)),
		int(r.get("matches", 0)), int(r.get("matches_won", 0)),
		int(r.get("matches_lost", 0)), int(r.get("tournaments_won", 0)),
		int(r.get("wander", 0))]
	var schooled := "Episodes %d · Recent %.2f/ep (total %.1f)" % [
		teps, float(t.get("recent_avg", 0.0)), tscore]
	var rows := "%s\n%s\n%s\n%s\n%s" % [fights, schooled, wiring,
		traits, _inheritance_line(rec)]
	var rear := _rearing_line(rec)
	if rear != "":
		rows += "\n" + rear
	return {"key": pid, "title": pname,
		"elo": "%d" % int(r.get("elo", 1200.0)), "rows": rows}


func _rearing_line(rec: Dictionary) -> String:
	# Heritable training recipe: how long/hard this brain was
	# schooled (episodes inherit ± a delta, wilds draw fresh).
	var tr: Dictionary = (rec.get("lineage", {}) as Dictionary).get("training", {})
	if tr.is_empty():
		return ""
	return "reared %dep · split %.2f · noise %.3f · struct %d" % [
		int(tr.get("episodes_total", 0)), float(tr.get("stage_split", 0.5)),
		float(tr.get("noise", 0.0)), int(tr.get("max_changes", 0))]


func _fmt_stat(v) -> String:
	return "%.2f" % float(v)


func _fmt_bias(yb) -> String:
	if yb is Array:
		var parts := PackedStringArray()
		for b in (yb as Array):
			parts.append("%.2f" % float(b))
		return "[" + ", ".join(parts) + "]"
	return str(yb)


func _nextgen_parent_name(pid: String) -> String:
	# Resolve a lineage parent id to its vault name; archived/gone
	# parents fall back to the id itself (never blank, never "?").
	var rec: Dictionary = nextgen_brains.get(pid, {})
	if not rec.is_empty():
		return str(rec.get("name", pid))
	var director := _director()
	if director != null:
		for p in director.tourney.get("players", []):
			var pd := p as Dictionary
			if str(pd.get("id", "")) == pid:
				return str(pd.get("name", pid))
	return pid


func _inheritance_line(rec: Dictionary) -> String:
	# "clone of X · traits: evasion 0.40→0.53" / "crossover A × B" /
	# "wild (evo-random · novelty)" / "reference stock" / "generated".
	var lin: Dictionary = rec.get("lineage", {})
	var src := str(lin.get("source", "?"))
	var line := src
	if src.begins_with("clone:"):
		line = "clone"
	elif src.begins_with("crossover:"):
		line = "crossover"
	elif src == "evo-random":
		line = "wild"
	elif src == "reference":
		line = "reference stock"
	elif src == "generated":
		line = "generated"
	var parents: Array = lin.get("parent_ids", [])
	if not parents.is_empty():
		var names := PackedStringArray()
		for pp in parents:
			names.append(_nextgen_parent_name(str(pp)))
		line += " of " + " × ".join(names)
	var mode := str(lin.get("explore_mode", ""))
	if mode != "" and line in ["wild", "crossover", "clone"]:
		line += " · " + mode
	var tm = lin.get("trait_mutations", {})
	if tm is Dictionary and not (tm as Dictionary).is_empty():
		var bits := PackedStringArray()
		for k in (tm as Dictionary).keys():
			var pair = (tm as Dictionary)[k]
			if pair is Array and (pair as Array).size() >= 2:
				bits.append("%s %s→%s" % [str(k),
					_fmt_stat((pair as Array)[0]), _fmt_stat((pair as Array)[1])])
		if bits.size() > 0:
			line += " · traits: " + ", ".join(bits)
	return line


func _build_gallery_entries(players: Array) -> void:
	nextgen_gallery.clear()
	for p in players:
		var pd := p as Dictionary
		nextgen_gallery.append(_gallery_card(str(pd.get("id", "")),
			str(pd.get("name", "?"))))
	nextgen_gallery_idx = 0
	if not nextgen_gallery.is_empty():
		_render_gallery_card(nextgen_gallery[0])


func _render_gallery_card(entry: Dictionary) -> void:
	if is_instance_valid(gallery_title):
		gallery_title.text = str(entry.get("title", "?"))
	# Same marker as the bracket rows: the gallery's own showcased
	# name carries the red star whenever the card names a fighter -
	# the exact key condition that showcases the bracket below, so
	# the two can never disagree.
	if is_instance_valid(gallery_star):
		gallery_star.visible = str(entry.get("key", "")) != ""
	if is_instance_valid(gallery_elo):
		gallery_elo.text = "ELO " + str(entry.get("elo", "--"))
	if is_instance_valid(gallery_rows):
		gallery_rows.text = str(entry.get("rows", ""))
	# The showcased fighter's bracket slot spotlights in sync, and
	# every bracket row spelling the name paints cyan with the gallery
	# title (cleared when the card carries no key).
	if is_instance_valid(arena_bracket):
		var k := str(entry.get("key", ""))
		if k != "":
			arena_bracket.set_spotlight(k)
			arena_bracket.set_showcase(k)
		else:
			arena_bracket.clear_spotlight()
			arena_bracket.clear_showcase()


func _gallery_advance() -> void:
	if nextgen_gallery.is_empty():
		return
	nextgen_gallery_idx = (nextgen_gallery_idx + 1) % nextgen_gallery.size()
	_render_gallery_card(nextgen_gallery[nextgen_gallery_idx])
	if is_instance_valid(gallery_box):
		var tw := create_tween()
		gallery_box.modulate.a = 0.25
		tw.tween_property(gallery_box, "modulate:a", 1.0, 0.4)


func _offspring_progress(kind: String) -> Array:
	# [label, pct]: 100 when done, live ep percent while training,
	# 0 queued/warming, -1 when the kind is entirely absent.
	var label := ""
	if _evo_done().has(kind):
		return [_evo_done_name(kind), 100.0]
	var cands: Array = []
	for spec in _evo_pending():
		cands.append(spec)
	var aw := _evo_awaited_spec(kind)
	if not aw.is_empty():
		cands.append(aw)
	for spec in cands:
		var s := spec as Dictionary
		if str(s.get("kind", "")) != kind:
			continue
		label = str(s.get("name", ""))
		if label == "":
			label = "wild"
		if not bool(s.get("launched", false)):
			return [label + " queued", 0.0]
		var prog := _evo_poll_file(str(s.get("progress", "")))
		if prog.is_empty():
			return [label + " warming up", 0.0]
		return [label, 100.0 * float(prog.get("episode", 0)) / _prog_total(prog)]
	return ["", -1.0]


func _update_nextgen_strip() -> void:
	if not nextgen_visible:
		return
	for slot in [["clone", strip_clone_label, strip_clone_bar],
			["wild", strip_wild_label, strip_wild_bar]]:
		var key := str(slot[0])
		var res: Array = _offspring_progress(key)
		var lab: Label = slot[1]
		var bar: ProgressBar = slot[2]
		if not is_instance_valid(lab) or not is_instance_valid(bar):
			continue
		var tag := key
		if key == "clone":
			tag = "new breed"
		elif key == "wild":
			tag = "new wild"
		if float(res[1]) < 0.0:
			lab.text = "%s: --" % tag
			bar.value = 0.0
		else:
			lab.text = "%s: %s" % [tag, str(res[0])]
			bar.value = clampf(float(res[1]), 0.0, 100.0)


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
		evo_await_spec = {"kind": kind, "name": sname0,
			"gen": int(s.get("gen", 1)),
			"progress": str(s.get("progress", "")),
			"launched": bool(s.get("launched", false)),
			"mode": str(s.get("mode", ""))}
		var display0 := sname0 if sname0 != "" else "wild"
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
					evo_await_spec = {}
					return ""
				var blk := _evo_blocking_spec(kind)
				if blk.is_empty():
					_show_evo_phase("BREEDING " + display0,
						"Waiting for the training slot (%s in progress)..." % str(tdir.pending_async.get("op", "?")))
				else:
					var blabel := str(blk.get("name", ""))
					if blabel == "":
						blabel = "wild"
					var bprog := _evo_poll_file(str(blk.get("progress", "")))
					var bep := "warming up"
					if not bprog.is_empty():
						bep = "ep %d/%d" % [int(bprog.get("episode", 0)), int(_prog_total(bprog))]
					_show_evo_phase("BREEDING " + display0,
						"Queued behind %s (%s)..." % [blabel, bep])
				await get_tree().create_timer(2.0).timeout
				swait += 2.0
				_evo_adopt_finished()
				tdir = _director()
			if tdir == null:
				evo_await_spec = {}
				return ""
			if not tdir.pending_async.is_empty():
				_show_evo_phase("BREEDING " + display0,
					"Training slot never freed - check brains/jobs log")
				evo_await_spec = {}
				return ""
			if not _evo_spawn_spec(s):
				_show_evo_phase("BREEDING " + display0,
					"Breed failed to start: %s" % evo_last_spawn_error)
				evo_await_spec = {}
				return ""
		# Fresh spawns and watcher-launched jobs alike: the await loop's
		# liveness gate and kill path key off evo_breed_pid.
		evo_breed_pid = int(s.get("pid", 0))
		var sname := str(s.get("name", ""))
		var display := sname if sname != "" else "wild"
		var bred := await _evo_await_result(display,
			str(s.get("progress", "")), str(s.get("result", "")),
			int(s.get("seed", -1)))
		if bred != "":
			var done := _evo_done()
			done[kind] = {"id": bred, "name": evo_last_bred_name}
			_evo_save_queue(_evo_pending(), done)
		evo_await_spec = {}
		return bred
	return ""


func _evo_abort(reason: String) -> void:
	var director := _director()
	if director != null:
		# Freeze, don't wipe: pending/done stay as forensic evidence
		# (a wiped queue once hid a whole failed generation).
		if not director.tourney.has("evo"):
			director.tourney["evo"] = {}
		var evo: Dictionary = director.tourney["evo"]
		evo["active"] = false
		director.save_state()
	evo_await_spec = {}
	_hide_nextgen()
	_hide_evo_phase()
	if is_instance_valid(status_label):
		status_label.text = "CONTINUOUS STOPPED: %s" % reason
	print("[Arena] CONTINUOUS STOPPED: %s" % reason)


func _on_evo_stop() -> void:
	if not _evo_active() and not evo_waiting:
		if is_instance_valid(status_label):
			status_label.text = "Continuous tournament loop is not running."
		return
	_evo_kill_job()
	_restore_timescale()
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
	evo_await_spec = {}
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
	_set_combat(false)
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
