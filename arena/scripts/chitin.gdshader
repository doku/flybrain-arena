shader_type spatial;

// Beetle-shell thorax + glossy eyes: dark core, team-colored fresnel
// rim, faint view-angle iridescence, uniform hit flash. Applied to the
// micro-CT thorax/eye meshes (no UVs on those meshes; NORMAL + VIEW
// only, so this is immune to scan-unit scaling).

uniform vec3 team_tint : source_color = vec3(1.0, 0.55, 0.30);
uniform vec3 shell_dark : source_color = vec3(0.10, 0.06, 0.05);
uniform float rim_strength : hint_range(0.0, 2.0) = 1.2;
uniform float iridescence : hint_range(0.0, 1.0) = 0.35;
uniform float flash_energy : hint_range(0.0, 3.0) = 0.0;
uniform float roughness_lo : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	float fres = pow(1.0 - max(dot(normalize(NORMAL), normalize(VIEW)), 0.0), 2.5);
	// Team color reads at every angle, blooming toward the silhouette.
	vec3 col = mix(shell_dark, team_tint, 0.45 + 0.45 * fres);
	// Oil-slick sheen: channel-swapped tint riding the rim.
	vec3 slick = team_tint.brg * vec3(0.85, 1.0, 1.15);
	col = mix(col, slick, iridescence * fres * 0.6);
	// Hit flash: hot white strike bloom.
	vec3 flash_col = vec3(1.0, 0.96, 0.88) * flash_energy;
	ALBEDO = col + flash_col * 0.6;
	EMISSION = team_tint * fres * rim_strength * 0.35 + flash_col * 1.2;
	ROUGHNESS = roughness_lo;
	SPECULAR = 0.6;
}
