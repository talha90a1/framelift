// SPDX-License-Identifier: AGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

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
                              constant uint& textCount [[buffer(2)]],
                              constant uint& reticleEnd [[buffer(3)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chromaOut.get_width() || gid.y >= chromaOut.get_height()) return;
    const int2 last = int2(lumaB.get_width() - 1, lumaB.get_height() - 1);
    float total = 0;
    for (uint k = 0; k < 4; ++k) {
        const uint2 at = gid * 2 + uint2(k & 1, k >> 1);
        if (at.x >= lumaOut.get_width() || at.y >= lumaOut.get_height()) continue;
        bool inside = false, reticle = false, hud = false;
        for (uint i = 0; i < count; ++i) {
            const bool hit = all(float2(at) >= boxes[i].xy) && all(float2(at) < boxes[i].zw);
            inside |= hit && i < textCount;
            reticle |= hit && i >= textCount && i < reticleEnd;
            hud |= hit && i >= reticleEnd;
        }
        const float b = lumaB.read(at).r, g = lumaG.read(at).r;
        float weight = reticle ? 1 : 0;
        if (hud && !reticle) {
            const float2 delta = abs(chromaA.read(gid).rg - chromaB.read(gid).rg);
            const float change = max(abs(lumaA.read(at).r - b), max(delta.x, delta.y));
            weight = 1 - smoothstep(6.0 / 255.0, 14.0 / 255.0, change);
        }
        if (inside && !reticle) {
            float white = 0, dark = 1, stableWhite = 0;
            for (int y = -3; y <= 3; ++y) for (int x = -4; x <= 4; ++x) {
                const uint2 p = uint2(clamp(int2(at) + int2(x, y), int2(0), last));
                const float v = lumaB.read(p).r;
                white = max(white, v); dark = min(dark, v);
                stableWhite = max(stableWhite, v * (1 - smoothstep(0.025, 0.065, abs(lumaA.read(p).r - v))));
            }
            const float stable = 1 - smoothstep(0.025, 0.065, abs(lumaA.read(at).r - b));
            weight = stable * smoothstep(0.45, 0.7, stableWhite) * smoothstep(0.15, 0.3, white - dark);
        }
        lumaOut.write(float4(mix(g, b, weight)), at);
        total += weight;
    }
    chromaOut.write(float4(mix(chromaG.read(gid).rg, chromaB.read(gid).rg, total * 0.25), 0, 1), gid);
}
