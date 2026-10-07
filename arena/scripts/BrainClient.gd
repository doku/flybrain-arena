class_name BrainClient
extends Node

signal motor_controls_received(alpha_ctrl: Dictionary, beta_ctrl: Dictionary, generation: int, stats: Dictionary)
signal generation_advanced(new_generation: int, winner: String)
signal merged(merge_count: int, archived_loser: String)
signal restarted(round_winner: String)
signal tournament_battle_received(battle_winner: String, fitness_alpha: float, fitness_beta: float, battle_id: String)
signal battle_progress_received(battle_id: String)
signal match_banked_received(match_winner: String, fitness_alpha: float, fitness_beta: float, match_id: String)
signal round_banked_received(round_nonce: String, tournament_id: String, match_label: String)
signal group_banked_received(group_nonce: String, tournament_id: String)
signal brains_loaded_received(alpha_info: Dictionary, beta_info: Dictionary, tournament_id: String, match_label: String)
signal prepared_received(tournament_id: String, match_label: String)
signal match_ready_received()
signal match_recorded_received()
signal tournament_closed_received()
signal server_error_received(error: String)
signal raster_map_received(side: String, pool: String, ids: Array, total: int)
signal server_state_received(tournament_mode: bool, tournament_id: String, match_label: String)

@export var server_host: String = "127.0.0.1"
@export var server_port: int = 9999

# Test quarantine: when true, NO packet leaves this client (every
# sender drops at _send_dict). Test harnesses set it before
# instantiating anything - a headless suite must never talk to the
# live tournament server (free_mode/round_over from a test boot used
# to yank live tournaments into FREE mid-match). Socket state machine
# (connect/reconnect/is_connected_server) still works, so link tests
# keep their meaning.
static var test_mute := false

var udp := PacketPeerUDP.new()
var is_connected_server: bool = false
var last_sent_time: float = 0.0
var tick_interval: float = 0.05 # 50 ms (20 Hz)

func _ready() -> void:
	if reconnect():
		print("[BrainClient] Bound UDP to ", server_host, ":", server_port)
	else:
		printerr("[BrainClient] Failed to connect UDP socket.")


func reconnect() -> bool:
	# Fresh socket: on Windows a connected UDP peer poisoned by one
	# ICMP unreachable (server restart/kill while the arena lived)
	# fails every later send/recv until recreated. Called on any send
	# error and before watchdog retries so the link self-heals instead
	# of wedging at SERVER SILENT with a live server.
	udp.close()
	var err := udp.connect_to_host(server_host, server_port)
	is_connected_server = err == OK
	if not is_connected_server:
		printerr("[BrainClient] Reconnect failed: ", err)
	return is_connected_server


func _send_dict(payload: Dictionary) -> void:
	if test_mute:
		return
	if not is_connected_server:
		return
	var json_data = JSON.stringify(payload).to_utf8_buffer()
	if udp.put_packet(json_data) != OK:
		print("[BrainClient] Send failed - reconnecting once and resending.")
		if reconnect():
			if udp.put_packet(json_data) != OK:
				printerr("[BrainClient] Resend failed after reconnect.")

func _process(_delta: float) -> void:
	# Poll incoming packets from brain server
	while udp.get_available_packet_count() > 0:
		var packet = udp.get_packet()
		var json_str = packet.get_string_from_utf8()
		var parse_result = JSON.parse_string(json_str)
		if parse_result is Dictionary:
			_handle_server_response(parse_result)
		else:
			# Never swallow packets silently: an unparsable reply (e.g. NaN
			# fitness, which is not valid JSON) would otherwise wedge the
			# arena with no error text and live animations.
			push_warning("[BrainClient] Dropped unparsable server packet: ",
				json_str.left(160))

var detail_level: int = 1

func send_sensory_step(sens_alpha: Dictionary, sens_beta: Dictionary) -> void:
	if not is_connected_server:
		return

	var msg = {
		"type": "step",
		"alpha": sens_alpha,
		"beta": sens_beta,
		"detail": detail_level
	}
	_send_dict(msg)

func send_round_over(stats_alpha: Dictionary, stats_beta: Dictionary, arena_draw: bool = false, battle_id: String = "", tournament_id: String = "", match_label: String = "", flight_alpha: Dictionary = {}, flight_beta: Dictionary = {}, draw_penalty: bool = false, end_reason: String = "", verdict: Dictionary = {}) -> void:
	if not is_connected_server:
		return

	var msg = {
		"type": "round_over",
		"stats_alpha": stats_alpha,
		"stats_beta": stats_beta,
		"arena_draw": arena_draw,
		"battle_id": battle_id,
		"tournament_id": tournament_id,
		"match": match_label,
		"flight_alpha": flight_alpha,
		"flight_beta": flight_beta,
		"draw_penalty": draw_penalty,
		"end_reason": end_reason,
		"verdict": verdict
	}
	_send_dict(msg)

func request_match_report(match_winner: String, tournament_id: String,
		match_label: String, match_id: String, battles: Array,
		partial: bool = false) -> void:
	# ONE bank per match: every cached battle rides one message; the
	# server replays them in order, then banks the match (one journal,
	# one save pair). Partial = quit-flush: banks battles only, the
	# match result stays undecided.
	if not is_connected_server:
		return
	_send_dict({
		"type": "match_report",
		"match_winner": match_winner,
		"tournament_id": tournament_id,
		"match": match_label,
		"match_id": match_id,
		"battles": battles,
		"partial": partial
	})

func request_tournament_load(alpha_path: String, beta_path: String, tournament_id: String, match_label: String, lr_scale: float = 0.5) -> void:
	if not is_connected_server:
		return
	var msg = {
		"type": "tournament_load",
		"alpha_path": alpha_path,
		"beta_path": beta_path,
		"tournament_id": tournament_id,
		"match": match_label,
		"lr_scale": lr_scale
	}
	_send_dict(msg)

func request_tournament_prepare(alpha_path: String, beta_path: String, tournament_id: String, match_label: String) -> void:
	# Preload the NEXT match into the server's prepare slot while a
	# countdown or the current match runs: the ~5-20 s disk+binding
	# load hides under the wait. The official load later activates the
	# slot in O(1). Best-effort (fire-and-forget).
	if not is_connected_server:
		return
	_send_dict({
		"type": "tournament_prepare",
		"alpha_path": alpha_path,
		"beta_path": beta_path,
		"tournament_id": tournament_id,
		"match": match_label
	})

func request_warm_wirings(paths: Array) -> void:
	# Bind-only pre-warm for a roster: the server loads meta, skips
	# cached wirings, and binds novel ones (shared caches), keeping
	# nothing. Fire-and-forget (no watch, no reply handling): genome
	# compiles land under intermissions instead of post-ack loads.
	if not is_connected_server or paths.is_empty():
		return
	_send_dict({"type": "warm_wirings", "paths": paths})

func request_raster_map(side: String, pool: String) -> void:
	if not is_connected_server:
		return
	_send_dict({"type": "raster_map", "side": side, "pool": pool})


func request_match_reset(match_label: String = "") -> void:
	if not is_connected_server:
		return
	_send_dict({"type": "match_reset", "match": match_label})

func request_round_report(round_nonce: String, tournament_id: String,
		match_label: String, matches: Array, group: bool = false) -> void:
	# ONE bank per round: every completed match rides one message; the
	# server replays matches in order, then journals once + saves each
	# brain once. Between matches/rounds only loads flow - the bank
	# hides under the intermission while the next round overlaps it.
	# Group files pass group=true: the server pins brains in RAM and
	# journals without saving; the group bank lands separately.
	if not is_connected_server:
		return
	_send_dict({
		"type": "round_report",
		"round_nonce": round_nonce,
		"tournament_id": tournament_id,
		"match": match_label,
		"matches": matches,
		"group": group
	})


func request_group_report(group_nonce: String, tournament_id: String,
		group_label: String) -> void:
	# ONE bank per group (group files only): the server seals the
	# journal and saves each pinned brain once. Sent at group
	# completion; final loads gate on the ack.
	if not is_connected_server:
		return
	_send_dict({
		"type": "group_report",
		"group_nonce": group_nonce,
		"tournament_id": tournament_id,
		"group": group_label
	})


func request_free_mode() -> void:
	if not is_connected_server:
		return
	_send_dict({"type": "free_mode"})

func request_server_state() -> void:
	# Proactive desync poll: tiny, no bank work on the server side.
	if not is_connected_server:
		return
	_send_dict({"type": "get_server_state"})

func request_tournament_match(match_winner: String, tournament_id: String = "", match_label: String = "") -> void:
	if not is_connected_server:
		return
	_send_dict({"type": "tournament_match", "match_winner": match_winner, "tournament_id": tournament_id, "match": match_label})

func request_tournament_end(champion: String, champion_id: String = "") -> void:
	if not is_connected_server:
		return
	_send_dict({"type": "tournament_end", "champion": champion,
		"champion_id": champion_id})

func request_merge() -> void:
	if not is_connected_server:
		return
	var msg = { "type": "merge" }
	_send_dict(msg)

func request_restart(stats_alpha: Dictionary, stats_beta: Dictionary) -> void:
	if not is_connected_server:
		return
	var msg = {
		"type": "restart",
		"stats_alpha": stats_alpha,
		"stats_beta": stats_beta
	}
	_send_dict(msg)

func _handle_server_response(data: Dictionary) -> void:
	var status = data.get("status", "")
	if status == "ok":
		var alpha_ctrl = data.get("alpha", {})
		var beta_ctrl = data.get("beta", {})
		var gen = data.get("generation", 1)
		var stats = data.get("stats", {})
		motor_controls_received.emit(alpha_ctrl, beta_ctrl, gen, stats)
	elif status == "generation_advanced":
		var new_gen = data.get("new_generation", 1)
		var winner = data.get("previous_winner", "")
		generation_advanced.emit(new_gen, winner)
	elif status == "merged":
		merged.emit(data.get("merge_count", 1), data.get("archived_loser", ""))
	elif status == "restarted":
		restarted.emit(data.get("round_winner", ""))
	elif status == "tournament_battle":
		tournament_battle_received.emit(
			data.get("battle_winner", "draw"),
			float(data.get("fitness_alpha", 0.0)),
			float(data.get("fitness_beta", 0.0)),
			str(data.get("battle_id", "")))
	elif status == "round_banked":
		round_banked_received.emit(
			str(data.get("battle_id", "")),
			str(data.get("tournament_id", "")),
			str(data.get("match", "")))
	elif status == "group_banked":
		group_banked_received.emit(
			str(data.get("battle_id", "")),
			str(data.get("tournament_id", "")))
	elif status == "tournament_match_battled":
		match_banked_received.emit(
			data.get("match_winner", "draw"),
			float(data.get("fitness_alpha", 0.0)),
			float(data.get("fitness_beta", 0.0)),
			str(data.get("battle_id", "")))
	elif status == "battle_progress":
		battle_progress_received.emit(str(data.get("battle_id", "")))
	elif status == "brains_loaded":
		brains_loaded_received.emit(
			data.get("alpha", {}), data.get("beta", {}),
			str(data.get("tournament_id", "")),
			str(data.get("match", "")))
	elif status == "prepared":
		prepared_received.emit(
			str(data.get("tournament_id", "")),
			str(data.get("match", "")))
	elif status == "match_ready":
		match_ready_received.emit()
	elif status == "match_recorded":
		match_recorded_received.emit()
	elif status == "tournament_closed":
		tournament_closed_received.emit()
	elif status == "raster_map":
		raster_map_received.emit(
			str(data.get("side", "")), str(data.get("pool", "")),
			data.get("ids", []), int(data.get("total", 0)))
	elif status == "server_state":
		server_state_received.emit(
			bool(data.get("tournament_mode", false)),
			str(data.get("tournament_id", "")),
			str(data.get("match", "")))
	elif status == "error":
		server_error_received.emit(str(data.get("error", "unknown")))
