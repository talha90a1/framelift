// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct AppResourcesTests {
    @Test func resolvesResourcesInsideAStandaloneApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Framelift.app")
        let resources = try makeBundle(app, id: "com.framelift.resources-test", type: "APPL")
        let shaders = resources.appendingPathComponent("Shaders")
        let demo = resources.appendingPathComponent("DualSensePairing.usdz")
        try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: false)
        try "bundled shader".write(to: shaders.appendingPathComponent("test.metal"), atomically: true, encoding: .utf8)
        try Data().write(to: demo)

        let host = try #require(Bundle(url: app))
        let (source, origin) = ShaderLibrary.source(in: host)
        #expect(source == "bundled shader")
        #expect(URL(fileURLWithPath: origin).resolvingSymlinksInPath() == shaders.resolvingSymlinksInPath())
        #expect(
            AppResources.url(forResource: "DualSensePairing", withExtension: "usdz", in: host)?.resolvingSymlinksInPath()
                == demo.resolvingSymlinksInPath())
    }

    @Test func fallsBackWhenAStandaloneAppHasNoResourceBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Framelift.app")
        _ = try makeBundle(app, id: "com.framelift.resources-test.empty", type: "APPL")

        let host = try #require(Bundle(url: app))
        #expect(ShaderLibrary.source(in: host).1 == "inline")
        #expect(AppResources.url(forResource: "DualSensePairing", withExtension: "usdz", in: host) == nil)
    }

    @Test func resolvesTheSwiftPMBundleBesideTheTestHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let testHost = root.appendingPathComponent("Fixture.xctest")
        _ = try makeBundle(testHost, id: "com.framelift.resources-test.host", type: "BNDL")
        let sibling = root.appendingPathComponent("Framelift_Framelift.bundle")
        let resources = try makeBundle(sibling, id: "com.framelift.resources-test.sibling", type: "BNDL")
        let demo = resources.appendingPathComponent("DualSensePairing.usdz")
        try Data().write(to: demo)

        let host = try #require(Bundle(url: testHost))
        #expect(
            AppResources.url(forResource: "DualSensePairing", withExtension: "usdz", in: host)?.resolvingSymlinksInPath()
                == demo.resolvingSymlinksInPath())
    }

    private func makeBundle(_ bundle: URL, id: String, type: String) throws -> URL {
        let contents = bundle.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundlePackageType": type]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return resources
    }
}
