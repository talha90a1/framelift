// SPDX-License-Identifier: AGPL-3.0-only
// Upscaler timing and pictures on a recorded stream (dev only). FRAMELIFT_CLIP + FRAMELIFT_UPSCALE_FRAME +
// FRAMELIFT_OUT: GPU time of the sharp pass and MetalFX at 1440p and 4K, alone and while Apple ML
// interpolates, and <out>/upscale-<method>-<height>.png.
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Testing
@testable import Framelift

@Suite struct OfflineUpscaleHarness {
    // The decoded buffers are read-only while the benchmark runs.
    private struct InputPair: @unchecked Sendable {
        let previous: CVPixelBuffer
        let current: CVPixelBuffer
    }

    @Test func compareUpscalers() throws {
        let env = ProcessInfo.processInfo.environment
        guard let clip = env["FRAMELIFT_CLIP"], let out = env["FRAMELIFT_OUT"],
            let k = env["FRAMELIFT_UPSCALE_FRAME"].flatMap(Int.init)
        else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let frames = try OfflineFrameGenHarness.decode(clip: clip, from: k, count: 2, w: 1920, h: 1080)
        try #require(frames.count == 2)
        let pair = InputPair(previous: frames[0], current: frames[1])
        let ctx = try RenderContext.shared()
        let encoder = try PresentEncoder(context: ctx)
        let interp = AppleLLFIInterpolator(keepWarm: false)
        interp.prepare(width: 1920, height: 1080)
        for _ in 0..<200 where !interp.isReady(for: pair.previous) { Thread.sleep(forTimeInterval: 0.05) }
        try #require(interp.isReady(for: pair.previous))

        for (w, h) in [(2560, 1440), (3840, 2160)] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            let target = try #require(ctx.device.makeTexture(descriptor: d))
            for upscaler in Upscaler.allCases {
                encoder.upscaler = upscaler
                var method = UpscaleMethod.bilinear
                func present() throws -> Double {
                    let cb = try #require(ctx.queue.makeCommandBuffer())
                    let done = try #require(encoder.encode(pair.previous, into: target, commandBuffer: cb, hud: nil))
                    method = done.method
                    cb.commit()
                    cb.waitUntilCompleted()
                    withExtendedLifetime(done.keep) {}
                    return (cb.gpuEndTime - cb.gpuStartTime) * 1000
                }
                for _ in 0..<5 { _ = try present() }
                let alone = try (0..<60).map { _ in try present() }.sorted()

                // Presents and interpolations at the same time, as in a stream.
                let interpMs = Locked<[Double]>([])
                let running = Locked(true)
                let finished = DispatchSemaphore(value: 0)
                let worker = Thread {
                    defer { finished.signal() }
                    while running.value {
                        let sem = DispatchSemaphore(value: 0)
                        interp.interpolate(previous: pair.previous, current: pair.current) { r in
                            if r.error == nil { interpMs.update { $0.append(r.wallMs) } }
                            sem.signal()
                        }
                        sem.wait()
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                }
                worker.start()
                let together: [Double]
                do {
                    defer {
                        running.value = false
                        finished.wait()
                    }
                    together = try (0..<60).map { _ in
                        let t = try present()
                        Thread.sleep(forTimeInterval: 0.008)
                        return t
                    }.sorted()
                }
                let im = interpMs.value.sorted()
                print(
                    String(
                        format: "upscale %@ %dx%d (%@): GPU median %.2f ms, p95 %.2f ms; with Apple ML %.2f ms; Apple ML median %.1f ms (n=%d)",
                        upscaler.rawValue, w, h, method.rawValue, alone[30], alone[57], together[30],
                        im.isEmpty ? 0 : im[im.count / 2], im.count))
                try Self.png(target, "\(out)/upscale-\(upscaler.rawValue)-\(h).png")
            }
        }
        // Apple ML alone, for comparison.
        var alone: [Double] = []
        for _ in 0..<40 {
            let sem = DispatchSemaphore(value: 0)
            interp.interpolate(previous: pair.previous, current: pair.current) { r in
                if r.error == nil { alone.append(r.wallMs) }
                sem.signal()
            }
            sem.wait()
            Thread.sleep(forTimeInterval: 0.02)
        }
        alone.sort()
        print(String(format: "Apple ML alone: median %.1f ms (n=%d)", alone.isEmpty ? 0 : alone[alone.count / 2], alone.count))
    }

    final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
        func update(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
    }

    static func png(_ texture: MTLTexture, _ path: String) throws {
        let (w, h) = (texture.width, texture.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(
            CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
