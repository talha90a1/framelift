// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CoreVideo
import Metal
import Testing
@testable import Framelift

@Suite(.serialized)
struct HDRInterpolationTests {
    @Test func resizedFlowKeepsMotionInDestinationGridUnits() throws {
        func flow(width: Int, height: Int) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_TwoComponent16Half,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
            return try #require(buffer)
        }
        let source = try flow(width: 160, height: 90), destination = try flow(width: 240, height: 135)
        CVPixelBufferLockBaseAddress(source, [])
        let base = CVPixelBufferGetBaseAddress(source)!
        for y in 0..<90 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(source)).assumingMemoryBound(to: Float16.self)
            for x in 0..<160 { row[x * 2] = 8; row[x * 2 + 1] = -4 }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let context = try RenderContext.shared(), converter = try HDRColorConverter(context: context)
        let command = try #require(context.queue.makeCommandBuffer())
        try #require(converter.rescaleFlow(source, into: destination, command: command))
        command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed)
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(destination)!.assumingMemoryBound(to: Float16.self)
        #expect(row[0] == 12 && row[1] == -6)
    }

    private struct Buffer: @unchecked Sendable { let value: CVPixelBuffer? }

    private func buffer(_ work: (@escaping (CVPixelBuffer?) -> Void) -> Void) async -> CVPixelBuffer? {
        let result: Buffer = await withCheckedContinuation { continuation in
            work { continuation.resume(returning: Buffer(value: $0)) }
        }
        return result.value
    }

    static func tag(_ buffer: CVPixelBuffer, hlg: Bool = false) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey,
            hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    }

    static func code(_ buffer: CVPixelBuffer, x: Int, y: Int, plane: Int = 0) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
        return Int(
            base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
                .assumingMemoryBound(to: UInt16.self)[x] >> 6)
    }

    private func movingFrame(at left: Int, hlg: Bool, width: Int = 640) throws -> CVPixelBuffer {
        let frame = try HDRPresentTests.frame(width: width, height: width * 9 / 16, y: 300, c: 512)
        let scale = width / 640, left = left * (width / 640)
        Self.tag(frame, hlg: hlg)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for y in (140 * scale)..<(204 * scale) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in left..<(left + 64 * scale) { row[x] = UInt16(((x - left) / (8 * scale) + (y - 140 * scale) / (8 * scale)) % 2 == 0 ? 800 : 600) << 6 }
        }
        return frame
    }

    @Test(.enabled(if: HDRFrameInterpolator.isSupported), arguments: [false, true], [640, 1280, 1920])
    func movingHDRDetailIsInterpolatedRatherThanBlended(hlg: Bool, width: Int) async throws {
        let interpolator = try HDRFrameInterpolator(context: RenderContext.shared())
        let a = try movingFrame(at: 200, hlg: hlg, width: width), b = try movingFrame(at: 216, hlg: hlg, width: width)
        interpolator.prepare(width: width, height: width * 9 / 16)
        for _ in 0..<1000 {
            if interpolator.isReady(for: a) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(interpolator.isReady(for: a))
        let result = await withCheckedContinuation { c in
            interpolator.interpolate(previous: a, current: b) { c.resume(returning: $0) }
        }
        let mid = try #require(result.frames.first, "\(result.error ?? "no output")")
        let expected = try movingFrame(at: 208, hlg: hlg, width: width)
        var generatedError = 0.0, blendError = 0.0
        let scale = width / 640
        for y in stride(from: 136 * scale, to: 208 * scale, by: 3 * scale) {
            for x in stride(from: 196 * scale, to: 284 * scale, by: 3 * scale) {
                let truth = Double(Self.code(expected, x: x, y: y))
                generatedError += abs(Double(Self.code(mid, x: x, y: y)) - truth)
                blendError += abs(Double(Self.code(a, x: x, y: y) + Self.code(b, x: x, y: y)) / 2 - truth)
            }
        }
        #expect(generatedError < blendError * 0.8, "Motion error \(generatedError), blend \(blendError)")
    }

    @Test(.enabled(if: HDRFrameInterpolator.isSupported))
    func primesFromRealFramesAndCanPrimeAgainAfterReset() async throws {
        let interpolator = try HDRFrameInterpolator(context: RenderContext.shared())
        let frame = try HDRPresentTests.frame(width: 1280, height: 720, y: 600, c: 560)
        Self.tag(frame)
        interpolator.prepare(width: 1280, height: 720)
        for _ in 0..<1000 {
            if interpolator.isReady(for: frame) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(interpolator.isReady(for: frame))
        for _ in 0..<2 {
            #expect(!interpolator.isPrimed)
            interpolator.prime(previous: frame, current: frame)
            for _ in 0..<500 {
                if interpolator.isPrimed { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(interpolator.isPrimed)
            let result = await withCheckedContinuation { c in
                interpolator.interpolate(previous: frame, current: frame) { c.resume(returning: $0) }
            }
            let mid = try #require(result.frames.first)
            #expect(abs(Self.code(mid, x: 640, y: 360) - 600) <= 2)
            #expect(abs(Self.code(mid, x: 640, y: 180, plane: 1) - 560) <= 2)
            #expect(ColourTags.read(mid) == ColourTags.read(frame))
            interpolator.reset()
        }
    }

    @Test(.enabled(if: HDRFrameInterpolator.isSupported))
    func busyRequestHasABoundedWaitAndResetDiscardsOldOutput() async throws {
        let interpolator = try HDRFrameInterpolator(context: RenderContext.shared())
        let frame = try movingFrame(at: 200, hlg: false)
        interpolator.prepare(width: 640, height: 360)
        for _ in 0..<1000 {
            if interpolator.isReady(for: frame) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(interpolator.isReady(for: frame))
        let old: InterpolationResult = await withCheckedContinuation { c in
            interpolator.interpolate(previous: frame, current: frame) { c.resume(returning: $0) }
            interpolator.reset()
        }
        #expect(old.frames.isEmpty && old.error == "reset")
        let (outputs, completed) = AsyncStream<InterpolationResult>.makeStream()
        for _ in 0..<2 {
            interpolator.interpolate(previous: frame, current: frame) { completed.yield($0) }
        }
        var iterator = outputs.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        completed.finish()
        #expect(first.frames.count == 1 || second.frames.count == 1)
        #expect([first, second].allSatisfy { $0.frames.count == 1 || $0.error == "busy" })
        #expect(interpolator.isPrimed)

        let (cancelled, cancellation) = AsyncStream<InterpolationResult>.makeStream()
        for _ in 0..<2 {
            interpolator.interpolate(previous: frame, current: frame) { cancellation.yield($0) }
        }
        interpolator.reset()
        #expect(!interpolator.isPrimed)
        var cancellations = cancelled.makeAsyncIterator()
        for _ in 0..<2 {
            let result = try #require(await cancellations.next())
            #expect(result.frames.isEmpty && result.error == "reset")
        }
        cancellation.finish()

    }

    @Test(arguments: [false, true], [false, true])
    func tenBitRoundTripRetainsHighlightsAndChroma(hlg: Bool, fullRange: Bool) async throws {
        let converter = try HDRColorConverter(context: RenderContext.shared())
        for (luma, chroma) in [(65, 512), (301, 512), (723, 512), (939, 512), (600, 560)] {
            let source = try HDRPresentTests.frame(
                width: 64, height: 36, y: UInt16(luma), c: UInt16(chroma),
                format: fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            Self.tag(source, hlg: hlg)
            let motion = try #require(await buffer { converter.motion(source, completion: $0) })
            let restored = try #require(
                await buffer { converter.encoded(motion, matching: source, completion: $0) })
            #expect(ColourTags.read(restored) == ColourTags.read(source))
            #expect(PixelFormats.is10Bit420(restored))
            #expect(abs(Self.code(restored, x: 32, y: 18) - luma) <= 1)
            #expect(abs(Self.code(restored, x: 32, y: 9, plane: 1) - chroma) <= 1)
        }
    }

    @Test(.enabled(if: HDRFrameInterpolator.isSupported), arguments: [1280, 1920])
    func generatedHDRSurvivesGuardsPresentationAndRecording(width: Int) async throws {
        let height = width * 9 / 16
        let ctx = try RenderContext.shared()
        let interpolator = try HDRFrameInterpolator(context: ctx)
        let a = try HDRPresentTests.frame(width: width, height: height, y: 723, c: 512)
        Self.tag(a)
        interpolator.prepare(width: width, height: height)
        for _ in 0..<1000 {
            if interpolator.isReady(for: a) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(interpolator.isReady(for: a))
        var previous = a
        var mid: CVPixelBuffer?
        var timings: [Double] = []
        for index in 0..<12 {
            let current = try HDRPresentTests.frame(width: width, height: height, y: 723, c: 512)
            Self.tag(current)
            let result = await withCheckedContinuation { c in
                interpolator.interpolate(previous: previous, current: current) { c.resume(returning: $0) }
            }
            mid = try #require(result.frames.first, "\(result.error ?? "no generated frame")")
            #expect(ColourTags.read(mid!) == ColourTags.read(a))
            #expect(abs(Self.code(mid!, x: 640, y: 360) - 723) <= 3)
            if index >= 3 { timings.append(result.wallMs) }
            previous = current
        }
        print("HDR \(width)x\(height) sequential interpolation ms: \(timings)")
        let generated = try #require(mid)
        let blender = try FrameBlender(context: ctx)
        let guarded = try #require(
            await buffer {
                blender.keepSubtitles(previous: a, current: previous, generated: generated, regions: [SIMD4(0, 0, 1, 1)], completion: $0)
            })
        #expect(PixelFormats.is10Bit420(guarded))
        #expect(ColourTags.read(guarded) == ColourTags.read(a))
        #expect(abs(Self.code(guarded, x: 640, y: 360) - 723) <= 1)

        let encoder = try PresentEncoder(context: ctx)
        encoder.colour = ColourMapping.decide(ColourTags.read(guarded), mode: .automatic)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: 1280, height: 720, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(ctx.device.makeTexture(descriptor: descriptor))
        let cb = try #require(ctx.queue.makeCommandBuffer())
        let presentation = try #require(encoder.encode(guarded, into: target, commandBuffer: cb, hud: nil))
        await withCheckedContinuation { c in
            cb.addCompletedHandler { _ in c.resume() }
            cb.commit()
        }
        withExtendedLifetime(presentation.keep) {}
        #expect(cb.status == .completed)
        var pixel: UInt32 = 0
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(640, 360, 1, 1), mipmapLevel: 0)
        #expect(abs(Int(pixel & 1023) - Int((723.0 - 64) / 876 * 1023)) <= 3)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("hdr.mp4")
        let recorder = SessionRecorder(url: url)
        for index in 0..<20 {
            recorder.appendVideo(guarded, tags: ColourTags.read(guarded), at: 100 + Double(index) / 60)
            try await Task.sleep(for: .milliseconds(17))
        }
        let result = await withCheckedContinuation { c in recorder.finish { c.resume(returning: $0) } }
        _ = try result.get()
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        reader.add(output)
        try #require(reader.startReading())
        let decoded = try #require(output.copyNextSampleBuffer().flatMap { CMSampleBufferGetImageBuffer($0) })
        #expect(PixelFormats.is10Bit420(decoded))
        #expect(ColourTags.read(decoded).hdrCurve == .pq)
        #expect(abs(Self.code(decoded, x: 640, y: 360) - 723) <= 5)
        interpolator.reset()
        let afterReset = await withCheckedContinuation { c in
            interpolator.interpolate(previous: previous, current: previous) { c.resume(returning: $0) }
        }
        #expect(afterReset.frames.count == 1)
    }
}
