class_name BrainClient
extends Node

signal motor_controls_received(alpha_ctrl: Dictionary, beta_ctrl: Dictionary, generation: int, stats: Dictionary)
signal generation_advanced(new_generation: int, winner: String)
signal merged(merge_count: int, archived_loser: String)
signal restarted(round_winner: String)
signal tournament_battle_received(battle_winner: String, fitness_alpha: float, fitness_beta: float, battle_id: String)
signal brains_loaded(alpha_info: Dictionary, beta_info: Dictionary)
signal match_ready_received()
signal match_recorded_received()
signal tournament_closed_received()
signal server_error_received(error: String)
signal raster_map_received(side: String, pool: String, ids: Array, total: int)

@export var server_host: String = "127.0.0.1"
@export var server_port: int = 9999

var udp := PacketPeerUDP.new()
var is_connected_server: bool = false
var last_sent_time: float = 0.0
var tick_interval: float = 0.05 # 50 ms (20 Hz)

func _ready() -> void:
	var err = udp.connect_to_host(server_host, server_port)
	if err == OK:
		is_connected_server = true
		print("[BrainClient] Bound UDP to ", server_host, ":", server_port)
	else:
		printerr("[BrainClient] Failed to connect UDP socket: ", err)

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
	var json_data = JSON.stringify(msg).to_utf8_buffer()
	udp.put_packet(json_data)

func send_round_over(stats_alpha: Dictionary, stats_beta: Dictionary, arena_draw: bool = false, battle_id: String = "", tournament_id: String = "", match_label: String = "", flight_alpha: Dictionary = {}, flight_beta: Dictionary = {}) -> void:
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
		"flight_beta": flight_beta
	}
	var json_data = JSON.stringify(msg).to_utf8_buffer()
	udp.put_packet(json_data)

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
	udp.put_packet(JSON.stringify(msg).to_utf8_buffer())

func request_raster_map(side: String, pool: String) -> void:
	if not is_connected_server:
		return
	udp.put_packet(JSON.stringify(
		{"type": "raster_map", "side": side, "pool": pool}).to_utf8_buffer())


func request_match_reset(match_label: String = "") -> void:
	if not is_connected_server:
		return
	udp.put_packet(JSON.stringify({"type": "match_reset", "match": match_label}).to_utf8_buffer())

func request_free_mode() -> void:
	if not is_connected_server:
		return
	udp.put_packet(JSON.stringify({"type": "free_mode"}).to_utf8_buffer())

func request_tournament_match(match_winner: String) -> void:
	if not is_connected_server:
		return
	udp.put_packet(JSON.stringify({"type": "tournament_match", "match_winner": match_winner}).to_utf8_buffer())

func request_tournament_end(champion: String) -> void:
	if not is_connected_server:
		return
	udp.put_packet(JSON.stringify({"type": "tournament_end", "champion": champion}).to_utf8_buffer())

func request_merge() -> void:
	if not is_connected_server:
		return
	var msg = { "type": "merge" }
	udp.put_packet(JSON.stringify(msg).to_utf8_buffer())

func request_restart(stats_alpha: Dictionary, stats_beta: Dictionary) -> void:
	if not is_connected_server:
		return
	var msg = {
		"type": "restart",
		"stats_alpha": stats_alpha,
		"stats_beta": stats_beta
	}
	udp.put_packet(JSON.stringify(msg).to_utf8_buffer())

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
	elif status == "brains_loaded":
		brains_loaded.emit(data.get("alpha", {}), data.get("beta", {}))
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
	elif status == "error":
		server_error_received.emit(str(data.get("error", "unknown")))
