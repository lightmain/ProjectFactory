shader_type spatial;
render_mode diffuse_burley;

varying vec3 world_position;
varying vec3 face_normal;
varying vec4 decoration;

uniform bool decorations_enabled = false;
uniform vec3 decoration_camera = vec3(0.0);
uniform float decoration_distance = 0.0;
uniform vec4 output_color : source_color;
uniform vec4 input_color : source_color;
uniform bool transform_decoration_centers = false;
uniform vec3 decoration_origin = vec3(0.0);

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	face_normal = abs(NORMAL);
	decoration = CUSTOM0;
	if (transform_decoration_centers) {
		decoration.xyz = (MODEL_MATRIX * vec4(CUSTOM0.xyz - decoration_origin, 1.0)).xyz;
	}
}

void fragment() {
	vec3 grid = world_position * 2.0;
	vec3 distance_to_edge = abs(fract(grid + 0.5) - 0.5);
	vec3 width = max(fwidth(grid) * 0.8, vec3(0.012));
	vec3 line = 1.0 - smoothstep(vec3(0.0), width, distance_to_edge);
	vec3 plane_lines = line * (vec3(1.0) - face_normal);
	float edge = max(plane_lines.x, max(plane_lines.y, plane_lines.z));
	ALBEDO = COLOR.rgb * mix(1.0, 0.78, edge);
	if (decorations_enabled && decoration.a > 0.5
			&& distance(decoration_camera, decoration.xyz) <= decoration_distance) {
		float mask = 0.0;
		if (decoration.a < 1.5) {
			float shaft = min(0.025 - abs(UV.x), min(UV.y + 0.05, 0.17 - UV.y));
			float head = min((UV.y + 0.20) * 0.7 - abs(UV.x), min(UV.y + 0.20, -0.05 - UV.y));
			float aa = max(length(fwidth(UV)), 0.00001);
			mask = smoothstep(-aa * 0.5, aa * 0.5, max(shaft, head));
		} else {
			vec2 border = vec2(0.5) - abs(UV);
			vec2 aa = max(fwidth(UV), vec2(0.00001));
			vec2 coverage = smoothstep(-aa * 0.5, aa * 0.5, border);
			mask = coverage.x * coverage.y;
		}
		vec3 mark_color = decoration.a < 2.5 ? output_color.rgb : input_color.rgb;
		// Existing markers are unshaded; retain that colour without new geometry.
		ALBEDO *= 1.0 - mask;
		EMISSION = mark_color * mask;
		SPECULAR = 0.5 * (1.0 - mask);
	}
	ROUGHNESS = 0.95;
}
