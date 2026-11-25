// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import Framelift

struct HUDTextTests {
    @Test func diagnosticLabelsHaveNoMissingGlyphs() {
        let labels = ["60 FPS  30 real + 30 gen  Apple ML", "Mac video 12 ms  ML 12 ms", "30 Mbps  lost 0",
                      "armed: press Options (pause menu) ~10×", "round trip 20 ms (median 18 of 3) + screen 12 ≈ 30 ms",
                      "Recording started", "Screenshot saved", "Saved 2026-11-25T14-14-08Z_BFE443.mp4"]
        let image = HUDText.rasterized(labels.map { HUDLine(text: $0) })
        for (row, text) in labels.enumerated() {
            for (column, character) in text.enumerated() where character != " " {
                #expect(HUDText.font[character] != nil, "Missing glyph: \(character)")
                let x = (column + HUDText.pad) * HUDText.cellW
                let y = (row + HUDText.pad) * HUDText.cellH - 1
                let hasInk = (0..<7).contains { gy in (0..<5).contains { gx in image.pixels[((y + gy) * image.width + x + gx) * 2] > 0 } }
                #expect(hasInk, "Blank character in \(text): \(character)")
            }
        }
    }

    @Test func unknownCharactersStayVisibleAndOnlyTheRequestedPrefixIsRed() {
        let image = HUDText.rasterized([HUDLine(text: "60 FPS 🕹", red: 0..<2)])
        var unknownHasInk = false, redHasInk = false
        for y in 0..<image.height { for x in 0..<image.width {
            let at = (y * image.width + x) * 2
            guard image.pixels[at] > 0 else { continue }
            let column = x / HUDText.cellW - HUDText.pad
            #expect(image.pixels[at + 1] == (column < 2 ? 255 : 0))
            if column < 2 { redHasInk = true }
            if column == 7 { unknownHasInk = true }
        } }
        #expect(redHasInk && unknownHasInk)
    }
}
