// SPDX-License-Identifier: AGPL-3.0-only
// Shared contracts between modules: RemotePlaySession -> VideoDecoder -> FrameSink, audio, controller I/O.
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Time

enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// mach_absolute_time ticks (same clock as CVDisplayLink / CADisplayLink host times).
    static func now() -> UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? seconds(end - start) * 1000 : -seconds(start - end) * 1000
    }
}

// MARK: - Stream settings

enum VideoCodecKind: Int, Codable, CaseIterable, Sendable {
    case h264 = 0, hevc = 1, hevcHDR = 2

    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .hevcHDR: "HEVC HDR"
        }
    }
}

struct StreamSettings: Codable, Equatable, Sendable {
    var width: UInt32 = 1920
    var height: UInt32 = 1080
    /// Stream preset requested from the PS5. 30 for 30 fps games (no duplicate frames), interpolated to 60.
    var streamFPS: UInt32 = 30
    var bitrateKbps: UInt32 = 30000
    // HEVC: sharper at the same bitrate.
    var codec: VideoCodecKind = .hevc
    /// CGDirectDisplayID of the screen to play on (TV over HDMI or built-in). nil = screen of the main window.
    var targetDisplayID: UInt32?
    var fullscreen: Bool = true
    /// Fall back to frame repeat when the source is late, a scene cut is detected or a keyframe recovery happens.
    var sceneCutFallback: Bool = true
    /// Performance overlay (Cmd+Shift+O).
    var showOverlay: Bool = false
    /// Spare Apple ML request between frames on a second session, so the model stays fast. Read at stream start.
    var keepLLFIWarm: Bool = true
    /// Copy pixels that don't move between the real frames (subtitles, HUD) into the generated frame.
    var keepStaticOverlays: Bool = true
    /// 50/50 blend shown when Apple's frame misses its deadline; off repeats the real frame instead.
    var blendFallback: Bool = true

    enum CodingKeys: String, CodingKey {
        case width, height, streamFPS, bitrateKbps, codec, targetDisplayID, fullscreen, sceneCutFallback
        case showOverlay, keepLLFIWarm, keepStaticOverlays, blendFallback
    }
}

extension StreamSettings {
    /// Missing keys keep their defaults, so stored settings (and paired consoles' lastSettings) decode after fields are added.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(UInt32.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(UInt32.self, forKey: .height) ?? height
        streamFPS = try c.decodeIfPresent(UInt32.self, forKey: .streamFPS) ?? streamFPS
        bitrateKbps = try c.decodeIfPresent(UInt32.self, forKey: .bitrateKbps) ?? bitrateKbps
        codec = try c.decodeIfPresent(VideoCodecKind.self, forKey: .codec) ?? codec
        targetDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .targetDisplayID)
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? fullscreen
        sceneCutFallback = try c.decodeIfPresent(Bool.self, forKey: .sceneCutFallback) ?? sceneCutFallback
        showOverlay = try c.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? showOverlay
        keepLLFIWarm = try c.decodeIfPresent(Bool.self, forKey: .keepLLFIWarm) ?? keepLLFIWarm
        keepStaticOverlays = try c.decodeIfPresent(Bool.self, forKey: .keepStaticOverlays) ?? keepStaticOverlays
        blendFallback = try c.decodeIfPresent(Bool.self, forKey: .blendFallback) ?? blendFallback
    }
}

// MARK: - Video

struct EncodedVideoUnit: Sendable {
    /// Annex-B bytes (start codes included). Either a complete access unit or codec config (SPS/PPS[/VPS]).
    var data: Data
    var codec: VideoCodecKind
    /// Frames the transport reported lost before this unit (> 0 => discontinuity).
    var framesLost: Int32
    var recovered: Bool
    /// HostClock ticks at network arrival.
    var arrivalHostTime: UInt64
}

struct PCMChunk: Sendable {
    var samples: [Int16]
    var channels: UInt32
    var sampleRate: UInt32
}

struct DecodedFrame: @unchecked Sendable {
    /// IOSurface-backed, Metal-compatible '420v' (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) or 'x420' for 10-bit.
    var pixelBuffer: CVPixelBuffer
    var sequence: UInt64
    /// HostClock ticks when the encoded unit arrived from the network.
    var arrivalHostTime: UInt64
    /// HostClock ticks when decode finished.
    var decodedHostTime: UInt64
    /// True after loss, IDR recovery or decoder reset: never interpolate across it.
    var discontinuity: Bool
}

protocol FrameSink: AnyObject {
    /// Called from the decoder's output queue. Must return quickly.
    func submit(_ frame: DecodedFrame)
    /// Drop history (session restart, resolution change).
    func reset()
}

// MARK: - Input

struct ControllerSnapshot: Equatable, Sendable {
    struct Buttons: OptionSet, Sendable {
        let rawValue: UInt32
        static let cross = Buttons(rawValue: 1 << 0), circle = Buttons(rawValue: 1 << 1)
        static let square = Buttons(rawValue: 1 << 2), triangle = Buttons(rawValue: 1 << 3)
        static let left = Buttons(rawValue: 1 << 4), right = Buttons(rawValue: 1 << 5)
        static let up = Buttons(rawValue: 1 << 6), down = Buttons(rawValue: 1 << 7)
        static let l1 = Buttons(rawValue: 1 << 8), r1 = Buttons(rawValue: 1 << 9)
        static let l3 = Buttons(rawValue: 1 << 10), r3 = Buttons(rawValue: 1 << 11)
        static let options = Buttons(rawValue: 1 << 12), share = Buttons(rawValue: 1 << 13)
        static let touchpad = Buttons(rawValue: 1 << 14), ps = Buttons(rawValue: 1 << 15)
    }
    struct Touch: Equatable, Sendable {
        var id: Int8 = -1
        var x: UInt16 = 0 // 0...1919
        var y: UInt16 = 0 // 0...1079
    }
    var buttons: Buttons = []
    /// -32768...32767, +y = down (chiaki convention).
    var leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0
    var l2: UInt8 = 0, r2: UInt8 = 0
    var touches: [Touch] = [Touch(), Touch()]
    var motionValid = false
    /// rad/s and g, SDL axis convention.
    var gyro: SIMD3<Float> = .zero
    var accel: SIMD3<Float> = SIMD3(0, 1, 0)
    var motionTimestampUs: UInt64 = 0
}

protocol ControllerSink: AnyObject {
    func send(_ state: ControllerSnapshot)
}

enum ControllerFeedbackEvent: Sendable {
    case rumble(left: UInt8, right: UInt8)
    case triggers(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8])
    /// Stereo S16 @ 3 kHz.
    case haptics([Int16])
    case motionReset
}

// MARK: - Telemetry

/// Lock-protected counters for the HUD and the debug log.
final class Telemetry: @unchecked Sendable {
    struct Snapshot: Sendable {
        var sourceFPS: Double = 0
        var displayedFPS: Double = 0
        var generatedFPS: Double = 0
        var displayHz: Double = 0
        var decodeMsP50: Double = 0
        var interpolateMsP50: Double = 0
        var interpolateMsP99: Double = 0
        var arrivalToPresentMsP50: Double = 0
        var droppedFrames: UInt64 = 0
        var repeatedFrames: UInt64 = 0
        var fallbackFrames: UInt64 = 0
        var packetsLost: UInt64 = 0
        var bitrateKbps: Double = 0
        var interpolationBackend: String = "off"
    }

    static let shared = Telemetry()
    private let lock = NSLock()
    private var value = Snapshot()

    func update(_ body: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
