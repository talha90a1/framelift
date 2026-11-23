// SPDX-License-Identifier: AGPL-3.0-only
// Offline check of frame generation on a recorded stream (dev only). Runs when FRAMELIFT_CLIP points to a
// recording; FRAMELIFT_FRAMES lists frame indices k (each pair k, k+1 is interpolated); PNGs go to FRAMELIFT_OUT:
// <k>-a-real.png, <k>-b-plain.png (Apple ML only), <k>-c-guard.png (with the subtitle/HUD guard), <k>-d-real.png.
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing
@testable import Framelift

@Suite struct OfflineFrameGenHarness {
    @Test func renderPairs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let clip = env["FRAMELIFT_CLIP"], let out = env["FRAMELIFT_OUT"] else { return }
        let frames = (env["FRAMELIFT_FRAMES"] ?? "0").split(separator: ",").compactMap { Int($0) }
        let (w, h) = (1920, 1080)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        let interp = AppleLLFIInterpolator(keepWarm: false)
        interp.prepare(width: w, height: h)
        let probe = try #require(Self.decode(clip: clip, from: frames[0], count: 1, w: w, h: h).first)
        for _ in 0..<200 where !interp.isReady(for: probe) { Thread.sleep(forTimeInterval: 0.05) }
        try #require(interp.isReady(for: probe))
        let blender = try FrameBlender(context: RenderContext.shared())

        for k in frames {
            let pair = try Self.decode(clip: clip, from: k, count: 2, w: w, h: h)
            try #require(pair.count == 2)
            let plainBox = Box(), guardBox = Box()
            let sem = DispatchSemaphore(value: 0)
            interp.interpolate(previous: pair[0], current: pair[1]) { r in plainBox.value = r.frames.first; sem.signal() }
            sem.wait()
            let plain = try #require(plainBox.value)
            blender.keepStatic(previous: pair[0], current: pair[1], generated: plain) { o in guardBox.value = o; sem.signal() }
            sem.wait()
            let guarded = try #require(guardBox.value)
            let name = String(format: "%05d", k)
            try Self.png(pair[0], "\(out)/\(name)-a-real.png")
            try Self.png(plain, "\(out)/\(name)-b-plain.png")
            try Self.png(guarded, "\(out)/\(name)-c-guard.png")
            try Self.png(pair[1], "\(out)/\(name)-d-real.png")
        }
    }

    final class Box: @unchecked Sendable { var value: CVPixelBuffer? }

    enum HarnessError: Error { case ffmpeg }

    /// Decodes `count` frames starting at index `from` with ffmpeg into IOSurface-backed 420v buffers.
    static func decode(clip: String, from: Int, count: Int, w: Int, h: Int) throws -> [CVPixelBuffer] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-i", clip, "-vf", "select=gte(n\\,\(from))", "-fps_mode", "passthrough",
                       "-frames:v", "\(count)", "-pix_fmt", "nv12", "-f", "rawvideo", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let frameBytes = w * h * 3 / 2
        guard p.terminationStatus == 0, data.count >= frameBytes else { throw HarnessError.ffmpeg }
        return (0..<(data.count / frameBytes)).compactMap { i in
            makeBuffer(data.subdata(in: i * frameBytes..<(i + 1) * frameBytes), w: w, h: h)
        }
    }

    static func makeBuffer(_ nv12: Data, w: Int, h: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        nv12.withUnsafeBytes { src in
            let base = src.baseAddress!
            for plane in 0..<2 {
                let dst = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rows = plane == 0 ? h : h / 2
                let offset = plane == 0 ? 0 : w * h
                for r in 0..<rows { memcpy(dst + r * stride, base + offset + r * w, w) }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    static func png(_ buffer: CVPixelBuffer, _ path: String) throws {
        let ctx = CIContext()
        try ctx.writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: URL(fileURLWithPath: path),
                                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// Renders one recorded frame through the app's own Metal present shader into BGRA (dev only).
/// FRAMELIFT_CLIP + FRAMELIFT_COLOUR_FRAME + FRAMELIFT_OUT -> <out>/present-<k>.bgra (1920x1080x4).
@Suite struct OfflineColourHarness {
    @Test func renderThroughPresentShader() throws {
        let env = ProcessInfo.processInfo.environment
        guard let clip = env["FRAMELIFT_CLIP"], let out = env["FRAMELIFT_OUT"], let k = env["FRAMELIFT_COLOUR_FRAME"].flatMap(Int.init) else { return }
        let frame = try #require(OfflineFrameGenHarness.decode(clip: clip, from: k, count: 1, w: 1920, h: 1080).first)
        let ctx = try RenderContext.shared()
        let encoder = try PresentEncoder(context: ctx)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(ctx.device.makeTexture(descriptor: d))
        let cb = try #require(ctx.queue.makeCommandBuffer())
        let done = try #require(encoder.encode(frame, into: target, commandBuffer: cb, hud: nil))
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(done.keep) {}
        var bytes = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
        target.getBytes(&bytes, bytesPerRow: 1920 * 4, from: MTLRegionMake2D(0, 0, 1920, 1080), mipmapLevel: 0)
        try Data(bytes).write(to: URL(fileURLWithPath: "\(out)/present-\(k).bgra"))
    }
}
