#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

layout(push_constant) uniform PushConstants {
    vec2 screen_size;
} pc;

void main() {
    // Vulkan NDC: y=-1 在顶部, y=+1 在底部 (与 Metal/OpenGL 相反)
    vec2 ndc = vec2(
        pc.screen_size.x > 0.0 ? (in_pos.x / pc.screen_size.x) * 2.0 - 1.0 : 0.0,
        pc.screen_size.y > 0.0 ? (in_pos.y / pc.screen_size.y) * 2.0 - 1.0 : 0.0
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
    frag_uv = in_uv;
    frag_color = in_color;
}
