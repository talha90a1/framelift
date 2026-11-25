// SPDX-License-Identifier: AGPL-3.0-only
// Last-resort generated frame: motion-free 50/50 blend of A and B (~0.1 ms at 1080p).
// Inputs may be 8- or 10-bit planes (normalised reads); output is an 8-bit 420v surface.
#include <metal_stdlib>
using namespace metal;

kernel void blend_frames(texture2d<float> lumaA [[texture(0)]],
                         texture2d<float> lumaB [[texture(1)]],
                         texture2d<float> chromaA [[texture(2)]],
                         texture2d<float> chromaB [[texture(3)]],
                         texture2d<float, access::write> lumaOut [[texture(5)]],
                         texture2d<float, access::write> chromaOut [[texture(6)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chromaOut.get_width() || gid.y >= chromaOut.get_height()) return;
    for (uint k = 0; k < 4; ++k) {
        const uint2 at = gid * 2 + uint2(k & 1, k >> 1);
        if (at.x >= lumaOut.get_width() || at.y >= lumaOut.get_height()) continue;
        lumaOut.write(float4(0.5 * (lumaA.read(at).r + lumaB.read(at).r)), at);
    }
    chromaOut.write(float4(0.5 * (chromaA.read(gid).rg + chromaB.read(gid).rg), 0.0, 1.0), gid);
}

// Static-overlay guard for Apple's generated frame: subtitles, HUD and prompts that do not move
// between the two real frames are copied from them, so the model cannot drag them with the
// background behind. Applies only where a pixel is unchanged in A and B and sits in local
// contrast (text and UI edges); moving or flat areas keep the generated pixel.
constant float kStaticLo = 5.0 / 255.0;
constant float kStaticHi = 14.0 / 255.0;
constant float kEdgeLo = 0.10;
constant float kEdgeHi = 0.20;

kernel void protect_subtitles(texture2d<float> lumaA [[texture(0)]],
                              texture2d<float> lumaB [[texture(1)]],
                              texture2d<float> chromaA [[texture(2)]],
                              texture2d<float> chromaB [[texture(3)]],
                              texture2d<float> lumaG [[texture(4)]],
                              texture2d<float, access::write> lumaOut [[texture(5)]],
                              texture2d<float, access::write> chromaOut [[texture(6)]],
                              texture2d<float> chromaG [[texture(7)]],
                              constant uint& count [[buffer(0)]],
                              constant float4* boxes [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chromaOut.get_width() || gid.y >= chromaOut.get_height()) return;
    const int2 last = int2(lumaB.get_width() - 1, lumaB.get_height() - 1);
    float total = 0;
    for (uint k = 0; k < 4; ++k) {
        const uint2 at = gid * 2 + uint2(k & 1, k >> 1);
        if (at.x >= lumaOut.get_width() || at.y >= lumaOut.get_height()) continue;
        const float2 uv = (float2(at) + 0.5) / float2(lumaB.get_width(), lumaB.get_height());
        bool inside = false;
        for (uint i = 0; i < count; ++i) inside |= all(uv >= boxes[i].xy) && all(uv <= boxes[i].zw);
        const float b = lumaB.read(at).r, g = lumaG.read(at).r;
        float weight = 0;
        if (inside) {
            float white = 0, dark = 1, stableWhite = 0;
            for (int y = -3; y <= 3; ++y) for (int x = -4; x <= 4; ++x) {
                const uint2 p = uint2(clamp(int2(at) + int2(x, y), int2(0), last));
                const float v = lumaB.read(p).r;
                white = max(white, v); dark = min(dark, v);
                stableWhite = max(stableWhite, v * (1 - smoothstep(0.025, 0.065, abs(lumaA.read(p).r - v))));
            }
            weight = smoothstep(0.45, 0.7, stableWhite) * smoothstep(0.15, 0.3, white - dark);
        }
        lumaOut.write(float4(mix(g, b, weight)), at);
        total += weight;
    }
    chromaOut.write(float4(mix(chromaG.read(gid).rg, chromaB.read(gid).rg, total * 0.25), 0, 1), gid);
}

kernel void keep_static(texture2d<float> lumaA [[texture(0)]],
                        texture2d<float> lumaB [[texture(1)]],
                        texture2d<float> chromaA [[texture(2)]],
                        texture2d<float> chromaB [[texture(3)]],
                        texture2d<float> lumaG [[texture(4)]],
                        texture2d<float, access::write> lumaOut [[texture(5)]],
                        texture2d<float, access::write> chromaOut [[texture(6)]],
                        texture2d<float> chromaG [[texture(7)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chromaOut.get_width() || gid.y >= chromaOut.get_height()) return;
    const int2 lmax = int2(lumaB.get_width() - 1, lumaB.get_height() - 1);
    // Local contrast of B over the 4x4 luma block around this chroma site.
    float lo = 1.0, hi = 0.0;
    for (int dy = -1; dy <= 2; ++dy) {
        for (int dx = -1; dx <= 2; ++dx) {
            const uint2 p = uint2(clamp(int2(gid * 2) + int2(dx, dy), int2(0), lmax));
            const float v = lumaB.read(p).r;
            lo = min(lo, v); hi = max(hi, v);
        }
    }
    const float edge = smoothstep(kEdgeLo, kEdgeHi, hi - lo);
    const float2 ca = chromaA.read(gid).rg, cb = chromaB.read(gid).rg;
    const float cdiff = max(abs(ca.x - cb.x), abs(ca.y - cb.y));
    float wsum = 0.0;
    for (uint k = 0; k < 4; ++k) {
        const uint2 at = gid * 2 + uint2(k & 1, k >> 1);
        if (at.x >= lumaOut.get_width() || at.y >= lumaOut.get_height()) continue;
        const float a = lumaA.read(at).r, b = lumaB.read(at).r;
        const float w = edge * (1.0 - smoothstep(kStaticLo, kStaticHi, max(abs(a - b), cdiff)));
        wsum += w;
        lumaOut.write(float4(mix(lumaG.read(at).r, 0.5 * (a + b), w)), at);
    }
    chromaOut.write(float4(mix(chromaG.read(gid).rg, 0.5 * (ca + cb), 0.25 * wsum), 0.0, 1.0), gid);
}
