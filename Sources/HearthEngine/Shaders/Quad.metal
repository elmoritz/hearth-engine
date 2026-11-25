#include <metal_stdlib>
using namespace metal;

// Quads in target pixels (origin top-left, y down). Values are written verbatim: no blending, no colour space.

struct QuadVertexIn {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct QuadVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadFrameUniforms {
    float2 targetSize;
};

vertex QuadVertexOut quad_vertex(QuadVertexIn in [[stage_in]], constant QuadFrameUniforms &frame [[buffer(1)]]) {
    QuadVertexOut out;
    float2 ndc = in.position / frame.targetSize * 2.0 - 1.0;
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

fragment float4 quad_solid_fragment(QuadVertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
}

fragment float4 quad_textured_fragment(QuadVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       sampler nearest [[sampler(0)]]) {
    return source.sample(nearest, in.uv);
}
