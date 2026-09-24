shader_type spatial;

// Painted stylized glade floor: dithered grass tones, mown arena
// markings (center joust ring, team spawn pads, soft outer ring),
// distance melt into fog. Mobile-safe: no textures, 3-octave value
// noise, hash dither for the RGB10A2 banding.

uniform vec3 grass_light : source_color = vec3(0.32, 0.58, 0.22);
uniform vec3 grass_dark : source_color = vec3(0.18, 0.40, 0.15);
uniform vec3 grass_dry : source_color = vec3(0.52, 0.55, 0.28);
uniform vec3 paint_white : source_color = vec3(0.92, 0.93, 0.86);
uniform vec3 team_alpha : source_color = vec3(1.0, 0.55, 0.30);
uniform vec3 team_beta : source_color = vec3(0.4, 0.75, 1.0);
uniform vec2 pad_a = vec2(-14.0, 0.0);
uniform vec2 pad_b = vec2(14.0, 0.0);
uniform float roughness_hi : hint_range(0.0, 1.0) = 0.92;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
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

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 3; i++) {
		v += amp * vnoise(p);
		p = p * 2.03 + vec2(17.3, 9.1);
		amp *= 0.5;
	}
	return v;
}

float ring(float d, float r, float w) {
	return 1.0 - smoothstep(w * 0.5, w, abs(d - r));
}

void fragment() {
	// Patchwork: large meadow blobs + fine blade speckle + dry sunny spots.
	float meadow = fbm(world_xz * 0.055);
	float speckle = vnoise(world_xz * 1.7);
	float dry = smoothstep(0.62, 0.78, fbm(world_xz * 0.11 + 4.7));
	vec3 col = mix(grass_dark, grass_light, smoothstep(0.25, 0.75, meadow));
	col = mix(col, grass_dry, dry * 0.55);
	col *= 0.92 + 0.16 * speckle;

	float dist_c = length(world_xz);
	// Mown center: slightly lighter disc where the joust opens.
	col = mix(col, col * 1.07 + vec3(0.01), 1.0 - smoothstep(7.0, 12.0, dist_c));
	// Painted markings, worn (noise-eroded edges).
	float wear = 0.55 + 0.45 * speckle;
	col = mix(col, paint_white, ring(dist_c, 6.0, 0.45) * 0.38 * wear);
	float pa = 1.0 - smoothstep(2.2, 2.7, length(world_xz - pad_a));
	float pb = 1.0 - smoothstep(2.2, 2.7, length(world_xz - pad_b));
	col = mix(col, team_alpha, pa * 0.50 * wear);
	col = mix(col, team_beta, pb * 0.50 * wear);
	col = mix(col, paint_white,
		(ring(length(world_xz - pad_a), 2.9, 0.3)
		+ ring(length(world_xz - pad_b), 2.9, 0.3)) * 0.35 * wear);
	col = mix(col, paint_white * 0.9, ring(dist_c, 30.0, 0.8) * 0.16 * wear);

	// Dither against banding, then standard PBR out.
	col += (hash12(world_xz * 61.7) - 0.5) * (3.0 / 1024.0);
	ALBEDO = col;
	ROUGHNESS = roughness_hi;
}
