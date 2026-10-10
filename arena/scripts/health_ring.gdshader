shader_type spatial;
render_mode unshaded, cull_disabled;

// Ground-projected combat ring: team rim that falls back to amber/red
// as HP drops, magenta seizure pulse, dim when KO'd, plus an expanding
// KO shockwave (`shock` 0 = off, else 0..1). Readability first: this is
// the in-world health bar.

uniform float hp : hint_range(0.0, 1.0) = 1.0;
uniform vec3 team_color : source_color = vec3(1.0, 0.55, 0.30);
uniform float seizing = 0.0;
uniform float ko = 0.0;
uniform float shock = 0.0;

void fragment() {
	vec2 c = UV - vec2(0.5);
	float d = length(c) * 2.0;
	vec3 hp_col = team_color;
	if (hp < 0.35) {
		hp_col = vec3(1.0, 0.65, 0.15);
	}
	if (hp < 0.15) {
		hp_col = vec3(1.0, 0.22, 0.15);
	}
	if (ko > 0.5) {
		hp_col = vec3(0.25, 0.25, 0.28);
	}
	float ring = 1.0 - smoothstep(0.06, 0.12, abs(d - 0.82));
	float fill = (1.0 - smoothstep(0.0, 0.78, d)) * 0.10;
	float pulse = 1.0;
	if (seizing > 0.5) {
		hp_col = mix(hp_col, vec3(1.0, 0.2, 1.0), 0.5 + 0.5 * sin(TIME * 10.0));
	} else if (hp < 0.25 && ko < 0.5) {
		pulse = 0.7 + 0.3 * sin(TIME * 6.0);
	}
	float a = (ring * 0.85 + fill) * pulse;
	if (shock > 0.001) {
		float sw = 1.0 - smoothstep(0.0, 0.25, abs(d - shock));
		a = max(a, sw * (1.0 - shock) * 0.9);
		hp_col = mix(hp_col, vec3(1.0, 1.0, 1.0), sw * 0.7);
	}
	if (ko > 0.5 && shock < 0.001) {
		a *= 0.35;
	}
	ALBEDO = hp_col;
	ALPHA = clamp(a, 0.0, 1.0);
}
