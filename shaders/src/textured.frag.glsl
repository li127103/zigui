#version 450

layout(binding = 0) uniform sampler2D tex_sampler;

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

void main() {
    // tex_color = (1,1,1,coverage) 来自 R8 swizzle
    // 预乘 alpha: rgb 必须乘以 coverage，配合 (ONE, ONE_MINUS_SRC_ALPHA) 混合
    vec4 tex_color = texture(tex_sampler, frag_uv);
    float alpha = tex_color.a * frag_color.a;
    out_color = vec4(frag_color.rgb * alpha, alpha);
}
