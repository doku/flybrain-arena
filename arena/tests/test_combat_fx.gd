extends SceneTree
## Headless combat-FX tests: health rings, ember bursts, vignette and
## the KO-shockwave lifecycle on the REAL arena scene (seconds, not a
## full live round). Run: godot --headless --path arena -s tests/test_combat_fx.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var tick := 0
var _rec_stage := 0
var _rec_ready_tick := 0
var _rec_armed := false
var _rec_old_tourney: Dictionary = {}
var _rec_old_dir := ""
var _tests_done := false
var _callout_fire_at := 0
var _callout_watch := false
var _callout_bad := false
var _callout_until := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_builds() -> void:
	# Built by the real _ready (same path as the game).
	_check(is_instance_valid(arena.ring_alpha), "alpha ring node built")
	_check(is_instance_valid(arena.ring_beta), "beta ring node built")
	_check(arena.ring_mat_alpha.shader != null, "alpha ring shader bound")
	_check(is_instance_valid(arena.hit_bursts["alpha"]), "alpha hit burst built")
	_check(is_instance_valid(arena.hit_bursts["beta"]), "beta hit burst built")
	_check(is_instance_valid(arena.ko_bursts["alpha"]), "alpha KO burst built")
	_check(is_instance_valid(arena.ko_bursts["beta"]), "beta KO burst built")
	_check(arena.get_node_or_null("VignetteLayer") != null, "vignette layer built")
	_check(arena.hit_bursts["alpha"].amount == 14 and arena.ko_bursts["alpha"].amount == 42,
		"burst sizes 14/42")
	var acol: Color = arena.hit_bursts["alpha"].draw_pass_1.material.albedo_color
	var bcol: Color = arena.hit_bursts["beta"].draw_pass_1.material.albedo_color
	_check(acol.is_equal_approx(Color(1.0, 0.55, 0.30)), "alpha bleeds orange")
	_check(bcol.is_equal_approx(Color(0.4, 0.75, 1.0)), "beta bleeds blue")
	_check(arena.fly_alpha.body_std_mat != null, "alpha team tint bound")
	_check(arena.fly_alpha.eye_mat != null, "alpha eye shader bound")
	_check(arena.fly_beta.membrane_mat != null, "beta wing shader bound")


func test_hit_feedback_path() -> void:
	arena._hit_feedback("alpha", "beta", "thorax")
	_check(arena.hit_bursts["beta"].emitting, "victim team burst emitting after strike")
	_check(not arena.hit_bursts["alpha"].emitting, "attacker burst stays dark")
	_check(arena.fly_beta.flash_energy == 1.0, "victim flash energy 1.0")
	_check(arena.stats_alpha["damage_dealt"] == 0.0,
		"no sim stat touched by FX path")


func test_stats_flash_path() -> void:
	# Strike flash lives on the HUD stat cards (never fullscreen):
	# victim side tints red, attacker cream; hidden cards fall back
	# to the health-row names; unknown sides no-op.
	arena._apply_pip_slot()
	var red := Color(1.0, 0.35, 0.35)
	arena.pip_name_alpha.visible = true
	arena.pip_stats_alpha.visible = true
	arena.pip_name_beta.visible = true
	arena.pip_stats_beta.visible = true
	_check(arena.pip_flash_beta.color.a == 0.0, "wash starts transparent")
	arena._flash_fighter_card("beta", red)
	_check(arena.pip_name_beta.modulate.is_equal_approx(red),
		"victim name tints red")
	_check(arena.pip_stats_beta.modulate.is_equal_approx(red),
		"victim body tints red")
	_check(arena.pip_flash_beta.color.a > 0.0, "victim wash covers card")
	_check(arena.pip_flash_beta.color.r < 0.6
		and arena.pip_flash_beta.color.b > 0.9,
		"victim wash is team blue")
	_check(arena.pip_name_alpha.modulate.is_equal_approx(Color.WHITE),
		"attacker card untouched by victim flash")
	arena._flash_fighter_card("alpha", red)
	_check(arena.pip_flash_alpha.color.r > 0.9
		and arena.pip_flash_alpha.color.g < 0.7,
		"attacker wash reads orange team color")
	var sibs: Array = arena.pip_flash_beta.get_parent().get_children()
	_check(sibs.find(arena.pip_flash_beta) < sibs.find(arena.pip_name_beta)
		and sibs.find(arena.pip_name_beta) < sibs.find(arena.pip_stats_beta),
		"wash sits behind name and body")
	arena.pip_name_alpha.visible = false
	arena.pip_stats_alpha.visible = false
	arena.pip_name_beta.visible = false
	arena.pip_stats_beta.visible = false
	arena._flash_fighter_card("alpha", red)
	_check(arena.alpha_row_name.modulate.is_equal_approx(red),
		"hidden cards fall back to health-row name")
	arena._flash_fighter_card("gamma", red)
	_check(true, "unknown side no-ops without error")


func test_server_error_routing() -> void:
	# An explicit server error during an awaited battle retries once
	# (same id), then lands the SERVER ERROR overlay instead of
	# hanging in REPORTING until the watchdog gives up.
	arena._seq_context = "battle"
	arena._seq_battle_id = "R9M9-B9"
	arena._tourney_awaiting_battle = true
	arena._seq_retried = false
	arena._seq_last_round = {"stats_a": {}, "stats_b": {},
		"draw": false, "tournament_id": "T9", "match": "R9M9",
		"flight_a": {}, "flight_b": {}, "end_reason": "ko",
		"verdict": {}}
	arena._on_server_error("boom")
	_check(arena._seq_retried, "first error retries same id")
	_check(arena._tourney_awaiting_battle, "still awaiting after retry")
	arena._on_server_error("boom again")
	_check(not arena._tourney_awaiting_battle, "second error stands down")
	_check(str(arena.status_label.text).begins_with("SERVER ERROR"),
		"overlay names the server error")


func test_wait_bracket_flow() -> void:
	# Server waits show the bracket with a squeezed outcome header
	# (same strings/colors), never a bare arena; replies auto-hide
	# only auto-opened views, never the user's manual bracket.
	arena._build_bracket_overlay()
	_check(not arena.wait_title.visible, "wait header hidden initially")
	arena._set_wait_header("X WINS BY KO", "Killing blow: THORAX",
		Color(1.0, 0.55, 0.3))
	_check(arena.wait_title.visible, "header shows on set")
	_check(arena.wait_title.text == "X WINS BY KO", "header title text")
	_check(arena.wait_title.get_theme_color("font_color").is_equal_approx(
		Color(1.0, 0.55, 0.3)), "header keeps winner color")
	_check(arena.wait_sub.visible, "sub shows on set")
	arena._wait_bracket = true
	arena._hide_wait_bracket()
	_check(not arena.wait_title.visible, "auto-hide clears header")
	_check(arena.wait_title.text == "", "auto-hide clears text")
	_check(not arena._wait_bracket, "auto-hide drops the flag")
	arena._set_wait_header("T", "S", Color.WHITE)
	arena._wait_bracket = false
	arena._hide_wait_bracket()
	_check(arena.wait_title.visible, "manual bracket never auto-hidden")
	arena.wait_title.visible = false
	arena.wait_sub.visible = false
	_check(arena._show_wait_bracket("T1  A vs B"), "wait bracket opens")
	_check(arena.bracket_overlay.visible, "overlay visible on wait")
	_check(arena._wait_bracket, "auto flag set on wait open")
	arena._hide_wait_bracket()
	_check(not arena.bracket_overlay.visible, "reply hides auto wait view")
	# Outcome-on-bracket: countdown above, ownership kept, preview.
	arena._build_bracket_overlay()
	_check(arena.winner_overlay.get_index() > arena.bracket_overlay.get_index(),
		"countdown draws above bracket")
	arena._show_wait_bracket("T2  C vs D")
	arena._wait_bracket = true
	arena._show_wait_bracket("T2  C vs D")
	_check(arena._wait_bracket, "re-show keeps wait ownership")
	var bv = arena.arena_bracket
	var m := {"a_name": "A", "b_name": "B", "wins_a": 0.0, "wins_b": 0.0}
	bv.live_preview = {"round": 0, "match": 0, "winner_slot": "alpha"}
	var card: PanelContainer = bv.call("_make_match_card", m, 0, 0, true)
	var rows = card.get_child(0)
	var nmA: Label = rows.get_child(1).get_child(0)
	# Score is the row's last child (the red showcase asterisk sits
	# between name and score).
	var scA: Label = rows.get_child(1).get_child(2)
	_check(nmA.text == "A", "preview keeps winner name")
	_check((nmA.get_theme_color("font_color") as Color).is_equal_approx(
		Color(0.5, 1.0, 0.55)), "preview tints winner green")
	_check(scA.text == "1", "preview bumps winner score")
	var nmB: Label = rows.get_child(2).get_child(0)
	var scB: Label = rows.get_child(2).get_child(2)
	_check((nmB.get_theme_color("font_color") as Color).is_equal_approx(
		Color(0.92, 0.92, 0.94)), "preview leaves loser default")
	_check(scB.text == "0", "preview leaves loser score")
	bv.live_preview = {"round": 5, "match": 0, "winner_slot": "alpha"}
	var card2: PanelContainer = bv.call("_make_match_card", m, 0, 0, true)
	var nmA2: Label = card2.get_child(0).get_child(1).get_child(0)
	_check((nmA2.get_theme_color("font_color") as Color).is_equal_approx(
		Color(0.92, 0.92, 0.94)), "preview ignores other cards")
	bv.live_preview = {}
	var card3: PanelContainer = bv.call("_make_match_card", m, 0, 0, true)
	var nmA3: Label = card3.get_child(0).get_child(1).get_child(0)
	var scA3: Label = card3.get_child(0).get_child(1).get_child(2)
	_check((nmA3.get_theme_color("font_color") as Color).is_equal_approx(
		Color(0.92, 0.92, 0.94)), "cleared preview restores color")
	_check(scA3.text == "0", "cleared preview restores score")
	arena._hide_wait_bracket()


func test_shock_lifecycle() -> void:
	# KO shockwave runs 0.01 -> 1.0 exactly once, then parks at 0.
	# (Regression: it used to advance unconditionally and ripple forever.)
	arena.ring_shock_alpha = 0.01
	for i in range(100):
		arena._update_combat_fx(0.016)
	_check(arena.ring_shock_alpha == 0.0, "shock completes and parks at 0")
	for i in range(10):
		arena._update_combat_fx(0.016)
	_check(arena.ring_shock_alpha == 0.0, "no perpetual ripple without KO")
	_check(float(arena.ring_mat_alpha.get_shader_parameter("shock")) == 0.0,
		"shock uniform 0 at rest")


func test_combat_gate() -> void:
	# Intermission clinches must not bleed: with combat closed,
	# damage/tears/KOs are all no-ops; reopened, damage applies.
	var fa = arena.fly_alpha
	arena._set_combat(false)
	var h0: float = fa.health
	fa.take_damage(25.0, "test")
	_check(fa.health == h0, "take_damage gated outside rounds")
	fa.tear_wing("left")
	_check(fa.left_wing_intact, "tear gated outside rounds")
	fa.inflict_lethal_strike()
	_check(not fa.is_disabled, "KO gated outside rounds")
	arena._set_combat(true)
	fa.take_damage(10.0, "test")
	_check(fa.health == h0 - 10.0, "damage applies in rounds")
	fa.health = h0


func test_ko_burst_path() -> void:
	# Same two lines the KO handler runs (burst + shock seed).
	arena._fire_burst(arena.ko_bursts["alpha"], arena.fly_alpha.global_position)
	arena.ring_shock_alpha = 0.01
	_check(arena.ko_bursts["alpha"].emitting, "KO burst emitting")
	_check(arena.ring_shock_alpha > 0.0, "KO shock seeded")


func test_pierce_only_on_kill() -> void:
	# Pierce-through arms only on a killing blow; glancing hits
	# retract normally. Held spear reads full reach.
	var atk = arena.fly_alpha
	var vic = arena.fly_beta
	vic.is_disabled = false
	atk.spear_pierce = false
	_check(not atk._note_pierce_if_lethal(vic), "live victim never pierces")
	_check(not atk.spear_pierce, "flag stays clear on glance")
	vic.is_disabled = true
	_check(atk._note_pierce_if_lethal(vic), "lethal strike pierces")
	_check(atk.spear_pierce, "flag holds after kill")
	_check(absf(atk._spear_extension() - atk.LUNGE_DIST) < 0.001,
		"pierced spear reads full reach")
	vic.is_disabled = false
	atk.spear_pierce = false


func test_pierce_releases_realtime() -> void:
	# Held through the slow-mo finish, released the frame real time
	# resumes (no manager coupling to get stuck).
	var atk = arena.fly_alpha
	atk.spear_pierce = true
	Engine.time_scale = 0.25
	atk._check_pierce_hold()
	_check(atk.spear_pierce, "holds through slow-mo")
	Engine.time_scale = 1.0
	atk._check_pierce_hold()
	_check(not atk.spear_pierce, "releases at real time")


func test_pip_stats_layering() -> void:
	# Stat cards are created under the bracket overlay (never on top
	# of the popup) and toggle with the slot mode.
	arena.pip_slot_mode = "STATS"
	arena._apply_pip_slot()
	_check(arena.pip_stats_alpha != null, "stats label created")
	var hud: Node = arena.get_node("HUD")
	var kids: Array = hud.get_children()
	var si: int = kids.find(arena.pip_stats_alpha)
	var oi: int = kids.find(arena.bracket_overlay)
	_check(oi == -1 or si < oi, "stats behind bracket overlay")
	arena.pip_slot_mode = "EYES"
	arena._apply_pip_slot()


func test_pip_slot_visibility() -> void:
	# STATS hides the viewport boxes (no frozen eye frames behind the
	# stat cards); EYES/BRAIN keep them. Brain mode forces clouds on.
	arena.pip_slot_mode = "STATS"
	arena._apply_pip_slot()
	_check(not arena.pip_alpha_box.visible, "stats hides eye box")
	_check(not arena.pip_beta_box.visible, "stats hides beta box")
	_check(arena.pip_stats_alpha.visible, "stats card shows in slot")
	arena.pip_slot_mode = "BRAIN"
	arena._apply_pip_slot()
	_check(arena.pip_alpha_box.visible, "brain keeps box")
	_check(arena.bv_cloud_alpha.visible, "brain forces cloud on")
	arena.pip_slot_mode = "EYES"
	arena._apply_pip_slot()
	_check(arena.pip_alpha_box.visible, "eyes restore box")
	_check(not arena.pip_stats_alpha.visible, "eyes hide stat card")


func test_loser_drops_faster() -> void:
	# Loser ceremony sinks at LOSER_SINK_RATE (5.5 m/s), not the old
	# gentle 3.0.
	var vic = arena.fly_beta
	vic.landing_mode = 1
	vic.global_position.y = 10.0
	vic._landing_step(1.0)
	_check(absf(vic.global_position.y - 4.5) < 0.05, "loser sinks 5.5 m/s")
	vic.landing_mode = 0


func _initialize() -> void:
	# Quarantine: no packet from this suite may reach any server (a
	# headless arena boot used to free_mode the LIVE tournament).
	load("res://scripts/BrainClient.gd").test_mute = true
	var scene = load("res://scenes/ArenaGlade.tscn")
	arena = scene.instantiate()
	root.add_child(arena)


func test_ko_flash_clears_attacker() -> void:
	# KO reads single-sided: the killing strike's feedback flashed both
	# cards, then the KO handler clears the attacker dead (tween
	# killed, wash zeroed, labels white, body glow zeroed) - only the
	# fly that got hurt keeps flashing.
	arena._apply_pip_slot()
	arena.pip_name_alpha.visible = true
	arena.pip_stats_alpha.visible = true
	arena.pip_name_beta.visible = true
	arena.pip_stats_beta.visible = true
	# Simulate the killing strike's _hit_feedback pair:
	arena._flash_fighter_card("beta", Color(1.0, 0.35, 0.35), 0.5)
	arena._flash_fighter_card("alpha", Color(1.0, 0.95, 0.75), 0.22)
	arena._flash_body(arena.fly_alpha, 0.6)
	arena._flash_body(arena.fly_beta, 1.0)
	_check(arena.pip_flash_alpha.color.a > 0.0, "attacker wash up from strike")
	_check(arena.pip_flash_beta.color.a > 0.0, "victim wash up from strike")
	_check(arena.fly_alpha.flash_energy > 0.0, "attacker glow up from strike")
	# The KO: victim flash + attacker clear (what _on_fly_knocked_out runs).
	arena._flash_fighter_card("beta", Color(1.0, 0.25, 0.25), 0.75)
	arena._clear_fighter_card("alpha")
	_check(arena.pip_flash_alpha.color.a == 0.0, "attacker wash zeroed at KO")
	_check(arena.pip_flash_beta.color.a > 0.0, "victim wash keeps flashing")
	_check(arena.pip_name_alpha.modulate.is_equal_approx(Color.WHITE),
		"attacker labels back to white")
	_check(arena.fly_alpha.flash_energy == 0.0, "attacker body glow zeroed")
	_check(arena.fly_beta.flash_energy > 0.0, "victim glow untouched")
	var twA = arena._pip_wash_tween.get("alpha")
	_check(twA == null or not (twA as Tween).is_valid(),
		"attacker wash tween killed")
	var twB = arena._pip_wash_tween.get("beta")
	_check(twB != null and (twB as Tween).is_valid(),
		"victim wash tween still running")
	arena.pip_name_alpha.visible = false
	arena.pip_stats_alpha.visible = false
	arena.pip_name_beta.visible = false
	arena.pip_stats_beta.visible = false


func test_brains_loaded_accept() -> void:
	# Match-echo validation, accept side (real scene: the accept path
	# proceeds into _reset_round, which needs real flies): a matching
	# echo starts the round; a no-echo reply (old server) passes too.
	arena.tournament_active = true
	arena._seq_context = "load"
	arena.tourney_awaiting_load = true
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._on_brains_loaded({}, {}, "T1", "R1M1")
	_check(not arena.tourney_awaiting_load, "matching echo accepted")
	_check(str(arena._seq_context) == "", "accept cleared the load context")
	# (The round itself starts after _reset_round's landing await - the
	# single-starter rule; not asserted synchronously here.)
	arena._seq_context = "load"
	arena.tourney_awaiting_load = true
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._on_brains_loaded({}, {})
	_check(not arena.tourney_awaiting_load, "old-server no-echo accepted")


func test_load_fail_loud_clears_latch() -> void:
	# The fail-loud screen clears the load latch: a late reply can
	# never silently start a round behind it.
	arena.tournament_active = true
	arena._seq_context = "load"
	arena._seq_retried = true
	arena._seq_deadline_msec = 1
	arena.tourney_awaiting_load = true
	arena._check_seq_watchdog()
	_check(not arena.tourney_awaiting_load, "fail-loud clears the load latch")


func test_match_over_sends_report() -> void:
	# ONE bank per match: match over stamps the nonce, flushes the
	# cache into the report, arms the matchbank watchdog (no
	# per-battle sends happened).
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._match_battle_cache = [{"battle_id": "R1M1-B1-1-1", "draw": false,
		"verdict": {"winner_slot": "alpha"}}]
	arena._last_verdict = {"end_reason": "ko", "winner_slot": "alpha",
		"blow_source": "thorax", "blow_amount": 80.0,
		"loser_slot": "beta", "line": "X"}
	arena._on_match_over("alpha", "1 - 0")
	_check(arena._last_match_winner == "alpha", "match winner stored")
	_check(arena._last_match_score == "1 - 0", "match score stored")
	_check(str(arena._seq_match_id) != "", "match nonce stamped")
	_check((arena._match_battle_cache as Array).is_empty(),
		"cache flushed into the report")
	_check(arena._tourney_awaiting_matchbank, "match bank awaited")
	_check(str(arena._seq_context) == "matchbank", "matchbank watchdog armed")


func test_forgivable_matchbank() -> void:
	# Post-fail-loud bank acks apply only for the still-owed match.
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._seq_forgive_matchbank = {}
	_check(not arena._forgivable_matchbank("X"), "nothing owed, nothing forgiven")
	arena._seq_forgive_matchbank = {"tournament_id": arena._tourney_id(),
		"match": "R1M1", "battle": "M1"}
	_check(arena._forgivable_matchbank("M1"), "owed ack forgiven")
	_check(not arena._forgivable_matchbank("M2"), "other ack dropped")
	arena._tourney_awaiting_matchbank = false
	arena._seq_forgive_matchbank = {}
	arena._on_match_banked("alpha", 0.0, 0.0, "X")
	_check(not arena._tourney_awaiting_matchbank, "stray bank ack drops clean")


func test_matchbank_retry() -> void:
	# The matchbank watchdog resends the SAME nonce once (idempotent),
	# then the fail-loud takes its normal path.
	arena.tournament_active = true
	arena._seq_context = "matchbank"
	arena._seq_retried = false
	arena._seq_deadline_msec = 1
	arena._seq_last_match_report = {"match_winner": "alpha",
		"tournament_id": "T1", "match": "R1M1", "match_id": "R1M1-MATCH-1-2",
		"partial": false, "battles": []}
	arena._check_seq_watchdog()
	_check(arena._seq_retried, "matchbank retry fires once")


func test_server_brain_loss_reloads() -> void:
	# Server restarted mid-match: the brainless-reset error triggers a
	# self-healing reload of the current match (capped) instead of the
	# fail-loud that used to kill the tournament on screen.
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._seq_context = "reset"
	arena._server_reloads = 0
	arena._on_server_error(
		"match_reset: no tournament brains loaded (server restarted?) - QUIT")
	_check(arena._server_reloads == 1, "brain-loss error reloads once")
	arena._server_reloads = 2
	arena._seq_context = "reset"
	arena._on_server_error(
		"match_reset: no tournament brains loaded (server restarted?) - QUIT")
	_check(arena._server_reloads == 2, "reload cap holds past the max")
	_check(str(arena.status_label.text).begins_with("SERVER ERROR"),
		"past-cap error still lands loud")
	arena._server_reloads = 0
	arena._seq_context = "reset"
	arena._on_server_error("some other failure")
	_check(arena._server_reloads == 0, "unrelated errors never reload")


func test_motors_slot() -> void:
	# MOTORS PiP slot: debug widgets show, eye views hide; the cards
	# refresh from the last command; the silence badge flips on a
	# quiet streak; STATS restores the old visibility.
	# Layering: lazily built motor widgets must sit BELOW the bracket
	# overlay (which itself stays below the WinnerOverlay callouts) -
	# otherwise the debug card draws on top of the bracket view.
	arena._build_bracket_overlay()
	arena.pip_slot_mode = "MOTORS"
	arena._apply_pip_slot()
	_check(arena.pip_motor_bars_alpha.size() == 4, "motor bars built")
	var bar0: ProgressBar = arena.pip_motor_bars_alpha[0]
	_check(bar0.visible, "motor bars show in MOTORS")
	_check(arena.pip_motor_trace_alpha.visible, "trace shows in MOTORS")
	_check(not arena.pip_alpha_box.visible, "views hide in MOTORS")
	var bi: int = arena.bracket_overlay.get_index()
	var below := true
	for w in arena.pip_motor_bars_alpha + arena.pip_motor_bars_beta \
			+ [arena.pip_motor_trace_alpha, arena.pip_motor_trace_beta,
				arena.pip_motor_scope_alpha, arena.pip_motor_scope_beta]:
		if is_instance_valid(w) and (w as Node).get_index() >= bi:
			below = false
	_check(below, "motor widgets below the bracket overlay")
	_check(arena.bracket_overlay.get_index()
		< arena.winner_overlay.get_index(),
		"bracket overlay stays below the callouts")
	arena._last_ctrl_a = {"thrust": 0.5, "yaw_torque": -0.4,
		"pitch_torque": 0.0, "roll_torque": 0.0}
	arena._update_motor_cards()
	_check(str(arena.pip_stats_alpha.text).contains("THR 0.50"),
		"motor text refreshes")
	_check(absf(float(bar0.value) - 0.5) < 0.001, "motor bars refresh")
	for i in range(10):
		arena._push_motor_sample("alpha", {}, {"spikes": 0})
	arena._update_motor_cards()
	_check(str(arena.pip_stats_alpha.text).contains("SILENT"),
		"silence badge shows")
	arena.pip_slot_mode = "STATS"
	arena._apply_pip_slot()
	_check(not bar0.visible, "motor bars hide outside MOTORS")
	_check(not arena.pip_motor_trace_alpha.visible,
		"trace hides outside MOTORS")


func test_matchbank_brain_loss_resends() -> void:
	# Server restart killed the bank: the free-mode error arms a
	# stored-report resend (flag + reload, capped); the reload landing
	# resends WITHOUT starting a round (the match is over).
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._seq_context = "matchbank"
	arena._server_reloads = 0
	arena._pending_matchbank_resend = false
	arena._seq_last_match_report = {"match_winner": "alpha",
		"tournament_id": "T1", "match": "R1M1", "match_id": "M1",
		"partial": false, "battles": []}
	arena._on_server_error(
		"match_report while in FREE mode - QUIT TO MENU + RESUME")
	_check(arena._pending_matchbank_resend, "bank-loss error arms resend")
	_check(arena._server_reloads == 1, "bank-loss reload counted")
	# Reload landing: re-arms the bank from the stored report, no round.
	arena._seq_context = "load"
	arena.tourney_awaiting_load = true
	arena.is_round_active = false
	arena._on_brains_loaded({}, {})
	_check(not arena._pending_matchbank_resend, "resend flag consumed")
	_check(arena._tourney_awaiting_matchbank, "bank re-armed after reload")
	_check(str(arena._seq_context) == "matchbank", "matchbank watchdog back")
	_check(not arena.is_round_active, "reload landing starts no round")
	# Cap: past-max errors land loud, flag stays down.
	arena._server_reloads = 2
	arena._seq_context = "matchbank"
	arena._on_server_error(
		"match_report while in FREE mode - QUIT TO MENU + RESUME")
	_check(not arena._pending_matchbank_resend, "capped bank error no resend")
	_check(str(arena.status_label.text).begins_with("SERVER ERROR"),
		"capped bank error still lands loud")


func test_callout_static() -> void:
	# Informational banners (empty prefix, e.g. GROUP COMPLETE) hold
	# statically: no " IN 3..." countdown, no FIGHT! Fired on a delay
	# so the free-boot phantom REMATCH (first ~5 s wall) is done first;
	# the watch then samples the label every tick until the overlay
	# hides (~2 s).
	_callout_fire_at = Time.get_ticks_msec() + 8000


func _watch_callout_tick() -> void:
	# Samples the callout label every tick while an informational
	# banner plays; clears (with the verdict) when the overlay hides
	# or the wall deadline passes.
	if is_instance_valid(arena.countdown_label):
		var t := str(arena.countdown_label.text)
		if t.contains(" IN ") or t == "FIGHT!":
			_callout_bad = true
	if (is_instance_valid(arena.winner_overlay) and not arena.winner_overlay.visible) \
			or Time.get_ticks_msec() > _callout_until:
		_callout_watch = false
		_check(not _callout_bad, "static callout never counts down")


func test_handoff_failure_view() -> void:
	# Handoff failures park on FINAL REVIEW with the reason, never on
	# a bare arena. (The timed quit lives in the callers, untouched
	# here so the scene survives the suite.)
	var d = arena._director()
	var old_tourney: Dictionary = {}
	var old_dir := ""
	if d != null:
		old_tourney = d.tourney
		old_dir = d.tournament_dir
		d.tournament_dir = "user://test_failview"
		DirAccess.make_dir_recursive_absolute("user://test_failview")
	arena._show_handoff_failure("FINAL REVIEW - TEST", "unit test reason")
	_check(arena.bracket_overlay.visible, "failure parks on the bracket")
	_check(str(arena.status_label.text).contains("unit test reason"),
		"failure names the reason")
	arena._hide_arena_bracket()
	if d != null:
		d.tourney = old_tourney
		d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_failview"):
		for f in DirAccess.get_files_at("user://test_failview"):
			DirAccess.remove_absolute("user://test_failview".path_join(f))
		DirAccess.remove_absolute("user://test_failview")


func test_tipoff_freshness() -> void:
	# Tip-off runs once per event: a fresh group-B file (quit during
	# its intermission, 0 battles banked) must NOT read as a brand-new
	# event, or the resume plays the 30 s mislabeled tip-off instead
	# of the 60 s resume intermission for the right group.
	var d = arena._director()
	if d == null:
		_check(true, "freshness skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_fresh"
	DirAccess.make_dir_recursive_absolute("user://test_fresh")
	var groups := {}
	for letter in ["A", "B", "C", "D"]:
		groups[letter] = {"players": [], "bracket_id": "",
			"standings": [], "done": letter == "A"}
	d.event_save({"id": "EFRESH", "status": "running", "generation": 1,
		"settings": {}, "groups": groups, "group_order": ["A", "B", "C", "D"],
		"final_id": "", "champion_id": "", "pool": [], "phase": "groups_B"})
	d.tourney = {"id": "TB", "format": "groups", "group": "B",
		"event_id": "EFRESH", "evo": {"active": true},
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a", "b_id": "b", "battles": 0}]]}
	_check(not arena._event_is_fresh(), "done groups defeat freshness")
	(groups["A"] as Dictionary)["done"] = false
	d.event_save({"id": "EFRESH", "status": "running", "generation": 1,
		"settings": {}, "groups": groups, "group_order": ["A", "B", "C", "D"],
		"final_id": "", "champion_id": "", "pool": [], "phase": "groups_A"})
	d.tourney = {"id": "TA", "format": "groups", "group": "A",
		"event_id": "EFRESH", "evo": {"active": true},
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a", "b_id": "b", "battles": 0}]]}
	_check(arena._event_is_fresh(), "untouched event 1 stays fresh")
	d.tourney = old_tourney
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_fresh"):
		for f in DirAccess.get_files_at("user://test_fresh"):
			DirAccess.remove_absolute("user://test_fresh".path_join(f))
		DirAccess.remove_absolute("user://test_fresh")


func test_bracket_record_contract() -> void:
	# The record capture must never yank a bracket another flow raised:
	# visible-on-entry -> showed=false -> no auto-hide. (Regression:
	# the un-awaited group record hid the intermission bracket ~2
	# frames after it appeared, leaving no bracket view for the whole
	# between-group countdown.) The PNG leg needs real frames, so its
	# assert lands in _finish_record_contract a few ticks later.
	var d = arena._director()
	if d == null:
		_check(true, "record contract skipped (no director)")
		return
	_rec_old_tourney = d.tourney
	_rec_old_dir = d.tournament_dir
	d.tournament_dir = "user://test_rec"
	DirAccess.make_dir_recursive_absolute("user://test_rec")
	d.tourney = {"id": "TESTREC", "rounds": [
		[{"a_id": "a1", "b_id": "b1", "a_name": "AA", "b_name": "BB"}]]}
	arena._show_arena_bracket("RECORD CONTRACT")
	_check(arena.bracket_overlay.visible, "bracket shown for record")
	arena._save_bracket_record(false)
	_check(arena.bracket_overlay.visible, "txt-only record keeps bracket up")
	_rec_armed = true
	arena._save_bracket_record(true)
	_rec_stage = 1
	_rec_ready_tick = tick + 8


func _finish_record_contract() -> void:
	# Assert + restore only when the async leg was armed (a no-director
	# run never stubbed the tourney, so there is nothing to assert and
	# restoring {} would clobber the real state). Summary + quit moved
	# to _process so the callout watch can finish alongside.
	if _rec_armed:
		_check(arena.bracket_overlay.visible,
			"png record never yanks a live bracket")
		var d = arena._director()
		if d != null:
			d.tourney = _rec_old_tourney
			d.tournament_dir = _rec_old_dir
	arena._hide_arena_bracket()
	if DirAccess.dir_exists_absolute("user://test_rec"):
		for f in DirAccess.get_files_at("user://test_rec"):
			DirAccess.remove_absolute("user://test_rec".path_join(f))
		DirAccess.remove_absolute("user://test_rec")


func _process(_delta: float) -> bool:
	tick += 1
	if _callout_fire_at != 0 and Time.get_ticks_msec() >= _callout_fire_at:
		_callout_fire_at = 0
		arena._show_callout("T", Color.WHITE, "S", "", false)
		_callout_watch = true
		_callout_bad = false
		_callout_until = Time.get_ticks_msec() + 8000
	if _callout_watch:
		_watch_callout_tick()
	if _rec_stage == 1:
		if tick < _rec_ready_tick:
			return false
		_rec_stage = 2
		_finish_record_contract()
	if _tests_done:
		if _rec_stage == 2 and _callout_fire_at == 0 and not _callout_watch:
			if failures == 0:
				print("ALL COMBAT-FX TESTS PASSED")
			else:
				printerr("COMBAT-FX TESTS: %d FAILURES" % failures)
			quit(failures)
			return true
		return false
	if tick < 3:
		return false
	test_builds()
	test_hit_feedback_path()
	test_stats_flash_path()
	test_ko_flash_clears_attacker()
	test_server_error_routing()
	test_brains_loaded_accept()
	test_load_fail_loud_clears_latch()
	test_match_over_sends_report()
	test_forgivable_matchbank()
	test_matchbank_retry()
	test_server_brain_loss_reloads()
	test_matchbank_brain_loss_resends()
	test_motors_slot()
	test_callout_static()
	test_handoff_failure_view()
	test_tipoff_freshness()
	test_wait_bracket_flow()
	test_shock_lifecycle()
	test_combat_gate()
	test_ko_burst_path()
	test_pip_stats_layering()
	test_pierce_only_on_kill()
	test_pierce_releases_realtime()
	test_loser_drops_faster()
	test_pip_slot_visibility()
	test_bracket_record_contract()
	_tests_done = true
	# Un-armed (e.g. no director): finish now instead of re-running the
	# suite every frame - the old quit-at-tick-3 contract must hold on
	# every path.
	if _rec_stage == 0:
		_rec_stage = 2
		_finish_record_contract()
	return false
