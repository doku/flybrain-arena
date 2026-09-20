class_name BrainView
extends Control
## Flow-diagram layer of the in-arena brain view (L1): named neuron
## pools as nodes in sense -> value -> descending -> motor columns,
## brightness/size follow live spike-rate EMA, edges light with
## presynaptic drive. Edges resolve from the fighter's real wiring mix
## + mapping, so different brains show different lit paths. Click a
## node to select its pool (raster drill-down consumes `selected`).
## Custom _draw only (no per-node Controls): cheap at 5 Hz refresh.

signal pool_selected(pool_key: String)

# Node layout: key, short label, column 0..3.
const NODES := [
	["pheromone_da1", "DA1", 0], ["pheromone_va1v", "VA1v", 0],
	["visual_lc10", "LC10", 0], ["visual_lc4", "LC4", 0],
	["visual_lplc2", "LPLC2", 0], ["visual_lc11", "LC11", 0],
	["visual_lc15", "LC15", 0], ["visual_lc17", "LC17", 0],
	["visual_lc18", "LC18", 0], ["gyro_jo", "JO", 0],
	["visual_t4a", "T4a", 0], ["visual_t4b", "T4b", 0],
	["visual_t4c", "T4c", 0], ["visual_t4d", "T4d", 0],
	["visual_t5a", "T5a", 0], ["visual_t5b", "T5b", 0],
	["visual_t5c", "T5c", 0], ["visual_t5d", "T5d", 0],
	["mbon_app", "MBON+", 1], ["mbon_av", "MBON-", 1],
	["dn_left", "dnL", 2], ["dn_right", "dnR", 2],
	["motor_thrust_dnp09", "DNp09", 2], ["motor_turn_dnp20", "DNp20", 2],
	["motor_giant_fiber", "GF", 2], ["motor_ram_dnpe017", "RAM", 2],
	["motor_mouth", "MOUTH", 3], ["motor_flight_thrust", "MN", 3],
	["motor_steer", "STEER", 3], ["flow_vs", "VS", 3],
	["flow_hs", "HS", 3],
]
# Edges: from, to, kind. "overlay" edges only light when the fighter's
# wiring mix provides them; "schemed" edges need the mapping scheme.
# kind also shades the line (base gray, overlays tinted).
const EDGES := [
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
const KIND_WIRING := {"contra": "lplc2_contra_dn", "wide": "retina_wide",
	"spear": "spear_lunge"}
const KIND_SCHEME := {"gyro": "gyro_flow", "flowt": "flow_trans"}

var tint := Color.WHITE
var emas := {}
var caps := {}
var wiring: Array = []
var mapping: Array = []
var selected := ""
var node_xy := {}
var title := ""

func refresh(p_emas: Dictionary, p_caps: Dictionary, p_wiring: Array,
		p_mapping: Array) -> void:
	emas = p_emas
	caps = p_caps
	wiring = p_wiring
	mapping = p_mapping
	_layout()
	queue_redraw()


func _edge_on(kind: String) -> bool:
	if kind == "base":
		return true
	if kind == "value":
		# MBON cells can spike in any brain, but only mbon-scheme
		# brains read them — don't imply influence otherwise.
		return "mbon" in mapping
	if kind in KIND_WIRING:
		return KIND_WIRING[kind] in wiring
	if kind in KIND_SCHEME:
		return KIND_SCHEME[kind] in mapping
	return false


func _rate(key: String) -> float:
	var cap := float(caps.get(key, 30.0))
	if cap <= 0.0:
		return 0.0
	return clampf(float(emas.get(key, 0.0)) / cap, 0.0, 1.0)


func _layout() -> void:
	node_xy.clear()
	var cols := [[], [], [], []]
	for spec in NODES:
		(cols[int(spec[2])] as Array).append(spec)
	var w := size.x
	var h := size.y
	for c in range(4):
		var items: Array = cols[c]
		for i in range(items.size()):
			var key := str(items[i][0])
			node_xy[key] = Vector2(
				30.0 + c * (w - 60.0) / 3.0,
				30.0 + i * (h - 60.0) / maxf(items.size() - 1.0, 1.0))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.05, 0.78))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.4, 0.5, 0.6), false, 1.0)
	if title != "":
		draw_string(ThemeDB.fallback_font, Vector2(8, 16), title,
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0, 12,
			Color(0.85, 0.85, 0.9, 0.9))
	for e in EDGES:
		if not _edge_on(str(e[2])):
			continue
		var a: Vector2 = node_xy.get(e[0], Vector2.ZERO)
		var b: Vector2 = node_xy.get(e[1], Vector2.ZERO)
		if a == Vector2.ZERO or b == Vector2.ZERO:
			continue
		var drive := _rate(str(e[0]))
		if drive < 0.02:
			continue
		var col := Color(0.55, 0.55, 0.6, 0.25 + 0.65 * drive)
		if str(e[2]) != "base" and str(e[2]) != "value":
			col = Color(tint.r, tint.g, tint.b, 0.25 + 0.65 * drive)
		draw_line(a, b, col, 1.0 + 3.0 * drive, true)
	for spec in NODES:
		var key := str(spec[0])
		var p: Vector2 = node_xy.get(key, Vector2.ZERO)
		if p == Vector2.ZERO:
			continue
		var r := _rate(key)
		var rad := 9.0 + 9.0 * r
		var glow := Color(tint.r, tint.g, tint.b, 0.15 + 0.85 * r)
		draw_circle(p, rad + 3.0, Color(glow.r, glow.g, glow.b, 0.25))
		draw_circle(p, rad, glow)
		draw_arc(p, rad, 0.0, TAU, 24, Color(0.9, 0.9, 0.95, 0.8), 1.0, true)
		if selected == key:
			draw_arc(p, rad + 6.0, 0.0, TAU, 24, Color(1.0, 1.0, 1.0, 0.9), 2.0, true)
		draw_string(ThemeDB.fallback_font, p + Vector2(-20.0, rad + 14.0),
			str(spec[1]), HORIZONTAL_ALIGNMENT_LEFT, 44.0, 11,
			Color(0.85, 0.85, 0.9, 0.9))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var best := ""
			var best_d := 26.0
			for key in node_xy.keys():
				var d: float = (node_xy[key] as Vector2).distance_to(mb.position)
				if d < best_d:
					best_d = d
					best = str(key)
			if best != "":
				selected = "" if selected == best else best
				pool_selected.emit(selected)
				queue_redraw()
				accept_event()
