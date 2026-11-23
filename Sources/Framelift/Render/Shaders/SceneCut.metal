// SPDX-License-Identifier: AGPL-3.0-only
// Shot-change test for one interpolation pair (ported from Veyra's VfgShotChange.hlsl): luma histogram
// distance and SAD; a flash (large SAD, near-identical histogram) is not a cut.
#include <metal_stdlib>
using namespace metal;

struct SceneCutParams {
    uint width;
    uint height;
    uint compare;        // 0: no valid A, never a cut
    uint videoRange;     // 1: expand Y 16..235 to 0..255 (Veyra's thresholds are full-range luma)
    float cutSad;        // SceneCadenceAnalyzer::Config defaults
    float cutHistogram;
    float replacementSad;
    float replacementHistogram;
    float flashSad;
    float flashHistogram;
    float pad1;
    float pad2;
};

constant uint kCutColumns = 64;
constant uint kCutRows = 36;
constant uint kCutSamples = kCutColumns * kCutRows;

// out[0] = 1 on a cut, out[1] = SAD bits, out[2] = histogram distance bits.
kernel void scene_cut(texture2d<float, access::read> previousLuma [[texture(0)]],
                      texture2d<float, access::read> currentLuma [[texture(1)]],
                      device uint *out [[buffer(0)]],
                      constant SceneCutParams &p [[buffer(1)]],
                      uint index [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint histogramPrevious[256];
    threadgroup atomic_uint histogramCurrent[256];
    threadgroup atomic_uint sadSum;
    threadgroup atomic_uint histogramL1;

    atomic_store_explicit(&histogramPrevious[index], 0u, memory_order_relaxed);
    atomic_store_explicit(&histogramCurrent[index], 0u, memory_order_relaxed);
    if (index == 0) {
        atomic_store_explicit(&sadSum, 0u, memory_order_relaxed);
        atomic_store_explicit(&histogramL1, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (p.compare != 0) {
        for (uint i = index; i < kCutSamples; i += 256) {
            const uint2 at = uint2((i % kCutColumns) * p.width / kCutColumns,
                                   (i / kCutColumns) * p.height / kCutRows);
            float fa = previousLuma.read(at).r * 255.0, fb = currentLuma.read(at).r * 255.0;
            if (p.videoRange != 0) { fa = (fa - 16.0) * (255.0 / 219.0); fb = (fb - 16.0) * (255.0 / 219.0); }
            const uint a = uint(clamp(fa + 0.5, 0.0, 255.0));
            const uint b = uint(clamp(fb + 0.5, 0.0, 255.0));
            atomic_fetch_add_explicit(&histogramPrevious[a], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&histogramCurrent[b], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&sadSum, a > b ? a - b : b - a, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint hp = atomic_load_explicit(&histogramPrevious[index], memory_order_relaxed);
    const uint hc = atomic_load_explicit(&histogramCurrent[index], memory_order_relaxed);
    atomic_fetch_add_explicit(&histogramL1, hp > hc ? hp - hc : hc - hp, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        const float sad = float(atomic_load_explicit(&sadSum, memory_order_relaxed)) / (255.0 * float(kCutSamples));
        const float histogram = float(atomic_load_explicit(&histogramL1, memory_order_relaxed)) / (2.0 * float(kCutSamples));
        const bool flash = sad > p.flashSad && histogram < p.flashHistogram;
        const bool cut = p.compare != 0 && !flash &&
            ((sad > p.cutSad && histogram > p.cutHistogram) ||
             (sad > p.replacementSad && histogram > p.replacementHistogram));
        out[0] = cut ? 1u : 0u;
        out[1] = as_type<uint>(sad);
        out[2] = as_type<uint>(histogram);
    }
}
