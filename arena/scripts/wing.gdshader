shader_type spatial;
render_mode blend_mix, cull_disabled;

// Smoky dipteran membranes: dark translucent grey-brown like a real
// fruit fly wing, near-flat opacity, faint traveling shade bands and
// almost no emission. Dark veins (separate material) do the talking.
// NORMAL + VIEW only (scan meshes carry no UVs); per-fly `phase`
// keeps Alpha/Beta unsynced.

uniform vec4 tint : source_color = vec4(0.32, 0.28, 0.26, 1.0);
uniform float phase = 0.0;
uniform float shimmer_speed = 3.0;

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float fres = pow(1.0 - abs(dot(n, v)), 2.0);
	float band = 0.5 + 0.5 * sin(dot(n, vec3(2.0, 1.0, 3.0)) * 6.0
		- TIME * shimmer_speed + phase);
	ALBEDO = tint.rgb;
	ALPHA = clamp(0.28 + 0.15 * fres + 0.05 * band, 0.0, 0.48);
	EMISSION = tint.rgb * band * 0.02;
	ROUGHNESS = 0.45;
	SPECULAR = 0.2;
}
