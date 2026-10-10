class_name BrainCloud
extends Node3D
## 3D soma-cloud layer of the in-arena brain view: every mapped-pool
## neuron with a known MaleCNS soma position renders as one MultiMesh
## instance (single draw call), colored by pool. Spikes flash via a
## shader-decayed timestamp, so the CPU only touches cells that fired
## (~hundreds per step, never the whole cloud).

const POOL_COLORS := {
	"pheromone_da1": Color(0.4, 1.0, 0.4), "pheromone_va1v": Color(0.5, 0.9, 0.3),
	"visual_lc10": Color(1.0, 0.9, 0.3), "visual_lc4": Color(1.0, 0.5, 0.2),
	"visual_lplc2": Color(1.0, 0.6, 0.9), "visual_lc11": Color(1.0, 1.0, 0.4),
	"visual_lc15": Color(1.0, 0.8, 0.2), "visual_lc17": Color(1.0, 0.7, 0.2),
	"visual_lc18": Color(0.9, 0.8, 0.3), "gyro_jo": Color(0.4, 0.8, 1.0),
	"visual_t4a": Color(0.3, 1.0, 0.7), "visual_t4b": Color(1.0, 0.4, 0.7),
	"visual_t4c": Color(0.4, 1.0, 1.0), "visual_t4d": Color(1.0, 0.9, 0.4),
	"visual_t5a": Color(0.35, 0.95, 0.65), "visual_t5b": Color(0.95, 0.35, 0.65),
	"visual_t5c": Color(0.35, 0.95, 0.95), "visual_t5d": Color(0.95, 0.85, 0.35),
	"motor_thrust_dnp09": Color(1.0, 0.4, 0.1), "motor_turn_dnp20": Color(1.0, 0.45, 0.1),
	"motor_giant_fiber": Color(1.0, 0.2, 0.2), "motor_ram_dnpe017": Color(1.0, 0.3, 0.4),
	"motor_mouth": Color(1.0, 0.2, 0.6), "motor_flight_thrust": Color(1.0, 0.5, 0.2),
	"motor_steer": Color(1.0, 0.55, 0.25), "flow_vs": Color(0.3, 0.7, 1.0),
	"flow_hs": Color(0.35, 0.75, 1.0), "mbon_app": Color(0.7, 0.4, 1.0),
	"mbon_av": Color(0.5, 0.2, 0.8), "descending_all": Color(1.0, 0.6, 0.15),
}

var multimesh: MultiMesh
var id_to_inst := {}
var inst_base: Array = []
var ready_ok := false
# Network overlay: pool-to-pool flow lines at real centroid positions,
# rebuilt per step (tens of lines = trivial). Each entry:
# [Vector3 from, Vector3 to, strength 0..1, Color].
var nets_mesh: MeshInstance3D

static func load_asset() -> Dictionary:
	# Shared parse (both flies use one copy; instances are per side).
	var path := "res://models/brain_cloud.json"
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


func build(asset: Dictionary, size_m: float) -> bool:
	var cells: Array = asset.get("cells", [])
	if cells.is_empty():
		return false
	var sphere := SphereMesh.new()
	sphere.radial_segments = 6
	sphere.rings = 4
	sphere.radius = 0.009
	sphere.height = 0.018
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://scripts/brain_cloud.gdshader")
	sphere.material = mat
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = sphere
	multimesh.instance_count = cells.size()
	inst_base.clear()
	inst_base.resize(cells.size())
	var i := 0
	for c in cells:
		var cell: Array = c
		var t := Transform3D(Basis(), Vector3(
			float(cell[1]) * size_m, float(cell[2]) * size_m, float(cell[3]) * size_m))
		multimesh.set_instance_transform(i, t)
		var col: Color = POOL_COLORS.get(str(cell[4]), Color(0.6, 0.6, 0.65))
		inst_base[i] = col
		# Alpha = far past: no glow until the first real spike.
		multimesh.set_instance_color(i, Color(col.r, col.g, col.b, -1000.0))
		id_to_inst[int(cell[0])] = i
		i += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	add_child(mmi)
	ready_ok = true
	return true


func set_nets(edges: Array) -> void:
	# Rebuilds the line overlay from [from, to, strength, Color]
	# entries. Empty array clears it.
	if not ready_ok:
		return
	if is_instance_valid(nets_mesh):
		nets_mesh.queue_free()
		nets_mesh = null
	if edges.is_empty():
		return
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for e in edges:
		var edge: Array = e
		var a: Vector3 = edge[0]
		var b: Vector3 = edge[1]
		var s := clampf(float(edge[2]), 0.0, 1.0)
		var c: Color = edge[3]
		im.surface_set_color(Color(c.r, c.g, c.b, 0.15 + 0.75 * s))
		im.surface_add_vertex(a)
		im.surface_set_color(Color(c.r, c.g, c.b, 0.15 + 0.75 * s))
		im.surface_add_vertex(b)
	im.surface_end()
	nets_mesh = MeshInstance3D.new()
	nets_mesh.mesh = im
	add_child(nets_mesh)


func push_spikes(spike_ids: Array) -> void:
	if not ready_ok or spike_ids.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for s in spike_ids:
		var i: int = int(id_to_inst.get(int(s), -1))
		if i >= 0:
			var base: Color = inst_base[i]
			multimesh.set_instance_color(i, Color(base.r, base.g, base.b, now))
