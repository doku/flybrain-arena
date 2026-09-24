shader_type sky;

// Vibrant stylized sky: warm horizon, saturated zenith, soft sun disc
// locked to the scene DirectionalLight, slow painted cloud band.
// Animation lives in the cubemap pass only; the visible pass reads the
// radiance cache, so TIME-driven clouds don't multiply shader cost.

uniform vec3 zenith_color : source_color = vec3(0.20, 0.46, 0.86);
uniform vec3 mid_color : source_color = vec3(0.45, 0.68, 0.92);
uniform vec3 horizon_color : source_color = vec3(0.98, 0.83, 0.62);
uniform vec3 ground_haze : source_color = vec3(0.55, 0.62, 0.55);
uniform vec3 cloud_tint : source_color = vec3(1.0, 0.97, 0.94);
uniform vec3 cloud_shade : source_color = vec3(0.72, 0.80, 0.90);
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.55;
uniform float cloud_speed = 0.008;

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
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p = p * 2.11 + vec2(13.7, 7.3);
		amp *= 0.5;
	}
	return v;
}

vec3 sky_color(vec3 dir) {
	float h = clamp(dir.y, -1.0, 1.0);
	vec3 col;
	if (h >= 0.0) {
		vec3 low = mix(mid_color, horizon_color, pow(1.0 - h, 3.0));
		col = mix(low, zenith_color, smoothstep(0.15, 0.85, h));
	} else {
		col = mix(mid_color * 0.9, ground_haze, smoothstep(0.0, -0.4, h));
	}
	if (h > 0.01) {
		// Painted cloud band: dome-projected FBM drifting with TIME.
		vec2 cuv = dir.xz / (dir.y + 0.18);
		float t = TIME * cloud_speed;
		float cl = fbm(cuv * 1.4 + vec2(t, t * 0.35));
		cl = smoothstep(1.0 - cloud_coverage - 0.25, 1.0 - cloud_coverage + 0.35, cl);
		cl *= smoothstep(0.01, 0.25, h);
		float shade = fbm(cuv * 2.6 - vec2(t * 1.7, 0.0));
		col = mix(col, mix(cloud_shade, cloud_tint, shade), cl * 0.85);
	}
	if (LIGHT0_ENABLED) {
		float sun_d = dot(dir, -LIGHT0_DIRECTION);
		float disc = smoothstep(0.9992, 0.9997, sun_d);
		float glow = pow(clamp(sun_d, 0.0, 1.0), 24.0) * 0.35;
		col += LIGHT0_COLOR * (disc * 2.2 + glow) * LIGHT0_ENERGY * step(0.0, h);
	}
	// Dither against RGB10A2 banding.
	col += (hash12(dir.xy * 541.3 + vec2(fract(TIME) * 7.0, 0.0)) - 0.5) * (3.0 / 1024.0);
	return col;
}

void sky() {
	if (AT_CUBEMAP_PASS) {
		COLOR = sky_color(EYEDIR);
	} else {
		COLOR = texture(RADIANCE, EYEDIR).rgb;
	}
}
