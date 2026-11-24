// SPDX-License-Identifier: AGPL-3.0-only
import RealityKit
import SwiftUI

struct DualSensePairingDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene: PairingScene?
    @State private var unavailable = false

    var body: some View {
        if !unavailable {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
                let time = reduceMotion ? Self.heldPose : Self.loopTime(timeline.date.timeIntervalSince(scene?.startedAt ?? timeline.date))
                let press = Self.press(at: time)
                RealityView { content in
                    content.camera = .virtual
                    await loadScene(into: content)
                } update: { _ in
                    scene?.show(press, lightOn: reduceMotion || Self.lightFlashes(at: time))
                }
                .realityViewCameraControls(.none)
                .overlay {
                    if scene != nil {
                        GeometryReader { geometry in
                            callout("Create", from: CGPoint(x: 0.15, y: 0.11), to: CGPoint(x: 0.308, y: 0.183), press: press.create, in: geometry.size)
                            callout("PS", from: CGPoint(x: 0.50, y: 0.87), to: CGPoint(x: 0.50, y: 0.488), press: press.ps, in: geometry.size)
                        }
                    }
                }
            }
            .frame(width: 244, height: 168)
            .background(Color(white: 0.09))
            .clipShape(.rect(cornerRadius: 10))
            .allowsHitTesting(false)
        }
    }

    @MainActor
    private func loadScene(into content: RealityViewCameraContent) async {
        do {
            guard let url = AppResources.url(forResource: "DualSensePairing", withExtension: "usdz") else {
                unavailable = true
                return
            }
            let model = try await Entity(contentsOf: url)
            guard !Task.isCancelled else { return }

            guard let create = model.findEntity(named: "CreateButton"),
                let ps = model.findEntity(named: "PSButton"),
                let lightBar = model.findEntity(named: "LightBarSurface") as? ModelEntity
            else {
                unavailable = true
                return
            }

            content.add(model)
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 29
            camera.look(at: [0, 0.01, 0], from: [0, 0.43, 8.65], relativeTo: nil)
            content.add(camera)

            let key = DirectionalLight()
            key.light.intensity = 2100
            key.look(at: .zero, from: [-2, 4, 5], relativeTo: nil)
            content.add(key)
            let fill = DirectionalLight()
            fill.light.intensity = 650
            fill.look(at: .zero, from: [3, -1, 4], relativeTo: nil)
            content.add(fill)

            let scene = PairingScene(create: create, ps: ps, lightBar: lightBar)
            scene.show(Self.press(at: reduceMotion ? Self.heldPose : 0), lightOn: reduceMotion)
            self.scene = scene
        } catch {
            if !Task.isCancelled { unavailable = true }
        }
    }

    private func callout(_ title: String, from label: CGPoint, to button: CGPoint, press: Float, in size: CGSize) -> some View {
        let center = CGPoint(x: label.x * size.width, y: label.y * size.height)
        let anchor = CGPoint(x: button.x * size.width, y: button.y * size.height)
        let end = CGPoint(x: center.x, y: center.y + (anchor.y > center.y ? 9 : -9))
        let ink = Color.white.opacity(0.94)

        return ZStack(alignment: .topLeading) {
            let leader = Path { path in
                path.move(to: end)
                path.addLine(to: anchor)
            }
            leader.stroke(.black.opacity(0.6), lineWidth: 2.5)
            leader.stroke(ink.opacity(0.8), lineWidth: 1)
            Circle()
                .strokeBorder(ink, lineWidth: 1.3)
                .background(.black.opacity(0.65), in: .circle)
                .overlay {
                    Circle()
                        .fill(ink)
                        .padding(3.5)
                        .opacity(Double(press))
                }
                .frame(width: 13, height: 13)
                .position(anchor)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.8), in: .capsule)
                .position(center)
        }
        .frame(width: size.width, height: size.height)
    }

    nonisolated static let heldPose: TimeInterval = 4.25

    nonisolated static func loopTime(_ elapsed: TimeInterval) -> TimeInterval {
        max(elapsed, 0).truncatingRemainder(dividingBy: 5.5)
    }

    nonisolated static func press(at time: TimeInterval) -> (create: Float, ps: Float) {
        func ease(_ range: Range<TimeInterval>) -> Float {
            let progress = Float(min(1, max(0, (time - range.lowerBound) / (range.upperBound - range.lowerBound))))
            return progress * progress * (3 - 2 * progress)
        }

        let release = 1 - ease(4.69..<5.02)
        return (ease(0.24..<0.66) * release, ease(0.74..<1.20) * release)
    }

    nonisolated static func lightFlashes(at time: TimeInterval) -> Bool {
        (4.20..<4.37).contains(time) || (4.49..<4.66).contains(time)
    }
}

@MainActor
private final class PairingScene {
    let startedAt = Date()
    private let create: Entity
    private let ps: Entity
    private let createRest: SIMD3<Float>
    private let psRest: SIMD3<Float>
    private let lightBar: ModelEntity
    private var isLit: Bool?

    init(create: Entity, ps: Entity, lightBar: ModelEntity) {
        self.create = create
        self.ps = ps
        createRest = create.position(relativeTo: nil)
        psRest = ps.position(relativeTo: nil)
        self.lightBar = lightBar
    }

    func show(_ press: (create: Float, ps: Float), lightOn: Bool) {
        create.setPosition(createRest - [0, 0, 0.08 * press.create], relativeTo: nil)
        ps.setPosition(psRest - [0, 0, 0.08 * press.ps], relativeTo: nil)

        guard isLit != lightOn else { return }
        isLit = lightOn
        lightBar.model?.materials = [UnlitMaterial(color: NSColor(white: lightOn ? 1 : 0.12, alpha: 1))]
    }
}
