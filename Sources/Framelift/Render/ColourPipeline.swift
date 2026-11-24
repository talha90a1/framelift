// SPDX-License-Identifier: AGPL-3.0-only
// Picks the YCbCr->RGB matrix, range expansion and CAMetalLayer colourspace from the stream's
// colour tags. The shader outputs gamma-encoded code values; the layer colourspace decodes them.
// HDR code values go to a 10-bit EDR layer tagged with the corresponding BT.2100 transfer function.
// SDR 709 uses sRGB (~2.2), not CGColorSpace.itur_709, whose inverse camera OETF lifts shadows.
// Missing or unknown tags: BT.709 matrix, video range, sRGB (what the PS5 sends in SDR).
import CoreGraphics
import CoreVideo
import Foundation

/// App-level "Colour" choice (StreamSettings is frozen). Stored by the app under `defaultsKey`.
enum ColourMode: String, CaseIterable, Identifiable, Sendable {
    /// From the stream's tags (default).
    case automatic
    /// BT.709 primaries, pure gamma 2.4 (BT.1886 reference EOTF): darker shadows.
    case bt1886
    /// BT.709 primaries, sRGB ~2.2 decode (what Automatic picks for PS5 SDR).
    case sRGB
    /// CGColorSpace.itur_709: inverse camera OETF, lifted shadows.
    case legacy709

    var id: String { rawValue }
    static let defaultsKey = "framelift.colour.v1"

    static func stored(_ defaults: UserDefaults = .standard) -> ColourMode {
        defaults.string(forKey: defaultsKey).flatMap(ColourMode.init(rawValue:)) ?? .automatic
    }
}

/// The decoded stream's colour description. Strings are the CVImageBuffer attachment values
/// (kCVImageBufferYCbCrMatrix_*, ...); nil = attachment absent.
struct ColourTags: Equatable, Sendable {
    var matrix: String?
    var primaries: String?
    var transfer: String?
    var fullRange: Bool

    static let untagged = ColourTags(matrix: nil, primaries: nil, transfer: nil, fullRange: false)

    var hdrCurve: LayerCurve? {
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        return nil
    }

    static func read(_ buffer: CVPixelBuffer) -> ColourTags {
        func tag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return ColourTags(
            matrix: tag(kCVImageBufferYCbCrMatrixKey),
            primaries: tag(kCVImageBufferColorPrimariesKey),
            transfer: tag(kCVImageBufferTransferFunctionKey),
            fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    var summary: String {
        "matrix=\(matrix ?? "none") primaries=\(primaries ?? "none") transfer=\(transfer ?? "none") range=\(fullRange ? "full" : "video")"
    }
}

enum YCbCrMatrix: String, Sendable {
    case bt601 = "BT.601", bt709 = "BT.709", bt2020 = "BT.2020"

    /// Luma weights (Kr, Kb).
    var weights: (kr: Double, kb: Double) {
        switch self {
        case .bt601: (0.299, 0.114)
        case .bt709: (0.2126, 0.0722)
        case .bt2020: (0.2627, 0.0593)
        }
    }
}

enum ColourPrimaries: String, Sendable {
    case bt709 = "709", p3 = "P3", bt2020 = "2020"
}

/// How the layer decodes the shader's code values to light.
enum LayerCurve: String, Sendable {
    /// sRGB piecewise (~2.2).
    case sRGB
    /// Pure power 2.4 (BT.1886 with zero black level).
    case gamma24 = "gamma 2.4"
    /// Inverse BT.709 camera OETF (CGColorSpace.itur_709 / itur_2020).
    case camera709 = "709 camera"
    /// HDR10 (SMPTE ST 2084).
    case pq = "PQ"
    case hlg = "HLG"
}

struct LayerColourSpace: Equatable, Sendable {
    var primaries: ColourPrimaries
    var curve: LayerCurve

    static let sRGB = LayerColourSpace(primaries: .bt709, curve: .sRGB)

    var isHDR: Bool { curve == .pq || curve == .hlg }

    var summary: String { "\(primaries.rawValue) primaries, \(curve.rawValue)" }

    func makeColorSpace() -> CGColorSpace? {
        switch (primaries, curve) {
        case (.bt709, .sRGB): return CGColorSpace(name: CGColorSpace.sRGB)
        case (.bt709, .camera709): return CGColorSpace(name: CGColorSpace.itur_709)
        case (.p3, .sRGB), (.p3, .camera709): return CGColorSpace(name: CGColorSpace.displayP3)
        case (.bt2020, .sRGB): return CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)
        case (.bt2020, .camera709): return CGColorSpace(name: CGColorSpace.itur_2020)
        case (_, .gamma24): return Self.calibrated(primaries, gamma: 2.4)
        case (_, .pq): return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case (_, .hlg): return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }
    }

    /// Calibrated RGB: D65 white, zero black, pure power `gamma`, RGB->XYZ of `primaries`
    /// (columns: X, Y, Z of red, green, blue).
    private static func calibrated(_ primaries: ColourPrimaries, gamma: CGFloat) -> CGColorSpace? {
        let white: [CGFloat] = [0.95047, 1.0, 1.08883]
        let black: [CGFloat] = [0, 0, 0]
        let g: [CGFloat] = [gamma, gamma, gamma]
        let m: [CGFloat]
        switch primaries {
        case .bt709: m = [0.4124, 0.2126, 0.0193, 0.3576, 0.7152, 0.1192, 0.1805, 0.0722, 0.9505]
        case .p3: m = [0.4866, 0.2290, 0.0000, 0.2657, 0.6917, 0.0451, 0.1982, 0.0793, 1.0439]
        case .bt2020: m = [0.6370, 0.2627, 0.0000, 0.1446, 0.6780, 0.0281, 0.1689, 0.0593, 1.0610]
        }
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: black, gamma: g, matrix: m)
    }
}

/// Shader constants of the YCbCr->RGB step (matches PresentColour in Present.metal: 5 x float4).
/// rgb = (r|g|b).xyz . (Y', Cb', Cr') with Y' = sampleY * range.x + range.y, C' = sampleC * range.z + range.w
/// (samples are the unorm texture values); params.x = sharpening strength (sharp pass only).
struct PresentColourConstants: Equatable {
    var r: SIMD4<Float>
    var g: SIMD4<Float>
    var b: SIMD4<Float>
    var range: SIMD4<Float>
    var params: SIMD4<Float> = .zero
}

/// Matrix, range and layer colourspace for one stream format + user mode.
struct ColourMapping: Equatable, Sendable {
    var matrix: YCbCrMatrix
    var fullRange: Bool
    var layer: LayerColourSpace
    /// Matrix tag absent or unrecognised (BT.709 assumed).
    var matrixAssumed = false

    static let standard = ColourMapping(matrix: .bt709, fullRange: false, layer: .sRGB)

    private static let matrices: [String: YCbCrMatrix] = [
        kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String: .bt601,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String: .bt709,
        kCVImageBufferYCbCrMatrix_ITU_R_2020 as String: .bt2020,
        // SMPTE 240M weights (0.212/0.087) are within rounding of 709.
        kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String: .bt709,
    ]
    private static let wideGamut: [String: ColourPrimaries] = [
        kCVImageBufferColorPrimaries_ITU_R_2020 as String: .bt2020,
        kCVImageBufferColorPrimaries_P3_D65 as String: .p3,
        kCVImageBufferColorPrimaries_DCI_P3 as String: .p3,
    ]
    static func decide(_ tags: ColourTags, mode: ColourMode) -> ColourMapping {
        var m = ColourMapping.standard
        m.fullRange = tags.fullRange
        if let matrix = tags.matrix.flatMap({ Self.matrices[$0] }) {
            m.matrix = matrix
        } else {
            m.matrixAssumed = true
        }
        if let hdr = tags.hdrCurve {
            m.layer = LayerColourSpace(primaries: .bt2020, curve: hdr)
            return m
        }

        // 601 primaries (EBU 3213 / SMPTE C) are close enough to 709 that the sRGB tag is the safer pick.
        let primaries = tags.primaries.flatMap { Self.wideGamut[$0] } ?? .bt709
        // The stream's primaries are always kept; the mode only picks the SDR curve.
        let curve: LayerCurve =
            switch mode {
            // Automatic: always an SDR display-referred decode (sRGB curve).
            case .automatic, .sRGB: .sRGB
            case .bt1886: .gamma24
            case .legacy709: .camera709
            }
        m.layer = LayerColourSpace(primaries: primaries, curve: curve)
        return m
    }

    /// Constants for a frame with `tenBit` samples (10 bits in the MSBs of a 16-bit unorm) or 8-bit.
    func constants(tenBit: Bool) -> PresentColourConstants {
        let (kr, kb) = matrix.weights
        let kg = 1 - kr - kb
        let r = SIMD4<Float>(1, 0, Float(2 * (1 - kr)), 0)
        let g = SIMD4<Float>(1, Float(-2 * kb * (1 - kb) / kg), Float(-2 * kr * (1 - kr) / kg), 0)
        let b = SIMD4<Float>(1, Float(2 * (1 - kb)), 0, 0)
        // unorm sample -> integer code value at the stream's bit depth.
        let bits = tenBit ? 10.0 : 8.0
        let toCode = tenBit ? 65535.0 / 64.0 : 255.0
        let step = pow(2, bits - 8)
        let (yOff, yDen, cDen): (Double, Double, Double) =
            fullRange
            ? (0, pow(2, bits) - 1, pow(2, bits) - 1)  // H.273 full range
            : (16 * step, 219 * step, 224 * step)  // video range: Y 16-235, C 16-240 (8-bit)
        let cOff = 128 * step
        let range = SIMD4<Float>(Float(toCode / yDen), Float(-yOff / yDen), Float(toCode / cDen), Float(-cOff / cDen))
        return PresentColourConstants(r: r, g: g, b: b, range: range)
    }

    var summary: String {
        "\(matrix.rawValue)\(matrixAssumed ? " (assumed)" : ""), \(fullRange ? "full" : "video") range, layer \(layer.summary)"
    }
}
