shader_type spatial;
render_mode blend_mix, cull_disabled;

// Pearly wing membranes: fresnel-driven opacity (ghostly face-on,
// silvered at grazing angles) + traveling normal-space shimmer bands.
// NORMAL + VIEW only (scan meshes carry no UVs); per-fly `phase` keeps
// Alpha/Beta out of sync.

uniform vec4 tint : source_color = vec4(0.90, 0.94, 1.0, 1.0);
uniform float phase = 0.0;
uniform float shimmer_speed = 3.0;

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	float fres = pow(1.0 - abs(dot(n, v)), 2.0);
	float band = 0.5 + 0.5 * sin(dot(n, vec3(2.0, 1.0, 3.0)) * 6.0
		- TIME * shimmer_speed + phase);
	ALBEDO = tint.rgb;
	ALPHA = clamp(0.22 + 0.55 * fres + 0.12 * band * fres, 0.0, 0.92);
	EMISSION = tint.rgb * (band * 0.10 + fres * 0.18);
	ROUGHNESS = 0.15;
	SPECULAR = 0.7;
}
