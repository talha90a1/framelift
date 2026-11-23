// SPDX-License-Identifier: AGPL-3.0-only
// Tiny built-in 5x7 bitmap font rendered into an rg8 texture for the in-frame FPS HUD
// (r = coverage, g = red). Rebuilt only when the text changes (the engine updates it <= 4x/s).
import Metal

struct HUDLine {
    var text: String
    /// Character range drawn in red (e.g. the displayed-fps number).
    var red: Range<Int>? = nil
}

final class HUDText {
    static let cellW = 6, cellH = 9, pad = 1

    private let device: MTLDevice
    private var textures: [MTLTexture] = []
    private var current = 0
    private var lastLines: [String] = []
    private var lastRed: [Range<Int>?] = []
    private(set) var texture: MTLTexture?

    init(device: MTLDevice) { self.device = device }

    func update(_ lines: [HUDLine]) {
        guard lines.map(\.text) != lastLines || lines.map(\.red) != lastRed else { return }
        lastLines = lines.map(\.text); lastRed = lines.map(\.red)
        let cols = (lines.map(\.text.count).max() ?? 0) + 2 * Self.pad
        let w = max(1, cols * Self.cellW), h = max(1, (lines.count + 2 * Self.pad) * Self.cellH - 2)
        var pixels = [UInt8](repeating: 0, count: w * h * 2)
        for (row, line) in lines.enumerated() {
            for (col, ch) in line.text.enumerated() {
                guard let glyph = Self.font[ch] else { continue }
                let red: UInt8 = line.red?.contains(col) == true ? 255 : 0
                let x0 = (col + Self.pad) * Self.cellW, y0 = (row + Self.pad) * Self.cellH - 1
                for (gy, bits) in glyph.enumerated() {
                    for gx in 0..<5 where bits & (0x10 >> gx) != 0 {
                        let i = ((y0 + gy) * w + x0 + gx) * 2
                        pixels[i] = 255; pixels[i + 1] = red
                    }
                }
            }
        }
        // Double-buffered so the CPU never rewrites a texture a frame in flight may read.
        current ^= 1
        if textures.count < 2 || textures[current].width != w || textures[current].height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { return }
            if textures.count < 2 { textures = [t, t] }
            textures[current] = t
        }
        textures[current].replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 2)
        texture = textures[current]
    }

    // 5x7 glyphs, one byte per row, bit 4 = leftmost pixel.
    static let font: [Character: [UInt8]] = {
        let rows: [Character: [String]] = [
            "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
            "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
            "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
            "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
            "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
            "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
            "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
            "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
            "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
            "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
            ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
            "/": ["00000", "00001", "00010", "00100", "01000", "10000", "00000"],
            "(": ["00010", "00100", "01000", "01000", "01000", "00100", "00010"],
            ")": ["01000", "00100", "00010", "00010", "00010", "00100", "01000"],
            "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
            "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
            ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
            "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
            "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
            "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
            "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
            "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
            "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
            "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
            "a": ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
            "b": ["10000", "10000", "10110", "11001", "10001", "10001", "11110"],
            "d": ["00001", "00001", "01101", "10011", "10001", "10001", "01111"],
            "e": ["00000", "00000", "01110", "10001", "11111", "10000", "01110"],
            "f": ["00110", "01001", "01000", "11100", "01000", "01000", "01000"],
            "g": ["00000", "01111", "10001", "10001", "01111", "00001", "01110"],
            "i": ["00100", "00000", "01100", "00100", "00100", "00100", "01110"],
            "k": ["10000", "10000", "10010", "10100", "11000", "10100", "10010"],
            "l": ["01100", "00100", "00100", "00100", "00100", "00100", "01110"],
            "m": ["00000", "00000", "11010", "10101", "10101", "10001", "10001"],
            "n": ["00000", "00000", "10110", "11001", "10001", "10001", "10001"],
            "o": ["00000", "00000", "01110", "10001", "10001", "10001", "01110"],
            "p": ["00000", "00000", "11110", "10001", "11110", "10000", "10000"],
            "r": ["00000", "00000", "10110", "11001", "10000", "10000", "10000"],
            "s": ["00000", "00000", "01110", "10000", "01110", "00001", "11110"],
            "t": ["01000", "01000", "11100", "01000", "01000", "01001", "00110"],
            "u": ["00000", "00000", "10001", "10001", "10001", "10011", "01101"],
            "w": ["00000", "00000", "10001", "10001", "10101", "10101", "01010"],
            "z": ["00000", "00000", "11111", "00010", "00100", "01000", "11111"],
        ]
        return rows.mapValues { $0.map { UInt8($0, radix: 2)! } }
    }()
}
