// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension ext: String?, in host: Bundle = .main) -> URL? {
        if let resource = host.url(forResource: name, withExtension: ext) { return resource }
        guard host.bundleURL.pathExtension != "app" else { return nil }

        let locations = [
            host.executableURL?.deletingLastPathComponent(),
            host.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }
        for location in locations {
            let bundleURL = location.appendingPathComponent("Framelift_Framelift.bundle", isDirectory: true)
            if let resource = Bundle(url: bundleURL)?.url(forResource: name, withExtension: ext) {
                return resource
            }
        }
        return nil
    }
}
