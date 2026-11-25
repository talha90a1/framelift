// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Testing
@testable import Framelift

struct SubtitleGuardTests {
    @Test func characterClothingIsNotACornerMeter() throws {
        let width = 1920, height = 1080
        var pixels = [UInt8](repeating: 60, count: width * height)
        for y in 900..<916 { for x in 506..<640 { pixels[y * width + x] = 150 } }
        let frame = try buffer(pixels, width: width, height: height)
        #expect(HUDDetector.detect(previous: frame, current: frame).isEmpty)
    }

    @Test func subtitleProtectionDoesNotCopyAMovingObjectNextToStableText() throws {
        let width = 64, height = 32
        var a = [UInt8](repeating: 45, count: width * height), b = a
        var generated = [UInt8](repeating: 56, count: width * height)
        for y in 12..<20 {
            for x in 24..<28 { a[y * width + x] = 235; b[y * width + x] = 235 }
            for x in 30..<34 { a[y * width + x] = 20 }
            for x in 28..<32 { b[y * width + x] = 20 }
            for x in 29..<33 { generated[y * width + x] = 20 }
        }
        let output = try apply(buffer(a), buffer(b), buffer(generated), regions: [SIMD4(0, 0, 1, 1)])
        let pixels = luma(output)
        #expect(pixels[15 * width + 28] == generated[15 * width + 28])
        #expect(pixels[15 * width + 26] == 235)
    }

    @Test(arguments: [false, true], [1280, 1920])
    func stableCornerMeterIsRestoredWithoutHoldingItsMovingBackground(tenBit: Bool, width: Int) throws {
        let height = width * 9 / 16
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 85, count: width * height)
        let generated = [UInt8](repeating: 60, count: width * height)
        let left = width / 30, right = width / 9, top = height / 28, bottom = height / 20
        for y in top..<bottom { for x in left..<right {
            let value: UInt8 = y < top + 2 || y >= bottom - 2 || x < left + 2 || x >= right - 2 ? 30 : 145
            a[y * width + x] = value; b[y * width + x] = value
        } }
        for y in bottom..<(bottom + 4) { for x in left..<(left + (right - left) / 3) {
            b[y * width + x] = 30
        } }
        let previous = try buffer(a, width: width, height: height, tenBit: tenBit)
        let current = try buffer(b, width: width, height: height, tenBit: tenBit)
        let plain = try buffer(generated, width: width, height: height, tenBit: tenBit)
        let regions = HUDDetector.detect(previous: previous, current: current)
        try #require(!regions.isEmpty)
        let output = try apply(previous, current, plain, regions: [], hudRegions: regions)
        let pixels = luma(output)
        var changes = 0, wrongMeterPixels = 0
        for y in 0..<height { for x in 0..<width {
            if x >= left && x < right && y >= top && y < bottom {
                if pixels[y * width + x] != b[y * width + x] { wrongMeterPixels += 1 }
            } else if pixels[y * width + x] != generated[y * width + x] { changes += 1 }
        } }
        #expect(wrongMeterPixels == 0)
        #expect(changes == 0)
        #expect(CVPixelBufferGetPixelFormatType(output) == CVPixelBufferGetPixelFormatType(current))
        #expect(ColourTags.read(output) == ColourTags.read(current))
    }

    @Test func movingCornerRectangleIsNotAStableHUD() throws {
        let width = 1280, height = 720
        var a = [UInt8](repeating: 45, count: width * height)
        var b = a
        for y in 26..<40 {
            for x in 40..<142 { a[y * width + x] = 145 }
            for x in 80..<182 { b[y * width + x] = 145 }
        }
        #expect(HUDDetector.detect(previous: try buffer(a, width: width, height: height),
                                   current: try buffer(b, width: width, height: height)).isEmpty)
    }

    @Test func preservesStableGlyphsWithoutChangingPixelsOutsideTheLine() throws {
        let width = 64, height = 32
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 70, count: width * height)
        var generated = [UInt8](repeating: 56, count: width * height)
        for y in 12..<20 { for x in 24..<28 { a[y * width + x] = 235; b[y * width + x] = 235 } }
        for y in 13..<21 { for x in 28..<32 { generated[y * width + x] = 180 } }
        let previous = try buffer(a), current = try buffer(b), plain = try buffer(generated)
        let output = try apply(previous, current, plain, regions: [SIMD4(0.25, 0.25, 0.75, 0.75)])
        let pixels = luma(output)
        for y in 12..<20 { for x in 24..<28 { #expect(pixels[y * width + x] == 235) } }
        for y in 0..<height { for x in 0..<width where x < 16 || x >= 48 || y < 8 || y >= 24 {
            #expect(pixels[y * width + x] == generated[y * width + x])
        } }
    }

    @Test func movingWhiteDetailDoesNotBecomeAStaticOverlay() throws {
        let width = 64, height = 32
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 70, count: width * height)
        let generated = [UInt8](repeating: 56, count: width * height)
        for y in 12..<20 {
            for x in 12..<16 { a[y * width + x] = 235 }
            for x in 32..<36 { b[y * width + x] = 235 }
        }
        let previous = try buffer(a), current = try buffer(b), plain = try buffer(generated)
        let output = try apply(previous, current, plain, regions: [SIMD4(0, 0, 1, 1)])
        #expect(luma(output) == generated)
    }

    @Test(arguments: [false, true]) func reticleArmsArePreservedWithoutHoldingTheCentreBackground(tenBit: Bool) throws {
        let width = 1920, height = 1080
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 70, count: width * height)
        let generated = [UInt8](repeating: 56, count: width * height)
        drawReticle(in: &a, width: width)
        drawReticle(in: &b, width: width)
        let previous = try buffer(a, width: width, height: height, tenBit: tenBit)
        let current = try buffer(b, width: width, height: height, tenBit: tenBit)
        let plain = try buffer(generated, width: width, height: height, tenBit: tenBit)
        let regions = CrosshairDetector.regions(previous: previous, current: current)
        #expect(regions.count == 3)
        let output = try apply(previous, current, plain, regions: [])
        #expect(CVPixelBufferGetPixelFormatType(output) == CVPixelBufferGetPixelFormatType(current))
        #expect(ColourTags.read(output) == ColourTags.read(current))
        let pixels = luma(output)
        #expect(pixels[540 * width + 950] == 235)
        #expect(pixels[540 * width + 970] == 235)
        #expect(pixels[550 * width + 960] == 235)
        #expect(pixels[540 * width + 960] == generated[540 * width + 960])
        var outsideChanges = 0
        for y in 0..<height { for x in 0..<width {
            let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
            let inside = regions.contains { u >= Double($0.x) && u <= Double($0.z) && v >= Double($0.y) && v <= Double($0.w) }
            if !inside, pixels[y * width + x] != generated[y * width + x] { outsideChanges += 1 }
        } }
        #expect(outsideChanges == 0)
    }

    @Test func movingBrightCentreObjectDoesNotTriggerReticleProtection() throws {
        let width = 1920, height = 1080
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 70, count: width * height)
        for y in 530..<550 {
            for x in 950..<970 { a[y * width + x] = 235 }
            for x in 958..<978 { b[y * width + x] = 235 }
        }
        let previous = try buffer(a, width: width, height: height)
        let current = try buffer(b, width: width, height: height)
        #expect(CrosshairDetector.regions(previous: previous, current: current).isEmpty)
        a = [UInt8](repeating: 45, count: width * height)
        b = [UInt8](repeating: 70, count: width * height)
        drawReticle(in: &a, width: width)
        drawReticle(in: &b, width: width, shift: 8)
        #expect(CrosshairDetector.regions(previous: try buffer(a, width: width, height: height),
                                         current: try buffer(b, width: width, height: height)).isEmpty)
        a = [UInt8](repeating: 45, count: width * height)
        b = [UInt8](repeating: 70, count: width * height)
        drawReticle(in: &a, width: width)
        drawReticle(in: &b, width: width)
        for y in 539..<541 { for x in 945..<975 { a[y * width + x] = 235; b[y * width + x] = 235 } }
        for y in 540..<555 { for x in 959..<961 { a[y * width + x] = 235; b[y * width + x] = 235 } }
        #expect(CrosshairDetector.regions(previous: try buffer(a, width: width, height: height),
                                         current: try buffer(b, width: width, height: height)).isEmpty)
    }

    @Test func reticleDetectionScalesTo720pAndAbstainsWhenAnArmIsMissing() throws {
        let width = 1280, height = 720
        var a = [UInt8](repeating: 45, count: width * height)
        var b = [UInt8](repeating: 70, count: width * height)
        drawReticle(in: &a, width: width, height: height)
        drawReticle(in: &b, width: width, height: height)
        let previous = try buffer(a, width: width, height: height)
        #expect(CrosshairDetector.regions(previous: previous, current: try buffer(b, width: width, height: height)).count == 3)
        for y in 359..<361 { for x in 643..<650 { b[y * width + x] = 70 } }
        #expect(CrosshairDetector.regions(previous: previous, current: try buffer(b, width: width, height: height)).isEmpty)
    }

    private func drawReticle(in pixels: inout [UInt8], width: Int, height: Int = 1080, shift: Int = 0) {
        let scale = Double(height) / 1080, cx = width / 2 + shift, cy = height / 2
        let near = Int(5 * scale), far = Int(15 * scale), band = max(1, Int(scale.rounded()))
        for y in (cy - band)..<(cy + band) {
            for x in (cx - far)..<(cx - near) { pixels[y * width + x] = 235 }
            for x in (cx + near)..<(cx + far) { pixels[y * width + x] = 235 }
        }
        for y in (cy + near)..<(cy + far) { for x in (cx - band)..<(cx + band) { pixels[y * width + x] = 235 } }
    }

    private func apply(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ generated: CVPixelBuffer,
                       regions: [SIMD4<Float>], hudRegions: [SIMD4<Float>] = []) throws -> CVPixelBuffer {
        let blender = try FrameBlender(context: RenderContext.shared())
        let result = OfflineFrameGenHarness.Box()
        let finished = DispatchSemaphore(value: 0)
        blender.keepSubtitles(previous: a, current: b, generated: generated, regions: regions, hudRegions: hudRegions) { output in
            result.value = output
            finished.signal()
        }
        try #require(finished.wait(timeout: .now() + 5) == .success)
        return try #require(result.value)
    }

    private func buffer(_ y: [UInt8], width: Int = 64, height: Int = 32, tenBit: Bool = false) throws -> CVPixelBuffer {
        if tenBit {
            let frame = try PixelFormatTests.frame(width: width, height: height, y: 64, c: 512)
            CVPixelBufferLockBaseAddress(frame, [])
            defer { CVPixelBufferUnlockBaseAddress(frame, []) }
            let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            for row in 0..<height {
                let pixels = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { pixels[x] = UInt16(y[row * width + x]) << 8 }
            }
            return frame
        }
        let bytes = Data(y + [UInt8](repeating: 128, count: y.count / 2))
        return try #require(OfflineFrameGenHarness.makeBuffer(bytes, w: width, h: height))
    }

    private func luma(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        if PixelFormats.is10Bit420(buffer) {
            return (0..<height).flatMap { y in
                let row = UnsafeRawPointer(base + y * stride).assumingMemoryBound(to: UInt16.self)
                return (0..<width).map { UInt8(row[$0] >> 8) }
            }
        }
        return (0..<height).flatMap { y in Array(UnsafeBufferPointer(start: base + y * stride, count: width)) }
    }
}
