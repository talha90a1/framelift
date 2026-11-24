// swift-tools-version: 6.0
// Framelift: native macOS port of Veyra's PS5 Remote Play + frame generation path.
// Build libchiaki first: scripts/build_chiaki.sh  (stages build/chiaki-dist)
import PackageDescription

// Absolute: the swiftbuild backend runs compilers from the parent directory, so relative -I/-L break.
let chiakiDist = Context.packageDirectory + "/build/chiaki-dist"

let package = Package(
    name: "Framelift",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Framelift", targets: ["Framelift"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(
            name: "VeyraCore",
            path: "Sources/VeyraCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("veyra/include"),
                .unsafeFlags(["-I\(chiakiDist)/include", "-I/opt/homebrew/opt/openssl@3/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(chiakiDist)/lib"]),
                .linkedLibrary("chiaki"),
                .linkedLibrary("curl"),
                .linkedLibrary("protobuf-nanopb"),
                .linkedLibrary("jerasure"),
                .linkedLibrary("gf_complete"),
                .linkedLibrary("opus"),
                .linkedLibrary("json-c"),
                .linkedLibrary("miniupnpc"),
                .linkedLibrary("event"),
                .linkedLibrary("event_pthreads"),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto"),
                .linkedLibrary("z"),
                .linkedFramework("CoreServices"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "Framelift",
            dependencies: ["VeyraCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Framelift",
            resources: [.copy("Render/Shaders"), .copy("App/DualSensePairing.usdz")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("MetalFX"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("GameController"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreHaptics"),
            ]
        ),
        .testTarget(
            name: "FrameliftTests",
            dependencies: ["Framelift"],
            path: "Tests/FrameliftTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
