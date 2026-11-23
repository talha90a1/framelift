// SPDX-License-Identifier: AGPL-3.0-only
// Rumble / PS5 haptics -> CoreHaptics on the controller: one looping event per handle actuator.
// Not thread-safe: call from InputManager's queue only.
import CoreHaptics
import Foundation
import GameController

final class ControllerHaptics {
    private final class Channel {
        let engine: CHHapticEngine
        let sharpness: Float
        var player: CHHapticAdvancedPatternPlayer?
        var playing = false
        var current: Float = 0
        var broken = false

        init(engine: CHHapticEngine, sharpness: Float) {
            self.engine = engine
            self.sharpness = sharpness
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] _ in self?.markBroken() }
            engine.resetHandler = { [weak self] in self?.markBroken() }
        }

        // Called on CoreHaptics' queue; only flips a flag the input queue reads (benign race).
        private func markBroken() { broken = true }

        func set(_ intensity: Float) {
            let value = min(max(intensity, 0), 1)
            if abs(value - current) < 0.01, playing == (value > 0), !broken { return }
            current = value
            do {
                if broken {
                    try engine.start()
                    player = nil
                    playing = false
                    broken = false
                }
                if value <= 0 {
                    if playing { try player?.stop(atTime: CHHapticTimeImmediate) }
                    playing = false
                    return
                }
                if player == nil {
                    let event = CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                        ],
                        relativeTime: 0, duration: 10)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let p = try engine.makeAdvancedPlayer(with: pattern)
                    p.loopEnabled = true
                    p.loopEnd = 10
                    player = p
                }
                try player?.sendParameters(
                    [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)],
                    atTime: CHHapticTimeImmediate)
                if !playing {
                    try player?.start(atTime: CHHapticTimeImmediate)
                    playing = true
                }
            } catch {
                broken = true
            }
        }

        func shutdown() {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            engine.stop(completionHandler: nil)
        }
    }

    private var left: Channel?
    private var right: Channel?
    private var single: Channel?

    init?(controller: GCController) {
        guard let haptics = controller.haptics else { return nil }
        let localities = haptics.supportedLocalities
        func make(_ locality: GCHapticsLocality, sharpness: Float) -> Channel? {
            guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
            do { try engine.start() } catch { return nil }
            return Channel(engine: engine, sharpness: sharpness)
        }
        if localities.contains(.leftHandle), localities.contains(.rightHandle) {
            left = make(.leftHandle, sharpness: 0.15)
            right = make(.rightHandle, sharpness: 0.75)
        }
        if left == nil || right == nil {
            left = nil
            right = nil
            single = make(.default, sharpness: 0.4)
        }
        if left == nil, single == nil { return nil }
    }

    /// 0...1 per side.
    func set(left l: Float, right r: Float) {
        if let single {
            single.set(max(l, r))
        } else {
            left?.set(l)
            right?.set(r)
        }
    }

    func shutdown() {
        [left, right, single].forEach { $0?.shutdown() }
        left = nil
        right = nil
        single = nil
    }
}
