class_name BrainRaster
extends Control
## Raster drill-down layer of the in-arena brain view (L2): per-neuron
## spike raster for one selected pool. Ring buffer of recent steps
## (columns = time, rows = cells); custom _draw only. Pushed one
## column per motor reply (~5 Hz) from the detail-2 spike-id stream.

const MAX_STEPS := 40
const MAX_ROWS := 128

var pool := ""
var total := 0
var tint := Color.WHITE
var row_ids: Array = []
var row_index := {}
var cols: Array = []

func setup(p_pool: String, p_ids: Array, p_total: int, p_tint: Color) -> void:
	pool = p_pool
	total = p_total
	tint = p_tint
	row_ids = (p_ids as Array).slice(0, MAX_ROWS)
	row_index.clear()
	for i in range(row_ids.size()):
		row_index[int(row_ids[i])] = i
	cols.clear()
	queue_redraw()


func clear() -> void:
	cols.clear()
	queue_redraw()


func push_step(spike_ids: Array) -> void:
	if row_ids.is_empty():
		return
	var lit := {}
	for s in spike_ids:
		var r: int = int(row_index.get(int(s), -1))
		if r >= 0:
			lit[r] = true
	cols.append(lit)
	while cols.size() > MAX_STEPS:
		cols.pop_front()
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.05, 0.85))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.4, 0.5, 0.6), false, 1.0)
	var head := "%s  %d cells%s" % [pool, total,
		("" if total <= MAX_ROWS else " (first %d)" % MAX_ROWS)]
	draw_string(ThemeDB.fallback_font, Vector2(8, 16), head,
		HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0, 12,
		Color(tint.r, tint.g, tint.b, 0.95))
	if row_ids.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(8, 40),
			"requesting cell list...", HORIZONTAL_ALIGNMENT_LEFT,
			size.x - 16.0, 11, Color(0.6, 0.6, 0.65, 0.9))
		return
	var top := 24.0
	var nrows := row_ids.size()
	var rh: float = minf(10.0, (size.y - top - 4.0) / maxf(nrows, 1.0))
	var cw: float = (size.x - 8.0) / float(MAX_STEPS)
	for c in range(cols.size()):
		var x := 4.0 + c * cw
		for r in (cols[c] as Dictionary).keys():
			var y := top + float(r) * rh
			draw_rect(Rect2(x, y, maxf(cw - 0.5, 1.0), maxf(rh - 0.5, 1.0)),
				Color(tint.r, tint.g, tint.b, 0.95))
