shader_type spatial;
render_mode diffuse_burley;

varying vec3 world_position;
varying vec3 face_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	face_normal = abs(NORMAL);
}

void fragment() {
	vec3 grid = world_position * 2.0;
	vec3 distance_to_edge = abs(fract(grid + 0.5) - 0.5);
	vec3 width = max(fwidth(grid) * 0.8, vec3(0.012));
	vec3 line = 1.0 - smoothstep(vec3(0.0), width, distance_to_edge);
	vec3 plane_lines = line * (vec3(1.0) - face_normal);
	float edge = max(plane_lines.x, max(plane_lines.y, plane_lines.z));
	ALBEDO = COLOR.rgb * mix(1.0, 0.78, edge);
	ROUGHNESS = 0.95;
}
