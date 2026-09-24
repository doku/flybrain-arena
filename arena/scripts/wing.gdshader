shader_type spatial;
render_mode blend_mix, cull_disabled;

// Glassy wing membranes: low ghost opacity face-on, silvered edge at
// grazing angles + traveling normal-space shimmer. NORMAL + VIEW only
// (scan meshes carry no UVs); per-fly `phase` keeps Alpha/Beta unsynced.

uniform vec4 tint : source_color = vec4(0.85, 0.90, 0.95, 1.0);
uniform float phase = 0.0;
uniform float shimmer_speed = 3.0;

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float fres = pow(1.0 - abs(dot(n, v)), 2.0);
	float band = 0.5 + 0.5 * sin(dot(n, vec3(2.0, 1.0, 3.0)) * 6.0
		- TIME * shimmer_speed + phase);
	ALBEDO = tint.rgb;
	ALPHA = clamp(0.10 + 0.25 * fres + 0.08 * band * fres, 0.0, 0.43);
	EMISSION = tint.rgb * (band * 0.05 + fres * 0.08);
	ROUGHNESS = 0.15;
	SPECULAR = 0.7;
}
