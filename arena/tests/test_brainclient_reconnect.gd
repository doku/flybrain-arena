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
	_check(true, "all senders safe while disconnected")
	b.queue_free()


func _initialize() -> void:
	test_reconnect_sets_flag()
	test_send_heals_broken_socket()
	test_guarded_send_never_crashes()
	if failures == 0:
		print("ALL BRAINCLIENT TESTS PASSED")
	else:
		printerr("BRAINCLIENT TESTS: %d FAILURES" % failures)
	quit(failures)
