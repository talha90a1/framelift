// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import IOBluetooth
import ObjectiveC.runtime

struct PairedDualSense: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isConnected: Bool

    enum Action: Sendable {
        case disconnect, unpair
    }

    enum OperationError: Error {
        case unavailable, unsupported, failed
    }

    static func devices() -> [Self] {
        pairedDevices()
            .compactMap { device in
                guard let id = device.addressString, let name = device.name else { return nil }
                return Self(id: id, name: name, isConnected: device.isConnected())
            }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func recognizes(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("DualSense")
    }

    func perform(_ action: Action) async throws {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let device = Self.pairedDevices().first(where: { $0.addressString == id }) else {
                throw OperationError.unavailable
            }
            switch action {
            case .disconnect:
                if device.isConnected(), device.closeConnection() != kIOReturnSuccess, device.isConnected() {
                    throw OperationError.failed
                }
            case .unpair:
                try Self.unpair(device)
            }

            for _ in 0..<20 {
                try Task.checkCancellation()
                let finished = action == .unpair ? !device.isPaired() : !device.isConnected()
                if finished { return }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw OperationError.failed
        }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }

    private static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { device in
            device.name.map(recognizes) == true && device.isPaired()
        }
    }

    private static func unpair(_ device: IOBluetoothDevice) throws {
        // Private method with no result. Confirm removal using isPaired().
        let selector = NSSelectorFromString("remove")
        guard let method = class_getInstanceMethod(type(of: device), selector),
            device.responds(to: selector),
            method_getNumberOfArguments(method) == 2,
            let encoding = method_getTypeEncoding(method),
            String(cString: encoding).first == "v"
        else { throw OperationError.unsupported }

        let remove = unsafeBitCast(method_getImplementation(method), to: (@convention(c) (AnyObject, Selector) -> Void).self)
        remove(device, selector)
    }
}
