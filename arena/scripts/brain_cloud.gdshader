shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_disabled;

// Per-instance COLOR: rgb = pool base color, a = engine-time (s) of the
// cell's last spike. Glow decays in-shader so the CPU only writes the
// cells that actually fired. Timestamp rides the alpha channel because
// INSTANCE_CUSTOM_DATA is not available on all renderers (it fails to
// compile on Forward Mobile).

uniform float decay_rate = 3.0;
uniform float flash_boost = 2.6;

varying float spike_glow;
varying vec3 pool_rgb;

void vertex() {
	float age = TIME - COLOR.a;
	spike_glow = exp(-max(age, 0.0) * decay_rate);
	pool_rgb = COLOR.rgb;
}

void fragment() {
	// Soft-ball soma: silhouette edges melt instead of clipping.
	float facing = max(dot(normalize(NORMAL), normalize(VIEW)), 0.0);
	float soft = mix(0.5, 1.0, pow(facing, 0.7));
	// Punchier flash curve: full attack, brighter decay tail.
	float glow = pow(clamp(spike_glow, 0.0, 1.0), 0.6);
	vec3 base = pool_rgb * 0.45;
	vec3 hot = vec3(1.0, 0.98, 0.92) * glow * flash_boost;
	ALBEDO = (base + hot) * soft;
	EMISSION = hot * soft;
}
