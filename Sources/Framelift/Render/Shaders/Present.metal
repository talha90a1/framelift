// SPDX-License-Identifier: AGPL-3.0-only
// Bi-planar 4:2:0 (8/10-bit) -> gamma-encoded R'G'B' for the CAMetalLayer drawable; matrix and range
// come from the stream's tags (ColourPipeline.swift). Letterboxing is done with the viewport.
#include <metal_stdlib>
using namespace metal;

struct PresentVertexOut {
    float4 position [[position]];
    float2 uv;
};

// ColourMapping.constants (PresentColourConstants in Swift): 5 x float4.
struct PresentColour {
    float4 r;        // xyz: weights of (Y', Cb', Cr') for R
    float4 g;
    float4 b;
    float4 range;    // Y' = y * x + y, C' = c * z + w (y, c: unorm samples)
    float4 params;   // x: sharpening strength (sharp pass)
};

static inline float3 present_yuv_to_rgb(float luma, float2 chroma, constant PresentColour &k)
{
    const float3 v = float3(luma * k.range.x + k.range.y, chroma * k.range.z + k.range.w);
    return saturate(float3(dot(k.r.xyz, v), dot(k.g.xyz, v), dot(k.b.xyz, v)));
}

// One oversized triangle covering the viewport; no vertex buffer.
vertex PresentVertexOut present_vertex(uint vid [[vertex_id]])
{
    const float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PresentVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 present_fragment(PresentVertexOut in [[stage_in]],
                                 texture2d<float> lumaTexture [[texture(0)]],
                                 texture2d<float> chromaTexture [[texture(1)]],
                                 constant PresentColour &colour [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(present_yuv_to_rgb(lumaTexture.sample(s, in.uv).r, chromaTexture.sample(s, in.uv).rg, colour), 1.0);
}

// Catmull-Rom weights for the taps at -1, 0, +1, +2 around fraction f (sum 1). Polynomial, since a
// Lanczos window needs sin() per tap.
static inline float4 present_catmull_rom_weights(float f)
{
    const float f2 = f * f, f3 = f2 * f;
    return float4(-0.5 * f3 + f2 - 0.5 * f,
                  1.5 * f3 - 2.5 * f2 + 1.0,
                  -1.5 * f3 + 2.0 * f2 + 0.5 * f,
                  0.5 * f3 - 0.5 * f2);
}

// Upscaler: luma is Catmull-Rom bicubic + CAS-style sharpening with an anti-ringing clamp to the
// nearest 2x2 texels; chroma is bilinear (it carries little detail at 4:2:0).
fragment float4 present_sharp_fragment(PresentVertexOut in [[stage_in]],
                                       texture2d<float> lumaTexture [[texture(0)]],
                                       texture2d<float> chromaTexture [[texture(1)]],
                                       constant PresentColour &colour [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 size = float2(lumaTexture.get_width(), lumaTexture.get_height());
    const float2 p = in.uv * size - 0.5;
    const float2 base = floor(p);
    const float2 f = p - base;
    // Gathers around the texel corner base+1 cover texels base-1 .. base+2 on both axes.
    // gather(): w = (x0,y0), z = (x1,y0), x = (x0,y1), y = (x1,y1).
    const float2 c = (base + 1.0) / size;
    const float4 tl = lumaTexture.gather(s, c, int2(-1, -1));
    const float4 tr = lumaTexture.gather(s, c, int2( 1, -1));
    const float4 bl = lumaTexture.gather(s, c, int2(-1,  1));
    const float4 br = lumaTexture.gather(s, c, int2( 1,  1));
    const float4 r0 = float4(tl.w, tl.z, tr.w, tr.z);
    const float4 r1 = float4(tl.x, tl.y, tr.x, tr.y);
    const float4 r2 = float4(bl.w, bl.z, br.w, br.z);
    const float4 r3 = float4(bl.x, bl.y, br.x, br.y);
    const float4 wx = present_catmull_rom_weights(f.x);
    const float4 wy = present_catmull_rom_weights(f.y);
    const float lz = wy.x * dot(r0, wx) + wy.y * dot(r1, wx) + wy.z * dot(r2, wx) + wy.w * dot(r3, wx);

    // Nearest 2x2 texels: bilinear reference, and the range for anti-ringing.
    const float a = r1.y, b = r1.z, cc = r2.y, d = r2.z;
    const float bil = mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
    const float mn = min(min(a, b), min(cc, d));
    const float mx = max(max(a, b), max(cc, d));
    // CAS amplitude: 1 in flat or mid-contrast areas, falling to 0 near clipping / hard edges.
    const float amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
    float luma = lz + colour.params.x * amp * (lz - bil);
    luma = clamp(luma, mn, mx);

    return float4(present_yuv_to_rgb(luma, chromaTexture.sample(s, in.uv).rg, colour), 1.0);
}

// FPS HUD, drawn in the same pass (viewport = HUD rectangle, same full-screen triangle), so
// no extra layer sits above the CAMetalLayer. Text texture: r = glyph coverage, g = red.
fragment float4 hud_fragment(PresentVertexOut in [[stage_in]],
                             texture2d<float> text [[texture(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    const float2 t = text.sample(s, in.uv).rg;
    if (t.r > 0.5) {
        return t.g > 0.5 ? float4(1.0, 0.3, 0.3, 1.0) : float4(1.0, 1.0, 1.0, 1.0);
    }
    return float4(0.0, 0.0, 0.0, 0.6);
}
