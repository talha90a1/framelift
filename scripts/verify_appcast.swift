// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fatalError("Usage: swift scripts/verify_appcast.swift <appcast> <zip> <download-url>")
}

let bundle = URL(fileURLWithPath: "dist/Framelift.app/Contents/Info.plist")
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle), format: nil) as? [String: Any]
let appcast = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[1]))
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .mappedIfSafe)
let items = try appcast.nodes(forXPath: "/rss/channel/item")
let elements = try appcast.nodes(forXPath: "/rss/channel/item/enclosure")

guard items.count == 1, elements.count == 1, let enclosure = elements.first as? XMLElement,
    enclosure.attribute(forName: "url")?.stringValue == arguments[3],
    enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
    let signatureValue = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
    let signature = Data(base64Encoded: signatureValue),
    let keyValue = plist?["SUPublicEDKey"] as? String, let key = Data(base64Encoded: keyValue),
    try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: archive)
else {
    FileHandle.standardError.write(Data("Invalid appcast URL, archive length, or EdDSA signature.\n".utf8))
    exit(1)
}

print("Verified appcast URL, archive length, and EdDSA signature.")
