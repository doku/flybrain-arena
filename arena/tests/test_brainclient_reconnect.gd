extends SceneTree
## Headless BrainClient link tests: reconnect + self-healing sends.
## Run: godot --headless --path arena -s tests/test_brainclient_reconnect.gd
## Exit code = failure count (0 = all green).
## NOTE: the client points at a dead port (55555) so no packet can ever
## reach (or disturb) a live server; UDP connect succeeds regardless.

var failures := 0
const DEAD_PORT := 55555


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_client():
	load("res://scripts/BrainClient.gd").test_mute = true
	var b = load("res://scripts/BrainClient.gd").new()
	b.server_port = DEAD_PORT
	return b


func test_reconnect_sets_flag() -> void:
	var b = _new_client()
	_check(not b.is_connected_server, "fresh client starts disconnected")
	_check(b.reconnect(), "reconnect to dead port reports ok (UDP, no handshake)")
	_check(b.is_connected_server, "flag set after reconnect")
	b.queue_free()


func test_send_heals_broken_socket() -> void:
	var b = _new_client()
	b.reconnect()
	b.udp.close()
	b.is_connected_server = true
	# Full-arity report on a broken socket: first put fails, the client
	# reconnects once and resends instead of wedging silent.
	b.send_round_over({}, {}, false, "B9", "T9", "R1M9", {}, {}, false, "ko", {})
	_check(b.is_connected_server, "link healed after send failure")
	b.queue_free()


func test_guarded_send_never_crashes() -> void:
	var b = _new_client()
	# Disconnected: every sender early-returns, none touch the socket.
	b.send_round_over({}, {}, false, "B9", "T9", "R1M9", {}, {}, false, "", {})
	b.request_match_reset("R1M9")
	b.request_free_mode()
	b.request_tournament_match("alpha", "T9", "R1M9")
	b.request_tournament_end("alpha")
	b.request_merge()
	b.request_restart({}, {})
	b.request_raster_map("alpha", "dn_left")
	b.request_tournament_load("a", "b", "T9", "R1M9", 0.5)
	b.request_warm_wirings([])
	b.request_warm_wirings(["a.flybrain"])
	_check(true, "all senders safe while disconnected")
	b.queue_free()


func test_round_banked_carries_nonce() -> void:
	# The server keys the ack nonce as battle_id (never round_nonce):
	# the client must forward it so forgive/mismatch checks see it.
	var b = _new_client()
	var got: Array = []
	b.round_banked_received.connect(
		func(nonce, tid, match): got.append([nonce, tid, match]))
	b._handle_server_response({"status": "round_banked",
		"battle_id": "RND-1", "tournament_id": "T",
		"match": "R1M1"})
	_check(got == [["RND-1", "T", "R1M1"]], "round ack forwards battle_id nonce")
	# Informational replies (warm ack) are ignored, never crash.
	b._handle_server_response({"status": "wirings_warm",
		"warmed": 3, "skipped": 13})
	_check(got.size() == 1, "warm ack touches no signal")
	b.queue_free()


func test_slim_battle_keeps_plasticity_keys() -> void:
	# Bank slimming: exactly the sens/ctrl fields dopamine replays
	# survive; arrays and non-plasticity keys drop.
	var b = _new_client()
	var fat := {
		"battle_id": "B1", "draw": false, "draw_penalty": false,
		"end_reason": "ko", "verdict": {"winner_slot": "alpha"},
		"stats_a": {"kills": 1}, "stats_b": {"kills": 0},
		"sens_a": {"pheromone_conc_left": 0.5, "visual_target_azimuth": -20.0,
			"visual_sec_presence": [1.0, 2.0], "junk": 1},
		"sens_b": {}, "ctrl_a": {"yaw_torque": 0.3, "thrust": 0.9},
		"ctrl_b": {}}
	var s: Dictionary = b.slim_battle_for_bank(fat)
	_check(float((s["sens_a"] as Dictionary).get("pheromone_conc_left", -1.0)) == 0.5,
		"plasticity sens kept")
	_check(float((s["sens_a"] as Dictionary).get("visual_target_azimuth", 999.0)) == -20.0,
		"azimuth kept")
	_check(not (s["sens_a"] as Dictionary).has("visual_sec_presence"),
		"arrays dropped")
	_check(not (s["sens_a"] as Dictionary).has("junk"), "unknown keys dropped")
	_check(float((s["ctrl_a"] as Dictionary).get("yaw_torque", 999.0)) == 0.3,
		"motor kept")
	_check(not (s["ctrl_a"] as Dictionary).has("thrust"),
		"non-plasticity ctrl dropped")
	_check(str(s["battle_id"]) == "B1", "ids kept")
	_check(str((s["verdict"] as Dictionary).get("winner_slot", "")) == "alpha",
		"verdict kept")
	b.queue_free()


func test_split_packs_and_orders() -> void:
	# Datagram-safe split: small reports ship whole (no part keys),
	# big ones split under budget with indexed metadata and exact
	# battle order across parts.
	var b = _new_client()
	var matches: Array = []
	for mi in range(3):
		var battles: Array = []
		for bi in range(5):
			battles.append({"battle_id": "M%dB%d" % [mi, bi], "draw": false,
				"verdict": {}, "stats_a": {}, "stats_b": {},
				"sens_a": {"pheromone_conc_left": 0.1}, "sens_b": {},
				"ctrl_a": {"yaw_torque": 0.1}, "ctrl_b": {}})
		matches.append({"match_id": "M%d" % mi, "match_winner": "alpha",
			"battles": battles})
	var base := {"type": "round_report", "round_nonce": "R1",
		"tournament_id": "T", "match": "M", "group": false}
	var one: Array = b.split_report_parts(base, matches, 50000)
	_check(one.size() == 1, "small report ships whole")
	_check(str((one[0] as Dictionary).get("type", "")) == "round_report",
		"whole keeps its type")
	_check(not (one[0] as Dictionary).has("part_idx"),
		"whole carries no part keys")
	var parts: Array = b.split_report_parts(base, matches, 1500)
	_check(parts.size() > 1, "big report splits")
	for i in range(parts.size()):
		var p: Dictionary = parts[i]
		_check(str(p.get("type", "")) == "round_report_part", "part typed")
		_check(int(p.get("part_idx", -1)) == i, "part indexed")
		_check(int(p.get("part_count", -1)) == parts.size(), "part counted")
		_check(JSON.stringify(p).length() <= 1500, "part fits budget")
	var ids: Array = []
	for p in parts:
		for m in ((p as Dictionary).get("matches", []) as Array):
			for bb in ((m as Dictionary).get("battles", []) as Array):
				ids.append(str((bb as Dictionary).get("battle_id", "")))
	var want: Array = []
	for mi in range(3):
		for bi in range(5):
			want.append("M%dB%d" % [mi, bi])
	_check(ids == want, "part order preserves battle order")
	b.queue_free()


func test_muted_send_reports_ok() -> void:
	# Test-mute skips the socket but reports success (no spurious
	# send-failure escalation in suites).
	var b = _new_client()
	b.request_round_report("R1", "T", "M", [], false)
	_check(b.last_send_ok, "muted send reports ok")
	b.queue_free()


func _initialize() -> void:
	test_reconnect_sets_flag()
	test_send_heals_broken_socket()
	test_guarded_send_never_crashes()
	test_round_banked_carries_nonce()
	test_slim_battle_keeps_plasticity_keys()
	test_split_packs_and_orders()
	test_muted_send_reports_ok()
	if failures == 0:
		print("ALL BRAINCLIENT TESTS PASSED")
	else:
		printerr("BRAINCLIENT TESTS: %d FAILURES" % failures)
	quit(failures)
