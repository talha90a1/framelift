// SPDX-License-Identifier: AGPL-3.0-only
// Annex-B helpers for VideoDecoder.
// Only H.264 type 5 and HEVC IDR_W_RADL/IDR_N_LP (19/20) are clean random-access points; HEVC CRA (21) is not.
import CoreMedia
import CoreVideo
import Foundation

enum VideoAnnexB {
    /// A NAL unit inside a byte array: `range` covers the NAL header + payload (no start code, no trailing zeros).
    struct NAL {
        var range: Range<Int>
        var type: UInt8
    }

    // MARK: Splitting

    /// Splits an Annex-B byte stream on 3- or 4-byte start codes. Trailing zero bytes (the leading zero of a
    /// 4-byte start code or trailing_zero_8bits) are stripped from each NAL.
    static func split(_ b: [UInt8], hevc: Bool) -> [NAL] {
        var out: [NAL] = []
        let n = b.count
        var i = 0
        var start = -1
        func close(_ end: Int) {
            guard start >= 0 else { return }
            var e = end
            while e > start && b[e - 1] == 0 { e -= 1 }
            if e > start + (hevc ? 1 : 0) { out.append(NAL(range: start..<e, type: nalType(b[start], hevc: hevc))) }
        }
        while i + 2 < n {
            if b[i + 2] > 1 { i += 3; continue }          // fast skip: no start code can end here
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                close(i)
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        close(n)
        return out
    }

    // MARK: Classification

    static func nalType(_ header: UInt8, hevc: Bool) -> UInt8 {
        hevc ? (header >> 1) & 0x3F : header & 0x1F
    }

    static func isVCL(_ t: UInt8, hevc: Bool) -> Bool {
        hevc ? t <= 31 : (t >= 1 && t <= 5)
    }

    /// Clean random access only. HEVC CRA/BLA are deliberately excluded (RASL pictures reference lost frames).
    static func isIDR(_ t: UInt8, hevc: Bool) -> Bool {
        hevc ? (t == 19 || t == 20) : t == 5
    }

    /// H.264 SPS(7)/PPS(8); HEVC VPS(32)/SPS(33)/PPS(34).
    static func isParameterSet(_ t: UInt8, hevc: Bool) -> Bool {
        hevc ? (t >= 32 && t <= 34) : (t == 7 || t == 8)
    }

    /// Parameter-set NAL types in the order CMVideoFormatDescription expects them.
    static func parameterSetTypes(hevc: Bool) -> [UInt8] {
        hevc ? [32, 33, 34] : [7, 8]
    }

    /// NALs that never go into the length-prefixed sample: AUD, end of sequence/stream, filler.
    static func isDiscardable(_ t: UInt8, hevc: Bool) -> Bool {
        hevc ? (t >= 35 && t <= 38) : (t >= 9 && t <= 12)
    }

    // MARK: Format description

    /// Builds a CMVideoFormatDescription from raw parameter-set NALs (no start codes), 4-byte NAL length headers.
    static func makeFormatDescription(parameterSets: [[UInt8]], hevc: Bool) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let buffers = parameterSets.map { ps -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: ps.count)
            p.initialize(from: ps, count: ps.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = parameterSets.map { $0.count }
        var fmt: CMVideoFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    // MARK: SPS bit depth

    /// Luma bit depth from an SPS NAL (header included), or nil when it cannot be parsed.
    static func lumaBitDepth(sps: [UInt8], hevc: Bool) -> Int? {
        var r = RBSPReader(nal: sps, headerBytes: hevc ? 2 : 1)
        if hevc {
            guard let maxSubLayersMinus1 = r.bits(8).map({ ($0 >> 1) & 7 }) else { return nil } // vps id(4) max_sub_layers(3) nesting(1)
            // profile_tier_level(1, maxSubLayersMinus1): general part is 88 bits + level 8 bits.
            guard r.skip(96) else { return nil }
            var subProfile: [Bool] = [], subLevel: [Bool] = []
            for _ in 0..<maxSubLayersMinus1 {
                guard let p = r.bits(1), let l = r.bits(1) else { return nil }
                subProfile.append(p == 1); subLevel.append(l == 1)
            }
            if maxSubLayersMinus1 > 0 { guard r.skip(2 * (8 - Int(maxSubLayersMinus1))) else { return nil } }
            for i in 0..<Int(maxSubLayersMinus1) {
                if subProfile[i] { guard r.skip(88) else { return nil } }
                if subLevel[i] { guard r.skip(8) else { return nil } }
            }
            guard r.ue() != nil, let chroma = r.ue() else { return nil }      // sps id, chroma_format_idc
            if chroma == 3 { guard r.skip(1) else { return nil } }
            guard r.ue() != nil, r.ue() != nil, let window = r.bits(1) else { return nil } // width, height
            if window == 1 { for _ in 0..<4 { guard r.ue() != nil else { return nil } } }
            return r.ue().map { Int($0) + 8 }
        } else {
            guard let profile = r.bits(8), r.skip(16), r.ue() != nil else { return nil }
            let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
            guard highProfiles.contains(profile) else { return 8 }
            guard let chroma = r.ue() else { return nil }
            if chroma == 3 { guard r.skip(1) else { return nil } }
            return r.ue().map { Int($0) + 8 }
        }
    }

    /// Exp-Golomb bit reader over an RBSP (emulation-prevention bytes removed).
    private struct RBSPReader {
        private var data: [UInt8] = []
        private var pos = 0

        init(nal: [UInt8], headerBytes: Int) {
            var zeros = 0
            data.reserveCapacity(min(nal.count, 64))
            for (i, byte) in nal.enumerated() where i >= headerBytes {
                if zeros >= 2 && byte == 3 { zeros = 0; continue }
                zeros = byte == 0 ? zeros + 1 : 0
                data.append(byte)
                if data.count >= 128 { break }   // bit depth lives in the first few dozen bytes
            }
        }

        mutating func bits(_ n: Int) -> UInt32? {
            guard pos + n <= data.count * 8 else { return nil }
            var v: UInt32 = 0
            for _ in 0..<n {
                v = (v << 1) | UInt32((data[pos >> 3] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }

        mutating func skip(_ n: Int) -> Bool {
            guard pos + n <= data.count * 8 else { return false }
            pos += n
            return true
        }

        mutating func ue() -> UInt32? {
            var zeros = 0
            while true {
                guard let bit = bits(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (UInt32(1) << UInt32(zeros)) - 1 + rest
        }
    }
}
