// SPDX-License-Identifier: AGPL-3.0-only
// Shared Metal state for the render module: device, queue, runtime-compiled shader library
// (builds do not need the Metal toolchain) and helpers to wrap 420v IOSurface planes.
import CoreVideo
import Foundation
import Metal

enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompile(String)
    case missingFunction(String)

    var description: String {
        switch self {
        case .noDevice: return "no Metal device"
        case .shaderCompile(let m): return "shader compile failed: \(m)"
        case .missingFunction(let n): return "missing Metal function \(n)"
        }
    }
}

enum ShaderLibrary {
    /// Where the last library came from (the Shaders folder path, or "inline").
    nonisolated(unsafe) private(set) static var loadedFrom = "none"

    static func source() -> (String, String) {
        var dirs: [URL] = []
        #if SWIFT_PACKAGE
        if let d = Bundle.module.url(forResource: "Shaders", withExtension: nil) { dirs.append(d) }
        #endif
        if let d = Bundle.main.url(forResource: "Shaders", withExtension: nil) { dirs.append(d) }
        for dir in dirs {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "metal" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let sources = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            if !sources.isEmpty, sources.count == files.count {
                return (sources.joined(separator: "\n"), dir.path)
            }
        }
        return (InlineShaderSources.files.map(\.source).joined(separator: "\n"), "inline")
    }

    static func make(device: MTLDevice) throws -> MTLLibrary {
        let (text, origin) = source()
        let options = MTLCompileOptions()
        options.mathMode = .fast
        options.languageVersion = .version3_1
        do {
            let lib = try device.makeLibrary(source: text, options: options)
            loadedFrom = origin
            return lib
        } catch {
            throw RenderError.shaderCompile("\(origin): \(error)")
        }
    }
}

/// One per process: shader compilation costs ~100 ms, so it is shared by every engine.
final class RenderContext: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    nonisolated(unsafe) private static var sharedInstance: RenderContext?
    private static let sharedLock = NSLock()

    static func shared() throws -> RenderContext {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let s = sharedInstance { return s }
        let s = try RenderContext()
        sharedInstance = s
        return s
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        queue.label = "framelift.render"
        library = try ShaderLibrary.make(device: device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RenderError.noDevice }
        textureCache = cache
    }

    func compute(_ name: String) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let fn = library.makeFunction(name: name) else { throw RenderError.missingFunction(name) }
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[name] = p
        return p
    }

    /// Zero-copy read view of one plane (CVMetalTextureCache). Keep the CVMetalTexture alive
    /// until the GPU work using it has completed.
    func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format, w, h, plane, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

    /// Read views of both planes with formats for 8-bit (r8/rg8) or 10/16-bit (r16/rg16) 4:2:0.
    func yuvTextures(_ buffer: CVPixelBuffer) -> (y: MTLTexture, c: MTLTexture, keep: [CVMetalTexture])? {
        let deep = !PixelFormats.is8Bit420(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let (y, ky) = planeTexture(buffer, plane: 0, format: deep ? .r16Unorm : .r8Unorm),
              let (c, kc) = planeTexture(buffer, plane: 1, format: deep ? .rg16Unorm : .rg8Unorm) else { return nil }
        return (y, c, [ky, kc])
    }

    /// Writable view of one IOSurface plane (the texture retains the surface).
    func writablePlaneTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                         width: CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                         height: CVPixelBufferGetHeightOfPlane(buffer, plane),
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d, iosurface: surface, plane: plane)
    }
}

enum PixelFormats {
    static let videoRange420: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let fullRange420: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    static func is8Bit420(_ buffer: CVPixelBuffer) -> Bool {
        let f = CVPixelBufferGetPixelFormatType(buffer)
        return f == videoRange420 || f == fullRange420
    }

    static func makePool(width: Int, height: Int, minimum: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: videoRange420,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: minimum] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }
}

/// Fixed-size sample window with percentiles (not thread-safe; callers lock).
struct PercentileWindow {
    private var values: [Double] = []
    private var next = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func add(_ v: Double) {
        if values.count < capacity { values.append(v) } else { values[next] = v }
        next = (next + 1) % capacity
    }

    var count: Int { values.count }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
}

/// GPU-only execution times (gpuEndTime - gpuStartTime) of the present command buffers, for
/// the stats line. Wall time includes queueing; this does not, so a rise here
/// means the GPU itself got slower (clocks/thermal), a rise only in wall time means waiting.
final class GPUTiming: @unchecked Sendable {
    static let shared = GPUTiming()
    private let lock = NSLock()
    private var present = PercentileWindow(capacity: 120)

    func addPresent(_ cb: MTLCommandBuffer) {
        let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        guard ms > 0, ms < 1000 else { return }
        lock.lock(); present.add(ms); lock.unlock()
    }

    /// "gpu present=p50/p90 therm=nominal"
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let therm: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: therm = "nominal"
        case .fair: therm = "fair"
        case .serious: therm = "serious"
        case .critical: therm = "critical"
        @unknown default: therm = "unknown"
        }
        return String(format: "gpu present=%.2f/%.2f therm=%@", present.percentile(0.5), present.percentile(0.9), therm)
    }
}
