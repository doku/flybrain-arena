shader_type canvas_item;

// Cinematic vignette: warm-dark corners, dithered against banding.
// Lives on a layer-0 CanvasLayer (under the HUD, over the 3D view).

uniform vec4 tint : source_color = vec4(0.05, 0.03, 0.08, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.32;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 c = UV - vec2(0.5);
	float d = length(c * vec2(1.25, 1.0)) * 2.0;
	float v = smoothstep(0.55, 1.25, d) * strength;
	v += (hash12(UV * 913.7) - 0.5) * 0.02;
	COLOR = vec4(tint.rgb, clamp(v, 0.0, 1.0));
}
