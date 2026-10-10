shader_type spatial;

// Wind sway for bushes + grass tufts (trees explicitly excluded: their
// materials feed the occlusion-fade system). One shader, two tunings
// via uniforms: grass bends by height, bushes wobble near-rigid.
// Per-instance phase is hashed from the instance origin, so the shared
// meshes/materials still move out of sync. Mobile-safe: TIME + MODEL.

uniform vec3 base_color : source_color = vec3(0.24, 0.47, 0.17);
uniform float sway_amp = 0.15;
uniform float bend_amount : hint_range(0.0, 1.0) = 1.0;
uniform float mesh_half_height = 0.55;
uniform vec2 wind_dir = vec2(1.0, 0.35);
uniform float roughness_hi : hint_range(0.0, 1.0) = 0.9;

varying vec2 world_xz;
varying float local_h;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	local_h = clamp((VERTEX.y + mesh_half_height) / (2.0 * mesh_half_height), 0.0, 1.0);
	// Per-instance phase: underbrush renders as MultiMeshes, so the
	// origin hash is replaced by the instance id (guaranteed unique
	// per instance on all renderers).
	float phase = fract(float(INSTANCE_ID) * 0.6180339 + 0.13) * 6.2831;
	float gust = 0.6 + 0.4 * sin(TIME * 0.7 + phase * 1.7);
	float w = mix(1.0, smoothstep(0.0, 1.0, local_h), bend_amount);
	VERTEX.xz += wind_dir * (sway_amp * w * gust);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	// Two-tone leaf dither + darker roots for a hand-painted tuft.
	float tone = vnoise(world_xz * 2.3);
	vec3 col = base_color * mix(0.82, 1.14, tone);
	col *= mix(0.8, 1.05, local_h);
	col += (hash12(world_xz * 91.3) - 0.5) * (3.0 / 1024.0);
	ALBEDO = col;
	ROUGHNESS = roughness_hi;
}
