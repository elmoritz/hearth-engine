#include <metal_stdlib>
using namespace metal;

// Quads in target pixels (origin top-left, y down), composited into the scene attachment, then the final stage
// writes the target. Single pass: the scene is attachment 1, memoryless, and the final stage reads it through
// [[color(1)]] (programmable blending). Two passes (D18): the scene is a stored texture the final stage samples.
// Blending is the pipeline's (E-PASS-3); values are otherwise written verbatim, no colour space (D1 is open).

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

// Two-pass scene stages: the scene texture is attachment 0.

fragment float4 quad_solid_fragment(QuadVertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
}

fragment float4 quad_textured_fragment(QuadVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       sampler nearest [[sampler(0)]]) {
    return source.sample(nearest, in.uv);
}

// Single-pass scene stages: the scene is attachment 1; attachment 0 (the target) is not written.

struct SceneOut {
    float4 scene [[color(1)]];
};

fragment SceneOut quad_solid_scene_fragment(QuadVertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return SceneOut{color};
}

fragment SceneOut quad_textured_scene_fragment(QuadVertexOut in [[stage_in]],
                                               texture2d<float> source [[texture(0)]],
                                               sampler nearest [[sampler(0)]]) {
    return SceneOut{source.sample(nearest, in.uv)};
}

// The final stage: one triangle covering the whole target, so every target pixel is written.

struct FinalVertexOut {
    float4 position [[position]];
};

vertex FinalVertexOut final_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2(float((vid << 1) & 2), float(vid & 2));
    FinalVertexOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment float4 final_fetch_fragment(FinalVertexOut in [[stage_in]], float4 scene [[color(1)]]) {
    return scene;
}

fragment float4 final_sample_fragment(FinalVertexOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    return scene.read(uint2(in.position.xy));
}
