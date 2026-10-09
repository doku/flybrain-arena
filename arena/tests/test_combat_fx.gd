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
var _hold_fire_at := 0
var _hold_watch := false
var _hold_seen := false
var _hold_fired_at := 0
var _hold_until := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _real_brain_pair(d) -> Array:
	# Two real vault brains (stub matches whose files EXIST, so load
	# pre-flights pass): the vault is read-only here. Empty when the
	# vault is short (callers skip).
	var real: Array = d.list_brains_cached()
	if real.size() < 2:
		return []
	return [real[0], real[1]]


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


func test_round_match_over_advances() -> void:
	# Per-match banking: match over sends the match (ids + battles)
	# into the pending table under its deterministic nonce, clears
	# the battle cache, and advances LOCALLY - no round payload, no
	# bank latch mid-round (those wait for the round boundary).
	var d = arena._director()
	if d == null:
		_check(true, "round advance skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_roundadv"
	DirAccess.make_dir_recursive_absolute("user://test_roundadv")
	d.tourney = {"id": "TR", "status": "running",
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a1", "b_id": "b1", "a_name": "A",
			"b_name": "B"},
			{"a_id": "c1", "b_id": "d1", "a_name": "C",
			"b_name": "D"}]]}
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._match_battle_cache = [{"battle_id": "R1M1-B1-1-1", "draw": false,
		"verdict": {"winner_slot": "alpha"}}]
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._on_match_over("alpha", "1 - 0")
	_check((arena._round_match_cache as Array).is_empty(),
		"match flows to the pending table, not the round cache")
	_check(arena._match_banks_pending.has(arena._current_match_nonce()),
		"match tracked under its deterministic nonce")
	_check((arena._match_battle_cache as Array).is_empty(),
		"battle cache cleared")
	_check(int(d.tourney.get("current_match", -1)) == 1,
		"bracket advanced locally")
	_check(not arena._tourney_awaiting_roundbank,
		"mid-round arms no bank")
	_check(not arena._round_bank_pending,
		"mid-round sets no round latch")
	arena._round_match_cache.clear()
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._hide_arena_bracket()
	d.tourney = old_tourney
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_roundadv"):
		for f in DirAccess.get_files_at("user://test_roundadv"):
			DirAccess.remove_absolute("user://test_roundadv".path_join(f))
		DirAccess.remove_absolute("user://test_roundadv")


func test_round_report_send() -> void:
	# ONE bank per round: round end stamps the nonce, flushes the round
	# cache into the report, arms the roundbank watchdog.
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._round_match_cache = [{"match_id": "R1M1-M1-1-1",
		"match_winner": "alpha", "battles": []}]
	arena._last_verdict = {"end_reason": "ko", "winner_slot": "alpha",
		"blow_source": "thorax", "blow_amount": 80.0,
		"loser_slot": "beta", "line": "X"}
	arena._send_round_report()
	_check(str(arena._seq_round_id) != "", "round nonce stamped")
	_check((arena._round_match_cache as Array).is_empty(),
		"round cache flushed into the report")
	_check(arena._tourney_awaiting_roundbank, "round bank awaited")
	_check(arena._round_bank_pending, "bank flag set")
	_check(str(arena._seq_context) == "roundbank", "roundbank watchdog armed")
	_check(not (arena._seq_last_round_report as Dictionary).is_empty(),
		"stored report kept for retry")


func test_forgivable_roundbank() -> void:
	# Post-fail-loud bank acks apply only for the still-owed round.
	arena.tournament_active = true
	arena._seq_forgive_roundbank = {}
	_check(not arena._forgivable_roundbank("X"), "nothing owed, nothing forgiven")
	arena._seq_forgive_roundbank = {"tournament_id": arena._tourney_id(),
		"match": "", "battle": "R1"}
	_check(arena._forgivable_roundbank("R1"), "owed ack forgiven")
	_check(not arena._forgivable_roundbank("R2"), "other ack dropped")
	arena._tourney_awaiting_roundbank = false
	arena._seq_forgive_roundbank = {}
	arena._on_round_banked("X", "", "")
	_check(not arena._tourney_awaiting_roundbank, "stray bank ack drops clean")


func test_roundbank_retry() -> void:
	# The roundbank watchdog resends the SAME nonce on every expiry
	# (idempotent ladder, never a battle reload): no recovery cycle,
	# no fail-loud, same id re-armed. Group twin rides the same rule.
	arena.tournament_active = true
	arena.brain_client.is_connected_server = true
	arena._seq_context = "roundbank"
	arena._seq_retried = false
	arena._seq_deadline_msec = 1
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = true
	arena._bank_retries = 0
	arena._bank_last_send_msec = 0
	arena._server_reloads = 0
	arena._seq_last_round_report = {"tournament_id": "T1",
		"match": "R1M1", "round_nonce": "RND-1-2",
		"matches": []}
	arena._check_seq_watchdog()
	_check(arena._bank_retries == 1, "roundbank watchdog resends same nonce")
	_check(arena._seq_round_id == "RND-1-2", "resend keeps the nonce")
	_check(arena._tourney_awaiting_roundbank, "still awaiting after resend")
	_check(arena._server_reloads == 0, "bank expiry never reloads")
	_check(str(arena._seq_context) == "roundbank", "watchdog re-armed")
	arena._seq_deadline_msec = 1
	arena._check_seq_watchdog()
	_check(arena._bank_retries == 2, "roundbank expiry resends again")
	_check(arena._server_reloads == 0, "second bank expiry still no reload")
	arena._seq_context = "groupbank"
	arena._seq_deadline_msec = 1
	arena._group_bank_pending = true
	arena._tourney_awaiting_groupbank = true
	arena._seq_last_group_report = {"tournament_id": "T1",
		"match": "R1M1", "group_nonce": "GRP-1-2"}
	arena._check_seq_watchdog()
	_check(arena._seq_group_id == "GRP-1-2", "group resend keeps its nonce")
	_check(arena._server_reloads == 0, "group expiry never reloads")
	arena._seq_context = ""
	arena._round_bank_pending = false
	arena._group_bank_pending = false
	arena._tourney_awaiting_roundbank = false
	arena._tourney_awaiting_groupbank = false
	arena._seq_last_round_report = {}
	arena._seq_last_group_report = {}
	arena._bank_retries = 0


func test_bank_tick_resends() -> void:
	# Owed-bank tick: a lost ack heals without any watchdog cycle -
	# and without the seq context a recovery cleared.
	arena.tournament_active = true
	arena.brain_client.is_connected_server = true
	arena._recover_in_flight = false
	arena._seq_context = ""
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = false
	arena._bank_retries = 0
	# Engine uptime in-suite is seconds: stamp the last send far in
	# the past so the 30 s cadence reads as due either way.
	arena._bank_last_send_msec = -60000
	arena._seq_last_round_report = {"tournament_id": "T1",
		"match": "R1M1", "round_nonce": "RND-9-9", "matches": []}
	arena._bank_resend_tick()
	_check(arena._bank_retries == 1, "tick resends the owed bank")
	_check(arena._seq_round_id == "RND-9-9", "tick keeps the nonce")
	_check(arena._tourney_awaiting_roundbank, "tick re-arms the wait")
	arena._bank_resend_tick()
	_check(arena._bank_retries == 1, "tick respects its cadence")
	arena._round_bank_pending = false
	arena._bank_last_send_msec = -60000
	arena._bank_retries = 0
	arena._bank_resend_tick()
	_check(arena._bank_retries == 0, "tick silent with no bank owed")
	arena._seq_last_round_report = {}
	arena._tourney_awaiting_roundbank = false


func test_late_bank_ack_after_recover_applies() -> void:
	# The semifinal-stall regression: a bank ack landing after a
	# recovery cleared the seq must still clear the owed latch
	# (forgive retained) instead of dropping as late/duplicate.
	var d = arena._director()
	if d == null:
		_check(true, "late ack skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	d.tourney = {"id": "T1"}
	arena.tournament_active = true
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = false
	arena._seq_round_id = "RND-9"
	arena._seq_forgive_roundbank = {"tournament_id": "T1",
		"match": arena.tourney_match_label, "battle": "RND-9"}
	arena._load_gated_on_bank = false
	arena._on_round_banked("RND-9", "T1", "R1M1")
	_check(not arena._round_bank_pending, "late ack clears the owed latch")
	_check(arena._seq_forgive_roundbank.is_empty(), "applied ack closes forgive")
	arena._seq_round_id = ""
	d.tourney = old_tourney


func test_recover_carries_owed_bank() -> void:
	# Recovery with a bank owed: the forgive window survives, the
	# stored-report resend arms, and the reload bypasses the bank
	# gate (the old code parked it: the exact semifinal stall).
	var d = arena._director()
	if d == null:
		_check(true, "recover bank skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var rpc: Array = _real_brain_pair(d)
	if rpc.is_empty():
		_check(true, "recover bank skipped (vault short)")
		return
	var ra: Dictionary = rpc[0]
	var rb: Dictionary = rpc[1]
	d.tourney = {"id": "TREC", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(ra.get("id", "")), "b_id": str(rb.get("id", "")),
			"a_name": "A", "b_name": "B"}]]}
	d.brains_cache = [ra, rb]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = false
	arena._seq_forgive_roundbank = {"tournament_id": "TREC",
		"match": "R1M1", "battle": "RND-7"}
	arena._seq_last_round_report = {"tournament_id": "TREC",
		"match": "R1M1", "round_nonce": "RND-7", "matches": []}
	arena._pending_roundbank_resend = false
	arena._load_gated_on_bank = false
	var ok: bool = arena._recover_server_state("unit test")
	_check(ok, "bank-owed recovery proceeds")
	_check(arena._pending_roundbank_resend, "owed bank arms its resend")
	_check(not arena._seq_forgive_roundbank.is_empty(), "owed bank keeps forgive")
	_check(not arena._load_gated_on_bank, "recovery load bypasses the gate")
	_check(arena.tourney_awaiting_load, "recovery load issued")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena._round_bank_pending = false
	arena._pending_roundbank_resend = false
	arena._seq_forgive_roundbank = {}
	arena._seq_last_round_report = {}
	arena._seq_context = ""
	arena.is_round_active = false
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec


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
	# Leg 1 armed a recovery; this suite skips its brains_loaded, so
	# reset the in-flight marker before the cap leg.
	arena._recover_in_flight = false
	arena._server_reloads = 2
	arena._seq_context = "reset"
	arena._on_server_error(
		"match_reset: no tournament brains loaded (server restarted?) - QUIT")
	_check(arena._server_reloads == 2, "reload cap holds past the max")
	_check(str(arena.status_label.text).begins_with("SERVER ERROR"),
		"past-cap error still lands loud")
	arena._server_reloads = 0
	arena._seq_context = "reset"
	arena._recover_in_flight = false
	arena._on_server_error("some other failure")
	_check(arena._server_reloads == 1, "unrelated errors recover too")
	arena._recover_in_flight = false


func test_step_pacing_gate() -> void:
	# Stop-and-wait: at most one step reply outstanding. The gate is
	# pure (timer + flag + link), so every branch is pinnable.
	arena.brain_tick_timer = 1.0
	arena._step_in_flight = false
	arena.brain_client.is_connected_server = true
	_check(arena._should_send_step(), "due + free + connected sends")
	arena._step_in_flight = true
	_check(not arena._should_send_step(), "in-flight blocks second send")
	arena._step_in_flight = false
	arena.brain_tick_timer = 0.0
	_check(not arena._should_send_step(), "timer ceiling holds below tick")
	arena.brain_tick_timer = 1.0
	arena.brain_client.is_connected_server = false
	_check(not arena._should_send_step(), "disconnected never flags a drop")
	arena.brain_client.is_connected_server = true
	arena._step_in_flight = false


func test_step_reply_clears_and_counts() -> void:
	# A reply frees the link and counts the applied pair; the HUD
	# shows n/srv so lost replies read as a gap.
	arena.is_round_active = true
	arena._step_in_flight = true
	arena._step_timeouts = 3
	var n0: int = arena._ctrl_n
	arena._on_motor_controls({}, {},
		1, {"step_seq": 41, "alpha": {"spikes": 1}, "beta": {"spikes": 1}})
	_check(not arena._step_in_flight, "reply clears in-flight")
	_check(arena._step_timeouts == 0, "reply resets timeout streak")
	_check(arena._ctrl_n == n0 + 1, "applied pair counted")
	_check(arena._ctrl_srv_seq == 41, "server seq recorded")
	arena._update_ctrl_label()
	_check(("n=%d" % (n0 + 1)) in arena.ctrl_label.text, "HUD shows applied n")
	_check("srv=41" in arena.ctrl_label.text, "HUD shows server srv")


func test_dead_round_reply_drops() -> void:
	# A straggler reply after the round ended replants nothing: no
	# fresh commands into finished flies (the post-timeout drift into
	# trees), no pollution of the banked accumulators. Only the
	# in-flight flag dies.
	arena.is_round_active = false
	arena._step_in_flight = true
	arena.fly_alpha.current_thrust = 0.77
	arena.fly_alpha.cmd_age = 5.0
	var n_before: int = arena._ctrl_n
	arena._on_motor_controls({"thrust": 1.0, "yaw_torque": 1.0},
		{"thrust": 1.0, "yaw_torque": -1.0},
		1, {"step_seq": 42, "alpha": {"spikes": 9}, "beta": {"spikes": 9}})
	_check(not arena._step_in_flight, "straggler still frees the flag")
	_check(absf(arena.fly_alpha.current_thrust - 0.77) < 0.001,
		"straggler replants no thrust")
	_check(arena.fly_alpha.cmd_age == 5.0, "straggler resets no clock")
	_check(arena._ctrl_n == n_before, "straggler counts no pair")
	arena.fly_alpha.current_thrust = 0.2
	arena.fly_alpha.cmd_age = 0.0
	arena._step_in_flight = false


func test_step_timeout_adapts() -> void:
	# Adaptive deadline: floor on a fast link, ~3x EMA on a slow
	# one (capped), flat grace for a round's first send. The fixed
	# 2 s deadline used to false-timeout every step on throttled
	# hardware (2.5 s service), wedging the link forever.
	var ob: int = arena._step_round_base
	var oo: int = arena._step_outstanding
	var os: int = arena._step_seq
	var orr: bool = arena._step_round_reply
	var oema: float = arena.bv_reply_ema
	arena._step_round_reply = true
	arena.bv_reply_ema = 0.2
	_check(arena._step_timeout_msec() == 2000, "fast link keeps the floor")
	arena.bv_reply_ema = 1.0
	_check(arena._step_timeout_msec() == 3000, "slow link scales by EMA")
	arena.bv_reply_ema = 10.0
	_check(arena._step_timeout_msec() == 15000, "runaway EMA caps out")
	arena._step_round_base = 5
	arena._step_seq = 5
	arena._step_outstanding = 6
	arena._step_round_reply = false
	_check(arena._step_timeout_msec() == 6000, "round's first send gets grace")
	arena._step_outstanding = 7
	arena.bv_reply_ema = 1.0
	_check(arena._step_timeout_msec() == 3000, "grace spends after first send")
	arena._step_round_base = ob
	arena._step_outstanding = oo
	arena._step_seq = os
	arena._step_round_reply = orr
	arena.bv_reply_ema = oema


func test_step_reconnect_gated() -> void:
	# Reconnect only on escalation: routine expiry just clears the
	# flag - rebinding every fire widowed the in-flight reply and fed
	# the server's 10054 storm. Pure gating, wall-clock injected.
	var ot: int = arena._step_timeouts
	var olr: int = arena._step_last_reconnect_msec
	arena._step_last_reconnect_msec = 0
	arena._step_timeouts = 3
	_check(not arena._step_should_reconnect(100000), "early fires never rebind")
	arena._step_timeouts = 5
	_check(arena._step_should_reconnect(100000), "escalation rebinds once")
	arena._step_timeouts = 7
	arena._step_last_reconnect_msec = 100000
	_check(not arena._step_should_reconnect(100000), "no rebind storm after")
	arena._step_last_reconnect_msec = 100000 - 11000
	_check(arena._step_should_reconnect(100000), "stuck link retries each 10 s")
	arena._step_timeouts = ot
	arena._step_last_reconnect_msec = olr


func test_stale_echo_drops() -> void:
	# Sequenced replies: a reply to an older send drops without
	# touching the flag (the newer send still owns it), the commands,
	# or the streak; the current echo applies normally.
	arena.is_round_active = true
	arena._step_outstanding = 10
	arena._step_in_flight = true
	arena._step_timeouts = 2
	arena._step_round_reply = false
	arena.fly_alpha.current_thrust = 0.77
	arena.fly_alpha.cmd_age = 5.0
	var n_before: int = arena._ctrl_n
	arena._on_motor_controls({"thrust": 1.0, "yaw_torque": 1.0},
		{"thrust": 1.0, "yaw_torque": -1.0},
		1, {"step_seq": 41, "step_echo": 7,
			"alpha": {"spikes": 1}, "beta": {"spikes": 1}})
	_check(arena._step_in_flight, "widowed reply frees no flag")
	_check(absf(arena.fly_alpha.current_thrust - 0.77) < 0.001,
		"widowed reply replants no thrust")
	_check(arena._ctrl_n == n_before, "widowed reply counts no pair")
	_check(arena._step_timeouts == 2, "widowed reply breaks no streak")
	_check(not arena._step_round_reply, "widowed reply hears nothing")
	arena._on_motor_controls({"thrust": 0.9, "yaw_torque": 0.0,
		"pitch_torque": 0.0, "roll_torque": 0.0},
		{"thrust": 0.9, "yaw_torque": 0.0,
			"pitch_torque": 0.0, "roll_torque": 0.0},
		1, {"step_seq": 42, "step_echo": 10,
			"alpha": {"spikes": 1}, "beta": {"spikes": 1}})
	_check(not arena._step_in_flight, "current echo frees the flag")
	_check(absf(arena.fly_alpha.current_thrust - 0.9) < 0.001,
		"current echo applies")
	_check(arena._ctrl_n == n_before + 1, "current echo counts the pair")
	_check(arena._step_round_reply, "current echo hears back")
	arena.fly_alpha.current_thrust = 0.2
	arena.fly_alpha.cmd_age = 0.0
	arena._step_in_flight = false
	arena._step_outstanding = 0


func test_step_watchdog_recovers_silently() -> void:
	# Lost reply: the flag clears so the next tick sends fresh state -
	# no modal, no wait-bracket, only a log line. Five in a row earns
	# status text (still non-blocking).
	arena.is_round_active = true
	arena._step_in_flight = true
	arena._step_deadline_msec = 1
	arena._step_timeouts = 0
	arena._check_step_watchdog()
	_check(not arena._step_in_flight, "expired step frees the link")
	_check(arena._step_timeouts == 1, "expiry counted")
	arena._step_in_flight = true
	arena._step_deadline_msec = 1
	arena._step_timeouts = 4
	arena._check_step_watchdog()
	_check(arena._step_timeouts == 5, "streak reaches five")
	_check("CONTROL LINK SLOW" in arena.status_label.text, "slow link named, not modal")
	arena._step_in_flight = true
	arena.is_round_active = false
	arena._check_step_watchdog()
	_check(not arena._step_in_flight, "round end disarms the flag")

func test_gallery_star() -> void:
	# The gallery names its showcased fighter exactly like the
	# bracket rows: cyan name + red star. Star shows whenever the
	# card carries a bracket key (the showcase condition), hides
	# otherwise - the two can never disagree. Overlay builds on
	# tournament entry, so build it here like the pip tests do.
	arena._build_bracket_overlay()
	arena._render_gallery_card({"title": "Dodger", "elo": "1312",
		"rows": "Titles 1", "key": "abc12345"})
	_check(arena.gallery_star.visible, "keyed card shows the star")
	_check(arena.gallery_star.get_theme_color("font_color").is_equal_approx(
		Color(1.0, 0.38, 0.3)), "star is marker red")
	arena._render_gallery_card({"title": "?", "elo": "--",
		"rows": "", "key": ""})
	_check(not arena.gallery_star.visible, "keyless card hides the star")

func test_idle_parks_loud() -> void:
	# Oct 2026 group-D phantom loop: a director that cannot place the
	# battle (tournament complete here) must park LOUD - no cache, no
	# session tally, no reset re-arm - instead of looping 0-0 battles.
	# Drives the legacy server-reply entry with an explicit idle res.
	arena._build_bracket_overlay()
	var n0: int = arena._match_battle_cache.size()
	var w0: int = arena.wins_alpha + arena.wins_beta
	arena._battle_post_sequence("alpha", {"action": "idle"})
	_check(arena._match_battle_cache.size() == n0, "idle caches nothing")
	_check(arena.wins_alpha + arena.wins_beta == w0, "idle counts no win")
	_check(arena._seq_context != "reset", "idle arms no reset")
	_check(arena.bracket_overlay.visible, "idle parks on the bracket")
	_check("QUIT TO MENU" in arena.status_label.text, "idle names the recipe")
	arena._hide_arena_bracket()


func test_idle_not_cached() -> void:
	# Same guard one level up: _battle_done_local consults the
	# director BEFORE caching, so a phantom never reaches the match
	# cache (banking one later would corrupt records). Past-end shell
	# mimics the completed group file; status complete alone suffices
	# (tournament_active() is status-gated).
	var d = arena._director()
	var old_tourney: Dictionary = (d.tourney as Dictionary).duplicate(true)
	d.tourney = {"id": "UT", "status": "complete", "format": "groups",
		"rounds": [[{"a_name": "A", "b_name": "B", "winner_id": "x"}]],
		"current_round": 0, "current_match": 0}
	var n0: int = arena._match_battle_cache.size()
	arena._last_sens_a = {}
	arena._last_sens_b = {}
	arena._last_ctrl_a = {}
	arena._last_ctrl_b = {}
	arena._battle_done_local(false)
	_check(arena._match_battle_cache.size() == n0, "phantom never cached")
	_check(arena._seq_context != "reset", "phantom arms no reset")
	_check("QUIT TO MENU" in arena.status_label.text, "phantom parks loud")
	d.tourney = old_tourney


func test_match_ready_refuses_ghosts() -> void:
	# A reset ack arriving after the director moved past the battle
	# must not start a ghost round (the phantom loop's suspected
	# seed): refused + parked loud instead.
	var d = arena._director()
	var old_tourney: Dictionary = (d.tourney as Dictionary).duplicate(true)
	var tact: bool = arena.tournament_active
	d.tourney = {"id": "UT", "status": "complete", "format": "groups",
		"rounds": [[{"a_name": "A", "b_name": "B", "winner_id": "x"}]],
		"current_round": 0, "current_match": 0}
	arena.tournament_active = true
	arena.is_round_active = false
	arena._seq_context = "reset"
	arena._on_match_ready()
	_check(not arena.is_round_active, "ghost reset starts no round")
	_check("QUIT TO MENU" in arena.status_label.text, "refusal parks loud")
	arena._seq_context = ""
	arena.tournament_active = tact
	d.tourney = old_tourney

func test_stats_survive_perf_off() -> void:
	# Eye-views OFF is a render saver, not a stats killer (Oct 2026:
	# a flipped eye-views toggle hid the whole PiP HUD including the
	# free stat cards). Cards stay visible with live text; viewports
	# stay hidden; everything restores when renders return.
	arena.pip_slot_mode = "STATS"
	arena.perf_pip = false
	arena._apply_pip_slot()
	_check(arena.pip_stats_alpha.visible, "stats card visible with renders off")
	_check(arena.pip_name_alpha.visible, "name row visible with renders off")
	_check(not arena.pip_alpha_box.visible, "viewport stays hidden with renders off")
	# Force the 1-in-6 refresh tick (throttle is intended behavior).
	arena._pip_tick = 5
	arena._update_pip_throttled({}, {})
	_check(str(arena.pip_stats_alpha.text) != "", "stats text refreshes with renders off")
	arena.perf_pip = true
	arena._update_pip_throttled({}, {})
	_check(arena.pip_stats_alpha.visible, "stats restore when renders return")
	_check(arena._pip_hidden == false, "hidden latch clears on return")

func test_intermission_header_band() -> void:
	# Dedicated top-margin band for the preview row: wraps (long rows
	# fold, never run off-edge) with a fixed floor, so per-second
	# countdown rewrites never resize the bracket below.
	arena._build_bracket_overlay()
	_check(arena.intermission_label.autowrap_mode != TextServer.AUTOWRAP_OFF,
		"header wraps")
	_check(arena.intermission_label.custom_minimum_size.y >= 50.0,
		"header band has a fixed floor")
	_check(not arena.intermission_row.visible, "header hidden until used")
	_check(arena.intermission_label.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
		"header label takes leftover row width (never 1px soup)")
	# Same disease class in the gallery title row (centered HBox with
	# buttons/markers): long fighter names must wrap, never stack.
	_check(arena.gallery_title.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
		"gallery title takes leftover row width")
	_check(arena.gallery_title.autowrap_mode != TextServer.AUTOWRAP_OFF,
		"gallery title wraps")
	# Bracket row holds a fixed floor so stacked header rows can never
	# squeeze it out of view; the scroll absorbs overflow internally.
	_check(arena.bracket_row.custom_minimum_size.y >= 380.0,
		"bracket row keeps its floor")

func test_group_report_send() -> void:
	# Group seal: minted GRP nonce, groupbank context armed, forgive
	# map stamped. State only (test_mute drops the packet).
	arena._send_group_report()
	_check(arena._tourney_awaiting_groupbank, "group bank awaited")
	_check(arena._group_bank_pending, "group bank pending")
	_check(str(arena._seq_group_id).begins_with("GRP-"), "GRP nonce minted")
	_check(arena._seq_context == "groupbank", "groupbank context armed")
	_check(not arena._seq_forgive_groupbank.is_empty(), "forgive map stamped")
	arena._tourney_awaiting_groupbank = false
	arena._group_bank_pending = false
	arena._seq_group_id = ""
	arena._seq_forgive_groupbank = {}
	arena._seq_last_group_report = {}
	arena._seq_context = ""


func test_group_banked_applies() -> void:
	# Group ack clears the wait; a foreign id without forgive data is
	# ignored, never applied.
	arena._tourney_awaiting_groupbank = true
	arena._group_bank_pending = true
	arena._seq_group_id = "GRP-1"
	arena._seq_forgive_groupbank = {"tournament_id": "", "match": "R3M2",
		"battle": "GRP-1"}
	arena._on_group_banked("GRP-9", "T")
	_check(arena._tourney_awaiting_groupbank, "mismatch keeps the wait")
	arena._on_group_banked("GRP-1", "T")
	_check(not arena._tourney_awaiting_groupbank, "ack clears awaiting")
	_check(not arena._group_bank_pending, "ack clears pending")
	_check(arena._seq_forgive_groupbank.is_empty(), "ack closes forgive")
	arena._seq_group_id = ""
	arena._seq_context = ""


func test_group_forgive_map() -> void:
	# Same-nonce post-fail-loud ack forgives; anything else does not.
	# Director file tag drives the tournament match (bare scene has
	# none, so stub it like the state-poll test does).
	var d = arena._director()
	var old_tourney: Dictionary = (d.tourney as Dictionary).duplicate(true)
	arena.tournament_active = true
	arena._seq_forgive_groupbank = {}
	_check(not arena._forgivable_groupbank("GRP-7"), "empty map refuses")
	d.tourney = {"id": "T1"}
	arena._seq_forgive_groupbank = {"tournament_id": "T1",
		"match": "R1M1", "battle": "GRP-7"}
	_check(arena._forgivable_groupbank("GRP-7"), "owed nonce forgives")
	_check(not arena._forgivable_groupbank("GRP-8"), "other nonce refuses")
	arena._seq_forgive_groupbank = {"tournament_id": "T2",
		"match": "R1M1", "battle": "GRP-7"}
	_check(not arena._forgivable_groupbank("GRP-7"), "other file refuses")
	arena._seq_forgive_groupbank = {}
	d.tourney = old_tourney


func test_round_report_group_flag() -> void:
	# Round reports out of group files carry group=true (server pins
	# instead of reloading); bracket files carry false.
	var d = arena._director()
	var old_tourney: Dictionary = (d.tourney as Dictionary).duplicate(true)
	d.tourney = {"id": "UT", "format": "groups"}
	arena._round_match_cache = [{"match_id": "M1"}]
	arena._send_round_report()
	_check(bool(arena._seq_last_round_report.get("group", false)),
		"group file flags its rounds")
	d.tourney = {"id": "UT", "format": "bracket"}
	arena._round_match_cache = [{"match_id": "M1"}]
	arena._send_round_report()
	_check(not bool(arena._seq_last_round_report.get("group", true)),
		"bracket file flags false")
	d.tourney = old_tourney
	arena._round_match_cache = []
	arena._tourney_awaiting_roundbank = false
	arena._round_bank_pending = false
	arena._seq_round_id = ""
	arena._seq_forgive_roundbank = {}
	arena._seq_last_round_report = {}
	arena._seq_context = ""

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


func test_overtake_fires_parked_load() -> void:
	# Round overtaken by its group bank is a CONFIRM, not a drop:
	# deferred chains drain and a parked load fires (an intermission
	# that expired mid-stall parks on the gate; nothing else
	# re-requests it after the overtake return).
	var d = arena._director()
	if d == null:
		_check(true, "overtake skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var pair: Array = _real_brain_pair(d)
	if pair.is_empty():
		_check(true, "overtake skipped (vault short)")
		return
	var r1: Dictionary = pair[0]
	var r2: Dictionary = pair[1]
	d.tourney = {"id": "TREC", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(r1.get("id", "")), "b_id": str(r2.get("id", "")),
			"a_name": "A", "b_name": "B"}]]}
	d.brains_cache = [r1, r2]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = true
	arena._seq_context = "roundbank"
	arena._seq_round_id = "RND-7"
	arena._seq_forgive_roundbank = {"tournament_id": "TREC",
		"match": "R1M1", "battle": "RND-7"}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._pending_roundbank_resend = false
	arena._seq_last_round_report = {"tournament_id": "TREC",
		"match": "R1M1", "round_nonce": "RND-7", "matches": []}
	arena._load_gated_on_bank = true
	arena._pending_advance = {"action": "next_match"}
	arena._on_server_error(
		"round_report: group already banked - QUIT TO MENU + RESUME")
	_check(not arena._round_bank_pending, "overtake stands the latch down")
	_check(arena._pending_advance.is_empty(), "overtake drains the chain")
	_check(not arena._load_gated_on_bank, "overtake fires the parked load")
	_check(arena.tourney_awaiting_load, "parked load re-issued")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena._round_bank_pending = false
	arena._tourney_awaiting_roundbank = false
	arena._seq_context = ""
	arena._seq_round_id = ""
	arena._seq_forgive_roundbank = {}
	arena.tourney_awaiting_load = false
	arena.is_round_active = false
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec


func test_overtake_preserves_live_load() -> void:
	# Incident replay, part 1: load sent (latch + context + echo
	# armed), then a stale round refusal lands BEFORE the
	# brains_loaded reply. The overtake must confirm the bank WITHOUT
	# touching the live load wait (the old entry wipe dropped it; the
	# reply then dropped and the game parked with no latch, no
	# context, no timer).
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = true
	arena._seq_forgive_roundbank = {"tournament_id": "T1",
		"match": "R1M1", "battle": "RND-9"}
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._load_gated_on_bank = false
	arena._pending_advance = {}
	arena._on_server_error(
		"round_report: group already banked - QUIT TO MENU + RESUME")
	_check(arena.tourney_awaiting_load, "overtake keeps the load latch")
	_check(arena._seq_context == "load", "overtake keeps load context")
	_check(str(arena._seq_last_load.get("match", "")) == "R1M1",
		"overtake keeps the load echo")
	_check(not arena._round_bank_pending, "overtake still clears the bank")
	_check(not arena._tourney_awaiting_roundbank, "overtake clears awaiting")
	arena.tourney_awaiting_load = false
	arena._seq_context = ""
	arena._seq_last_load = {}
	arena._round_bank_pending = false
	arena._tourney_awaiting_roundbank = false
	arena._seq_forgive_roundbank = {}
	arena._server_reloads = 0
	arena._recover_in_flight = false


func test_overtaken_load_still_starts_round() -> void:
	# Incident replay, part 2: the matching brains_loaded arrives
	# after the overtake - the round must START (was: dropped as
	# "nothing awaited", silent permanent stall).
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._round_bank_pending = true
	arena._tourney_awaiting_roundbank = true
	arena._seq_forgive_roundbank = {"tournament_id": "T1",
		"match": "R1M1", "battle": "RND-9"}
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._load_gated_on_bank = false
	arena._pending_advance = {}
	arena._pending_roundbank_resend = false
	arena._seq_last_round_report = {}
	arena._seq_last_group_report = {}
	arena._group_bank_pending = false
	arena.fly_alpha.landing_mode = 2
	arena.fly_alpha.global_position.y = arena.fly_alpha.LAND_POS_Y
	arena.fly_beta.landing_mode = 2
	arena.fly_beta.global_position.y = arena.fly_beta.LAND_POS_Y
	arena._on_server_error(
		"round_report: group already banked - QUIT TO MENU + RESUME")
	arena._on_brains_loaded({}, {}, "T1", "R1M1")
	_check(arena.is_round_active, "late brains start the round")
	_check(not arena.tourney_awaiting_load, "load latch consumed")
	arena.is_round_active = false
	arena.tourney_awaiting_load = false
	arena._seq_context = ""
	arena._seq_last_load = {}
	arena._round_bank_pending = false
	arena._tourney_awaiting_roundbank = false
	arena._seq_forgive_roundbank = {}
	arena._server_reloads = 0
	arena._recover_in_flight = false


func test_failloud_clears_load_wait() -> void:
	# Fail-loud still stands the load down: with recovery capped, a
	# generic error parks loudly AND clears latch + context, so no
	# late reply can start a round behind the stalled screen.
	arena.tournament_active = true
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._server_reloads = 2
	arena._recover_in_flight = false
	arena._on_server_error("boom")
	_check(not arena.tourney_awaiting_load, "fail-loud clears the latch")
	_check(arena._seq_context == "", "fail-loud clears the context")
	_check(str(arena.status_label.text).begins_with("SERVER ERROR"),
		"fail-loud names the error")
	arena._server_reloads = 0
	arena._recover_in_flight = false


func test_loading_supervisor_recovers() -> void:
	# LOADING with no watch: a load was issued but no watchdog
	# watches it and no bank owns the stall -> capped in-place
	# recovery, once per episode. Watched loads and bank stalls
	# never trip it.
	var d = arena._director()
	if d == null:
		_check(true, "supervisor skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var rpc2: Array = _real_brain_pair(d)
	if rpc2.is_empty():
		_check(true, "supervisor skipped (vault short)")
		return
	var qa: Dictionary = rpc2[0]
	var qb: Dictionary = rpc2[1]
	d.tourney = {"id": "TREC", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(qa.get("id", "")), "b_id": str(qb.get("id", "")),
			"a_name": "A", "b_name": "B"}]]}
	d.brains_cache = [qa, qb]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._group_bank_pending = false
	arena.tourney_awaiting_load = true
	arena._seq_context = ""
	arena._load_stall_since_msec = 0
	arena._load_stall_fired = false
	arena._loading_supervise_tick()
	_check(arena._load_stall_since_msec != 0, "stall clock starts")
	arena._load_stall_since_msec = Time.get_ticks_msec() - 61000
	arena._loading_supervise_tick()
	_check(arena._server_reloads == 1, "unwatched load recovers")
	_check(arena._recover_in_flight, "recovery marked in flight")
	_check(arena._load_stall_fired, "one shot per episode")
	arena._loading_supervise_tick()
	_check(arena._server_reloads == 1, "no repeat spam")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena._load_stall_since_msec = 0
	arena._load_stall_fired = false
	arena._seq_context = "load"
	arena._load_stall_since_msec = Time.get_ticks_msec() - 61000
	arena._loading_supervise_tick()
	_check(arena._server_reloads == 0, "watched load never trips")
	arena._seq_context = ""
	arena._round_bank_pending = true
	arena._load_stall_since_msec = Time.get_ticks_msec() - 61000
	arena._loading_supervise_tick()
	_check(arena._server_reloads == 0, "bank stall never trips")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena._round_bank_pending = false
	arena._seq_context = ""
	arena._load_stall_since_msec = 0
	arena._load_stall_fired = false
	arena.tourney_awaiting_load = false
	arena.is_round_active = false
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec


func test_preload_skips_unbuilt_final() -> void:
	# Final stashed behind banks: the director still points at the old
	# group, so preloading would burn a 5-20 s server cycle on the
	# wrong brains. The ack handler preloads once built instead.
	arena.tournament_active = true
	arena._pending_final_group = {"id": "E9"}
	var before: Dictionary = (arena._preload_params as Dictionary).duplicate(true)
	arena._preload_next_match()
	_check(arena._preload_params == before, "stale final skips preload")
	arena._pending_final_group = {}


func test_preload_targets_current_match() -> void:
	# Preload sends the director's CURRENT match to the prepare slot
	# (the property the post-build preload in the ack handler relies
	# on: the director points at final QF1 by then).
	var d = arena._director()
	if d == null:
		_check(true, "preload skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var pair0: Array = _real_brain_pair(d)
	if pair0.is_empty():
		_check(true, "supervisor skipped (vault short)")
		d.tourney = old_tourney
		return
	var s1: Dictionary = pair0[0]
	var s2: Dictionary = pair0[1]
	d.tourney = {"id": "TREC", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(s1.get("id", "")), "b_id": str(s2.get("id", "")),
			"a_name": "A", "b_name": "B"}]]}
	d.brains_cache = [s1, s2]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena._pending_final_group = {}
	arena._preload_params = {}
	arena.brain_client.is_connected_server = true
	arena._preload_next_match()
	_check(str((arena._preload_params as Dictionary).get("match", "")) == "R1M1",
		"preload targets the current match")
	arena._preload_params = {}
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec


func test_match_nonce_deterministic() -> void:
	# Match nonces recompute identically (resume/flush dedup key),
	# differing per match and round.
	arena.tourney_match_label = "R1M4"
	var n1 := str(arena._current_match_nonce())
	_check(n1 == str(arena._current_match_nonce()), "match nonce recomputable")
	_check("R1M4" in n1, "nonce carries the label")
	arena.tourney_match_label = "R1M3"
	_check(str(arena._current_match_nonce()) != n1, "nonce differs per match")
	arena.tourney_match_label = "R1M4"


func test_match_bank_decision() -> void:
	# Only multi-match bracket rounds bank per match; groups and
	# single-match rounds keep the round report. Pure over the
	# director position (call before advance_after_match).
	var d = arena._director()
	if d == null:
		_check(true, "bank decision skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	d.tourney = {"id": "TDEC", "format": "bracket", "current_round": 0,
		"rounds": [[{}, {}, {}, {}], [{}, {}]]}
	_check(arena._match_bank_round(), "four-match bracket banks per match")
	d.tourney = {"id": "TDEC", "format": "bracket", "current_round": 1,
		"rounds": [[{}, {}, {}, {}], [{}, {}]]}
	_check(arena._match_bank_round(), "two-match bracket banks per match")
	d.tourney = {"id": "TDEC", "format": "bracket", "current_round": 0,
		"rounds": [[{}]]}
	_check(not arena._match_bank_round(), "single-match round keeps round report")
	d.tourney = {"id": "TDEC", "format": "groups", "current_round": 0,
		"rounds": [[{}, {}], [{}, {}]]}
	_check(not arena._match_bank_round(), "groups keep round reports")
	d.tourney = old_tourney


func test_match_send_and_complete() -> void:
	# Per-match bank: send tracks the pending table (same nonce),
	# unknown acks drop, the tick resends outside live battles only,
	# and the last ack completes the round (latch, stamp, parked load).
	var d = arena._director()
	if d == null:
		_check(true, "match bank skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_matchbank"
	DirAccess.make_dir_recursive_absolute("user://test_matchbank")
	var real: Array = d.list_brains_cached()
	if real.size() < 2:
		_check(true, "match bank skipped (vault short)")
		d.tourney = old_tourney
		d.tournament_dir = old_dir
		return
	var ra: Dictionary = real[0]
	var rb: Dictionary = real[1]
	d.tourney = {"id": "TMB", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(ra.get("id", "")), "b_id": str(rb.get("id", "")),
			"bank_nonce": "", "banked": false,
			"winner_id": str(ra.get("id", ""))}]]}
	d.brains_cache = [ra, rb]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena.brain_client.is_connected_server = true
	arena.is_round_active = false
	arena._recover_in_flight = false
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._bank_link_fails = 0
	var entry := {"match_id": "TMB|R0R1M1", "match_winner": "alpha",
		"round": 0, "match": 0, "label": "R1M1", "battles": [{"battle_id": "B1"}]}
	arena._send_match_report(entry)
	_check(arena._match_banks_pending.has("TMB|R0R1M1"), "match send tracked")
	_check(int(arena._match_bank_retries.get("TMB|R0R1M1", 0)) == 1,
		"initial send counted")
	arena._on_match_banked("alpha", 0.0, 0.0, "nope")
	_check(arena._match_banks_pending.has("TMB|R0R1M1"), "unknown ack ignored")
	var st: Dictionary = arena._match_banks_pending["TMB|R0R1M1"]
	st["last_send"] = -60000
	arena._match_banks_pending["TMB|R0R1M1"] = st
	arena._bank_resend_tick()
	_check(int(arena._match_bank_retries.get("TMB|R0R1M1", 0)) == 2,
		"tick resends same nonce")
	arena.is_round_active = true
	st = arena._match_banks_pending["TMB|R0R1M1"]
	st["last_send"] = -60000
	arena._match_banks_pending["TMB|R0R1M1"] = st
	arena._bank_resend_tick()
	_check(int(arena._match_bank_retries.get("TMB|R0R1M1", 0)) == 2,
		"live battle suppresses resends")
	arena.is_round_active = false
	arena._round_bank_pending = true
	arena._round_match_banked = true
	arena._load_gated_on_bank = true
	arena._pending_advance = {}
	arena._on_match_banked("alpha", 0.0, 0.0, "TMB|R0R1M1")
	_check(arena._match_banks_pending.is_empty(), "ack clears the entry")
	_check(not arena._round_bank_pending, "last ack completes the round")
	_check(not arena._load_gated_on_bank, "parked load fired")
	_check(arena.tourney_awaiting_load, "load re-issued")
	_check(bool((((d.tourney.get("rounds", []) as Array)[0] as Array)[0] as Dictionary).get("banked", false)),
		"banked flag stamped")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena._round_bank_pending = false
	arena._round_match_banked = false
	arena._seq_context = ""
	arena.tourney_awaiting_load = false
	arena.is_round_active = false
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_matchbank"):
		for f in DirAccess.get_files_at("user://test_matchbank"):
			DirAccess.remove_absolute("user://test_matchbank".path_join(f))
		DirAccess.remove_absolute("user://test_matchbank")


func test_flush_splits_per_match() -> void:
	# Quit-flush drains per match on match-pathed rounds (small
	# datagrams that arrive), one report otherwise.
	var d = arena._director()
	if d == null:
		_check(true, "flush skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	d.tourney = {"id": "TFL", "format": "bracket", "current_round": 0,
		"current_match": 2,
		"rounds": [[{}, {}, {}, {}]]}
	arena.tournament_active = true
	arena.tourney_match_label = "R1M3"
	arena.brain_client.is_connected_server = true
	arena._round_match_cache = [
		{"match_id": "TFL|R0R1M1", "match_winner": "alpha",
			"battles": [{"battle_id": "B1"}]},
		{"match_id": "TFL|R0R1M2", "match_winner": "beta",
			"battles": [{"battle_id": "B2"}]}]
	arena._match_battle_cache = []
	arena._flush_round_report()
	_check((arena._round_match_cache as Array).is_empty(), "flush drains the cache")
	d.tourney = old_tourney


func test_audit_banked_rounds() -> void:
	# Resume honesty: completed multi-match rounds with decided but
	# unbanked matches report the gap; clean files stay silent.
	var d = arena._director()
	if d == null:
		_check(true, "audit skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	arena.tournament_active = true
	d.tourney = {"id": "TAU", "status": "running", "format": "bracket",
		"current_round": 1,
		"rounds": [
			[{"winner_id": "a", "banked": true}, {"winner_id": "b", "banked": true},
				{"winner_id": "c", "banked": false}, {"winner_id": "e", "banked": false}],
			[{"winner_id": "a"}, {"winner_id": ""}]]}
	_check(arena._audit_banked_rounds() == 2, "audit counts the gap")
	d.tourney = {"id": "TAU", "status": "running", "format": "bracket",
		"current_round": 1,
		"rounds": [
			[{"winner_id": "a", "banked": true}, {"winner_id": "b", "banked": true}],
			[{"winner_id": "a"}, {"winner_id": ""}]]}
	_check(arena._audit_banked_rounds() == 0, "clean file stays silent")
	# Decided-without-fighting is not lost: walkovers and byes never
	# had anything to bank (but real gaps beside them still count).
	d.tourney = {"id": "TAU", "status": "running", "format": "bracket",
		"current_round": 1,
		"rounds": [
			[{"winner_id": "a", "banked": true},
				{"winner_id": "b", "skipped": true, "walkover": "x"},
				{"winner_id": "c"},
				{"winner_id": "e", "banked": true, "bye": true}],
			[{"winner_id": "a"}, {"winner_id": ""}]]}
	_check(arena._audit_banked_rounds() == 1, "walkovers excluded, gaps counted")
	d.tourney = old_tourney


func test_round_freezes_at_match_over() -> void:
	# The round is OVER at match over: sim frozen (steps, timer,
	# timeout verdicts gated) before the result overlay and the next
	# load on the finished match's brains.
	var d = arena._director()
	if d == null:
		_check(true, "freeze skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_mfreeze"
	DirAccess.make_dir_recursive_absolute("user://test_mfreeze")
	d.tourney = {"id": "TMF", "status": "running",
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a1", "b_id": "b1", "a_name": "A",
			"b_name": "B"},
			{"a_id": "c1", "b_id": "d1", "a_name": "C",
			"b_name": "D"}]]}
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena.is_round_active = true
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._round_match_cache = []
	arena._match_battle_cache = [{"battle_id": "B1", "draw": false,
		"verdict": {"winner_slot": "alpha"}}]
	arena._on_match_over("alpha", "1 - 0")
	_check(not arena.is_round_active, "match over freezes the round")
	_check(arena._round_match_cache.is_empty(),
		"per-match path keeps no round cache")
	_check(arena._match_banks_pending.has(arena._current_match_nonce()),
		"match banked under its nonce")
	arena._round_match_cache = []
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._hide_arena_bracket()
	d.tourney = old_tourney
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_mfreeze"):
		for f in DirAccess.get_files_at("user://test_mfreeze"):
			DirAccess.remove_absolute("user://test_mfreeze".path_join(f))
		DirAccess.remove_absolute("user://test_mfreeze")


func test_match_over_clears_replaying_status() -> void:
	# Group-D-to-final wart: a draw's REPLAYING sat on the status bar
	# through the result, the group-complete record and the whole
	# FINAL intermission (~2 min). The decision owns the bar now.
	var d = arena._director()
	if d == null:
		_check(true, "replaying-clear skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_mreplay"
	DirAccess.make_dir_recursive_absolute("user://test_mreplay")
	d.tourney = {"id": "TMR", "status": "running",
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a1", "b_id": "b1", "a_name": "A",
			"b_name": "B"},
			{"a_id": "c1", "b_id": "d1", "a_name": "C",
			"b_name": "D"}]]}
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena.tourney_a_name = "A"
	arena.tourney_b_name = "B"
	arena.is_round_active = true
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._round_match_cache = []
	arena._match_battle_cache = [{"battle_id": "B1", "draw": false,
		"verdict": {"winner_slot": "alpha"}}]
	arena.status_label.text = "R1M1 DNF x2 - REPLAYING"
	arena._on_match_over("alpha", "1 - 0")
	_check(not ("REPLAYING" in arena.status_label.text),
		"match over clears stale replaying")
	_check(("Round 1, Match 1" in arena.status_label.text) and ("1 - 0" in arena.status_label.text),
		"decision names the match and score")
	arena.status_label.text = "R1M1 DNF x2 - REPLAYING"
	arena._on_match_over("draw", "0 - 0")
	_check(not ("REPLAYING" in arena.status_label.text),
		"draw split clears stale replaying too")
	arena._round_match_cache = []
	arena._match_banks_pending = {}
	arena._match_bank_retries = {}
	arena._hide_arena_bracket()
	d.tourney = old_tourney
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_mreplay"):
		for f in DirAccess.get_files_at("user://test_mreplay"):
			DirAccess.remove_absolute("user://test_mreplay".path_join(f))
		DirAccess.remove_absolute("user://test_mreplay")


func test_bracket_stays_until_combat() -> void:
	# The bracket survives reply-hides moved to combat-enable:
	# brains-loaded and match-ready no longer uncover; _reset_round
	# drops the view exactly at _set_combat(true).
	var d = arena._director()
	if d == null:
		_check(true, "bracket-stays skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_bstay"
	DirAccess.make_dir_recursive_absolute("user://test_bstay")
	arena._build_bracket_overlay()
	d.tourney = {"id": "TBS", "status": "running", "lr_scale": 0.5,
		"round_time": 40.0,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "a1", "b_id": "b1", "a_name": "A",
			"b_name": "B"}]]}
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	# Programmatic result display: NOT manual (acquired by waits).
	arena._bracket_manual = false
	arena._show_arena_bracket("RESULT DISPLAY")
	_check(arena.bracket_overlay.visible, "result display shows")
	# Load-send view over the visible programmatic bracket acquires
	# ownership (what _request_current_battle_load does).
	_check(arena._show_wait_bracket("LOADING R1M1"), "load view acquires")
	_check(arena._wait_bracket, "programmatic view acquired by the wait")
	# Brains arrive: the bracket STAYS UP (no early uncover).
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "TBS", "match": "R1M1"}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._pending_roundbank_resend = false
	arena._seq_last_round_report = {}
	arena._seq_last_group_report = {}
	arena._on_brains_loaded({}, {}, "TBS", "R1M1")
	_check(arena._wait_bracket, "load acquires the programmatic view")
	_check(arena.bracket_overlay.visible,
		"bracket stays up after brains (no early uncover)")
	# Reset path: same rule (no hide before the round).
	arena.tourney_awaiting_load = false
	arena._seq_context = "reset"
	arena.is_round_active = false
	# Fresh booted flies sit mid-air with landing_mode 0 (never done):
	# force them landed so _reset_round's landing await returns at once
	# and the round-start completes synchronously.
	arena.fly_alpha.landing_mode = 2
	arena.fly_alpha.global_position.y = arena.fly_alpha.LAND_POS_Y
	arena.fly_beta.landing_mode = 2
	arena.fly_beta.global_position.y = arena.fly_beta.LAND_POS_Y
	arena._on_match_ready()
	_check(arena.is_round_active, "round started")
	# _reset_round hides at combat-enable: the await landed, the view
	# drops NOW (async tail may still be pending - give it a beat).
	arena._reset_round()
	_check(not arena.bracket_overlay.visible,
		"bracket drops at combat-enable")
	_check(not arena._wait_bracket, "ownership released at combat-enable")
	arena.is_round_active = false
	d.tourney = old_tourney
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_bstay"):
		for f in DirAccess.get_files_at("user://test_bstay"):
			DirAccess.remove_absolute("user://test_bstay".path_join(f))
		DirAccess.remove_absolute("user://test_bstay")


func test_manual_bracket_survives() -> void:
	# A user-opened bracket is never yanked: replies no-op, the view
	# stays the user's until they close it.
	arena._build_bracket_overlay()
	arena.tournament_active = true
	arena._on_bracket_toggle()
	_check(arena.bracket_overlay.visible and arena._bracket_manual,
		"manual open sets the flag")
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._pending_roundbank_resend = false
	arena._seq_last_round_report = {}
	arena._seq_last_group_report = {}
	arena._on_brains_loaded({}, {}, "T1", "R1M1")
	_check(not arena._wait_bracket, "manual view never acquired")
	_check(arena.bracket_overlay.visible, "manual bracket survives reply")
	arena._on_bracket_toggle()
	_check(not arena.bracket_overlay.visible and not arena._bracket_manual,
		"manual close clears the flag")
	arena.is_round_active = false
	arena.tourney_awaiting_load = false
	arena._seq_context = ""


func test_vanish_walks_over_and_advances() -> void:
	# Missing vault file at load: no packet goes out; every remaining
	# undecided match of the vanished fighter walks over, the pointer
	# advances past the decided position, and the next load issues.
	# In-progress battles of the broken match are discarded (loud);
	# other matches' caches are untouched.
	var d = arena._director()
	if d == null:
		_check(true, "vanish skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_vanish"
	DirAccess.make_dir_recursive_absolute("user://test_vanish")
	var real: Array = d.list_brains_cached()
	if real.size() < 2:
		_check(true, "vanish skipped (vault short)")
		d.tourney = old_tourney
		d.tournament_dir = old_dir
		return
	var r1: Dictionary = real[0]
	var r2: Dictionary = real[1]
	d.tourney = {"id": "TV", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "gone1", "b_id": "b1", "a_name": "Gone",
			"b_name": "B"},
			{"a_id": str(r1.get("id", "")), "b_id": str(r2.get("id", "")),
				"a_name": "R1", "b_name": "R2"}]]}
	d.brains_cache = [{"id": "gone1", "filename": "gone1.flybrain"},
		{"id": "b1", "filename": "b1.flybrain"}, r1, r2]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena.brain_client.is_connected_server = true
	arena.is_round_active = false
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._group_bank_pending = false
	arena._match_battle_cache = [{"battle_id": "B9"}]
	arena.tourney_awaiting_load = false
	arena._on_fighter_vanished("gone1", "unit test")
	var r0: Array = (d.tourney.get("rounds", []) as Array)[0]
	_check(str((r0[0] as Dictionary).get("winner_id", "")) == "b1"
		and bool((r0[0] as Dictionary).get("skipped", false)),
		"vanished match walks over")
	_check((arena._match_battle_cache as Array).is_empty(),
		"broken match battles discarded")
	_check(int(d.tourney.get("current_match", -1)) == 1,
		"pointer advances past the walkover")
	_check(arena.tourney_awaiting_load, "next load issued")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena.tourney_awaiting_load = false
	arena.is_round_active = false
	arena._seq_context = ""
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_vanish"):
		for f in DirAccess.get_files_at("user://test_vanish"):
			DirAccess.remove_absolute("user://test_vanish".path_join(f))
		DirAccess.remove_absolute("user://test_vanish")


func test_vanish_error_skips_recovery() -> void:
	# Server "not found in vault" is deterministic: walkover now,
	# never a recovery cycle (server_reloads untouched).
	var d = arena._director()
	if d == null:
		_check(true, "vanish error skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var old_dir: String = d.tournament_dir
	d.tournament_dir = "user://test_vanish_err"
	DirAccess.make_dir_recursive_absolute("user://test_vanish_err")
	var real: Array = d.list_brains_cached()
	if real.size() < 2:
		_check(true, "vanish error skipped (vault short)")
		d.tourney = old_tourney
		d.tournament_dir = old_dir
		return
	var r1: Dictionary = real[0]
	var r2: Dictionary = real[1]
	d.tourney = {"id": "TV2", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": "gone2", "b_id": "b2", "a_name": "Gone",
			"b_name": "B"},
			{"a_id": str(r1.get("id", "")), "b_id": str(r2.get("id", "")),
				"a_name": "R1", "b_name": "R2"}]]}
	d.brains_cache = [{"id": "gone2", "filename": "gone2.flybrain"},
		{"id": "b2", "filename": "b2.flybrain"}, r1, r2]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena.brain_client.is_connected_server = true
	arena.is_round_active = false
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._group_bank_pending = false
	arena._server_reloads = 0
	arena._seq_context = "load"
	arena._on_server_error(
		"tournament_load: Brain 'gone2.flybrain' not found in vault X")
	var rr0: Array = (d.tourney.get("rounds", []) as Array)[0]
	_check(str((rr0[0] as Dictionary).get("winner_id", "")) == "b2",
		"deterministic error walks over")
	_check(arena._server_reloads == 0, "no recovery burned")
	_check(not arena._recover_in_flight, "no recovery armed")
	arena._recover_in_flight = false
	arena._server_reloads = 0
	arena.tourney_awaiting_load = false
	arena.is_round_active = false
	arena._seq_context = ""
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec
	d.tournament_dir = old_dir
	if DirAccess.dir_exists_absolute("user://test_vanish_err"):
		for f in DirAccess.get_files_at("user://test_vanish_err"):
			DirAccess.remove_absolute("user://test_vanish_err".path_join(f))
		DirAccess.remove_absolute("user://test_vanish_err")


func test_roundbank_brain_loss_resends() -> void:
	# Server restart killed the round bank: the free-mode error arms a
	# stored-report resend (supervisor reload, capped); the reload
	# landing resends WITHOUT starting a round (rounds are over).
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._seq_context = "roundbank"
	arena._server_reloads = 0
	arena._pending_roundbank_resend = false
	arena._recover_in_flight = false
	arena._seq_last_round_report = {"tournament_id": "T1",
		"match": "R1M1", "round_nonce": "RND-1", "matches": []}
	arena._on_server_error(
		"round_report while in FREE mode - QUIT TO MENU + RESUME")
	_check(arena._pending_roundbank_resend, "bank-loss error arms resend")
	_check(arena._server_reloads == 1, "bank-loss reload counted")
	# Reload landing: re-arms the bank from the stored report, no round.
	arena._seq_context = "load"
	arena.tourney_awaiting_load = true
	arena.is_round_active = false
	arena._on_brains_loaded({}, {})
	_check(not arena._pending_roundbank_resend, "resend flag consumed")
	_check(arena._tourney_awaiting_roundbank, "bank re-armed after reload")
	_check(str(arena._seq_context) == "roundbank", "roundbank watchdog back")
	_check(not arena.is_round_active, "reload landing starts no round")
	# Cap: past-max errors land loud, flag stays down.
	arena._server_reloads = 2
	arena._seq_context = "roundbank"
	arena._recover_in_flight = false
	arena._on_server_error(
		"round_report while in FREE mode - QUIT TO MENU + RESUME")
	_check(not arena._pending_roundbank_resend, "capped bank error no resend")
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


func test_callout_hold() -> void:
	# Coronation hold: a callout with hold_secs stays up past the
	# normal ~2 s beat (the event-champion flash used to vanish
	# before anyone read it). Fires late so the static-callout watch
	# above is done driving the shared overlay first.
	_check(arena.EVENT_CHAMPION_HOLD_SECS >= 10.0,
		"coronation hold is a real beat")
	_hold_fire_at = Time.get_ticks_msec() + 20000


func _watch_hold_tick() -> void:
	# Hold beat is 2.0 s + 4.0 s hold: still up at +2.5 s, down by
	# +12 s. One verdict when the overlay hides (or the wall passes).
	if _hold_fire_at != 0 and Time.get_ticks_msec() >= _hold_fire_at:
		_hold_fire_at = 0
		arena._show_callout("H", Color.WHITE, "S", "", false, 4.0)
		_hold_fired_at = Time.get_ticks_msec()
		_hold_until = _hold_fired_at + 12000
		_hold_watch = true
		_hold_seen = false
		return
	if not _hold_watch:
		return
	var elapsed := Time.get_ticks_msec() - _hold_fired_at
	if is_instance_valid(arena.winner_overlay) and arena.winner_overlay.visible \
			and elapsed > 2500:
		_hold_seen = true
	if _hold_seen and is_instance_valid(arena.winner_overlay) \
			and not arena.winner_overlay.visible:
		_hold_watch = false
		_check(true, "hold keeps the callout past its beat")
	elif Time.get_ticks_msec() > _hold_until:
		_hold_watch = false
		_check(_hold_seen, "hold keeps the callout past its beat")


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


func test_auto_recover_supervisor() -> void:
	# The quit+resume recipe in place: fresh seq/latches/socket + a
	# re-issued load (director stubbed so the load actually arms);
	# capped; in-flight marker consumed on the clean load.
	var d = arena._director()
	if d == null:
		_check(true, "supervisor skipped (no director)")
		return
	var old_tourney: Dictionary = d.tourney
	var old_cache: Array = d.brains_cache
	var old_msec: int = d.brains_cache_msec
	var rpc3: Array = _real_brain_pair(d)
	if rpc3.is_empty():
		_check(true, "supervisor skipped (vault short)")
		return
	var sa: Dictionary = rpc3[0]
	var sb: Dictionary = rpc3[1]
	d.tourney = {"id": "TREC", "status": "running", "lr_scale": 0.5,
		"current_round": 0, "current_match": 0,
		"rounds": [[{"a_id": str(sa.get("id", "")), "b_id": str(sb.get("id", "")),
			"a_name": "A", "b_name": "B"}]]}
	d.brains_cache = [sa, sb]
	d.brains_cache_msec = Time.get_ticks_msec()
	arena.tournament_active = true
	arena.tourney_match_label = "R1M1"
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._round_bank_pending = false
	arena._load_gated_on_bank = false
	arena._tourney_awaiting_roundbank = false
	arena._seq_round_id = ""
	arena._pending_roundbank_resend = false
	arena._seq_context = "battle"
	arena._tourney_awaiting_battle = true
	arena.tourney_awaiting_load = true
	arena._recover_in_flight = false
	var ok: bool = arena._recover_server_state("unit test")
	_check(ok, "supervisor recovers under the cap")
	_check(not arena._tourney_awaiting_battle, "latches cleared")
	_check(arena.tourney_awaiting_load, "load re-issued")
	_check(str(arena._seq_context) == "load", "load watchdog armed")
	_check(arena._recover_in_flight, "recovery marked in flight")
	_check(str(arena.status_label.text).contains("LOADING"),
		"status shows the recovery load")
	# Cap: past-max returns false, caller parks loud.
	arena._recover_in_flight = false
	arena._server_reloads = 2
	arena._seq_context = "battle"
	arena._tourney_awaiting_battle = true
	_check(not bool(arena._recover_server_state("unit test")),
		"cap exhausted, no recovery")
	_check(str(arena._seq_context) == "battle", "cap path touches nothing")
	_check(not arena._recover_in_flight, "cap path arms nothing")
	# Clean load resets the cap + consumes the in-flight marker.
	arena._server_reloads = 2
	arena.tourney_awaiting_load = true
	arena._seq_context = "load"
	arena._seq_last_load = {"tournament_id": "T1", "match": "R1M1"}
	arena._on_brains_loaded({}, {}, "T1", "R1M1")
	_check(arena._server_reloads == 0, "clean load resets the cap")
	_check(not arena._recover_in_flight, "clean load consumes in-flight")
	arena.is_round_active = false
	d.tourney = old_tourney
	d.brains_cache = old_cache
	d.brains_cache_msec = old_msec


func test_state_poll() -> void:
	# Proactive desync catch: a FREE-mode server while a round bank is
	# owed arms the stored-report resend immediately (no 240 s cycle).
	arena.tournament_active = true
	arena._seq_context = "roundbank"
	arena._tourney_awaiting_roundbank = true
	arena._pending_roundbank_resend = false
	arena._seq_last_round_report = {"tournament_id": "T1",
		"match": "R1M1", "round_nonce": "RND-1", "matches": []}
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._on_server_state(false, "", "")
	_check(arena._pending_roundbank_resend, "FREE-mode poll arms resend")
	_check(arena._server_reloads == 1, "poll recovery counted")
	# Tournament-mode reply with the bank still owed: attribution
	# only, no recovery (mode - not the cleared context - decides).
	arena._seq_context = "roundbank"
	arena._pending_roundbank_resend = false
	arena._server_reloads = 0
	arena._recover_in_flight = false
	arena._on_server_state(true, "T1", "R1M1")
	_check(not arena._pending_roundbank_resend, "healthy poll is inert")
	_check(arena._server_reloads == 0, "healthy poll counts nothing")
	arena._seq_context = ""


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
	_watch_hold_tick()
	if _rec_stage == 1:
		if tick < _rec_ready_tick:
			return false
		_rec_stage = 2
		_finish_record_contract()
	if _tests_done:
		if _rec_stage == 2 and _callout_fire_at == 0 and not _callout_watch \
				and _hold_fire_at == 0 and not _hold_watch:
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
	test_round_match_over_advances()
	test_round_report_send()
	test_forgivable_roundbank()
	test_roundbank_retry()
	test_bank_tick_resends()
	test_late_bank_ack_after_recover_applies()
	test_recover_carries_owed_bank()
	test_overtake_fires_parked_load()
	test_overtake_preserves_live_load()
	test_overtaken_load_still_starts_round()
	test_failloud_clears_load_wait()
	test_loading_supervisor_recovers()
	test_preload_skips_unbuilt_final()
	test_preload_targets_current_match()
	test_match_nonce_deterministic()
	test_match_bank_decision()
	test_match_send_and_complete()
	test_flush_splits_per_match()
	test_audit_banked_rounds()
	test_vanish_walks_over_and_advances()
	test_vanish_error_skips_recovery()
	test_round_freezes_at_match_over()
	test_match_over_clears_replaying_status()
	test_bracket_stays_until_combat()
	test_manual_bracket_survives()
	test_roundbank_brain_loss_resends()
	test_step_pacing_gate()
	test_step_reply_clears_and_counts()
	test_dead_round_reply_drops()
	test_step_timeout_adapts()
	test_step_reconnect_gated()
	test_stale_echo_drops()
	test_step_watchdog_recovers_silently()
	test_gallery_star()
	test_idle_parks_loud()
	test_idle_not_cached()
	test_match_ready_refuses_ghosts()
	test_stats_survive_perf_off()
	test_intermission_header_band()
	test_group_report_send()
	test_group_banked_applies()
	test_group_forgive_map()
	test_round_report_group_flag()
	test_auto_recover_supervisor()
	test_state_poll()
	test_motors_slot()
	test_callout_static()
	test_callout_hold()
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
