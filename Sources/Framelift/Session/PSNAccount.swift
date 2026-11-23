// SPDX-License-Identifier: AGPL-3.0-only
// PSN account id parsing: the base64 form chiaki-ng shows, or the decimal account number.
import Foundation

enum PSNAccount {
    /// Returns the 8-byte account id, or nil. All-digit input is a decimal account number
    /// (stored little endian, as Veyra and chiaki-ng do); anything else must be base64 of 8 bytes.
    static func decode(base64OrDecimal text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard trimmed.count <= 20, let value = UInt64(trimmed) else { return nil }
            return withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var padded = trimmed
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded), data.count == 8 else { return nil }
        return data
    }
}
