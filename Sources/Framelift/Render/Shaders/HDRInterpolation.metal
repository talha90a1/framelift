// SPDX-License-Identifier: AGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

struct HDRDecodeConstants {
    float4 r, g, b, range;
};

kernel void rescale_hdr_flow(texture2d<float> input [[texture(0)]],
                             texture2d<float, access::write> output [[texture(1)]],
                             uint2 at [[thread_position_in_grid]]) {
    if (at.x >= output.get_width() || at.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 size = float2(output.get_width(), output.get_height());
    const float2 scale = size / float2(input.get_width(), input.get_height());
    output.write(float4(input.sample(s, (float2(at) + 0.5f) / size).rg * scale, 0, 1), at);
}

kernel void hdr_to_rgb(texture2d<float> y [[texture(0)]],
                          texture2d<float> c [[texture(1)]],
                          texture2d<half, access::write> out [[texture(2)]],
                          constant HDRDecodeConstants& k [[buffer(0)]],
                          uint2 at [[thread_position_in_grid]]) {
    if (at.x >= out.get_width() || at.y >= out.get_height()) return;
    const float luma = y.read(at).r * k.range.x + k.range.y;
    const float2 chroma = c.read(at / 2).rg * k.range.z + k.range.w;
    const float3 ycc = float3(luma, chroma);
    const float3 rgb = float3(dot(k.r.xyz, ycc), dot(k.g.xyz, ycc), dot(k.b.xyz, ycc));
    out.write(half4(half3(clamp(rgb, 0.0f, 1.0f)), 1.0h), at);
}

kernel void rgb_to_hdr(texture2d<half> input [[texture(0)]],
                          texture2d<float, access::write> y [[texture(1)]],
                          texture2d<float, access::write> c [[texture(2)]],
                          constant float4& k [[buffer(0)]],
                          uint2 at [[thread_position_in_grid]]) {
    if (at.x >= c.get_width() || at.y >= c.get_height()) return;
    const float kr = k.x, kb = k.y, kg = 1.0f - kr - kb;
    const bool full = k.w != 0;
    float2 chroma = 0;
    for (uint i = 0; i < 4; ++i) {
        const uint2 p = at * 2 + uint2(i & 1, i >> 1);
        const float3 rgb = clamp(float3(input.read(p).rgb), 0.0f, 1.0f);
        const float luma = dot(rgb, float3(kr, kg, kb));
        const float code = round(clamp(luma * (full ? 1023.0f : 876.0f) + (full ? 0.0f : 64.0f), 0.0f, 1023.0f));
        y.write(float4(code * (64.0f / 65535.0f)), p);
        chroma += float2((rgb.b - luma) / (2.0f * (1.0f - kb)), (rgb.r - luma) / (2.0f * (1.0f - kr)));
    }
    const float2 code = round(clamp(chroma * 0.25f * (full ? 1023.0f : 896.0f) + 512.0f, 0.0f, 1023.0f));
    c.write(float4(code * (64.0f / 65535.0f), 0, 1), at);
}
