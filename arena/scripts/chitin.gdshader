shader_type spatial;

// Jersey thorax + glossy eyes: bold matte team color over a dark
// shell, colored rim light only (no white), uniform hit flash.
// Applied to the micro-CT thorax/eye meshes (no UVs on those meshes;
// NORMAL + VIEW only, so this is immune to scan-unit scaling).

uniform vec3 team_tint : source_color = vec3(1.0, 0.55, 0.30);
uniform vec3 shell_dark : source_color = vec3(0.08, 0.05, 0.04);
uniform float rim_strength : hint_range(0.0, 2.0) = 1.2;
uniform float iridescence : hint_range(0.0, 1.0) = 0.15;
uniform float flash_energy : hint_range(0.0, 3.0) = 0.0;
uniform float roughness_lo : hint_range(0.0, 1.0) = 0.7;
uniform float specular_amt : hint_range(0.0, 1.0) = 0.15;
// 3D depth factor: UI swatches are unlit, but this albedo sits under a
// bright sun + sky ambient that would bleach it white. Deepening the
// diffuse keeps burnt-orange / cobalt bodies that never clip.
uniform float tint_depth : hint_range(0.2, 1.0) = 0.55;

void fragment() {
	float fres = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), 2.5);
	vec3 jersey = team_tint * tint_depth;
	// Jersey coverage: deep team color at every angle, dark shell
	// shades the form underneath instead of replacing the hue.
	vec3 col = mix(shell_dark, jersey, 0.6 + 0.3 * fres);
	// Faint oil-slick sheen riding the rim; mostly team hue.
	vec3 slick = jersey.brg * vec3(0.85, 1.0, 1.15);
	col = mix(col, slick, iridescence * fres * 0.6);
	// Hit flash: hot white strike bloom (zero at rest, so no wash).
	vec3 flash_col = vec3(1.0, 0.96, 0.88) * flash_energy;
	ALBEDO = col + flash_col * 0.6;
	EMISSION = team_tint * fres * rim_strength * 0.15 + flash_col * 1.2;
	ROUGHNESS = roughness_lo;
	SPECULAR = specular_amt;
}
