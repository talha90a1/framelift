// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
import IOBluetooth
import OSLog

@MainActor
final class DualSensePairing: NSObject, ObservableObject {
    struct Candidate: Identifiable {
        let id: String
        let name: String
        fileprivate let device: IOBluetoothDevice
    }

    enum State {
        case idle, searching, found([Candidate]), pairing, connecting, paired
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairing: IOBluetoothDevicePair?
    private var connectingDevice: IOBluetoothDevice?
    private var timeout: Task<Void, Never>?
    private let log = Logger(subsystem: "com.framelift.mac", category: "Bluetooth")

    func search() {
        cancel()
        guard let host = IOBluetoothHostController.default(), host.powerState == kBluetoothHCIPowerStateON else {
            state = .failed("Turn on Bluetooth and try again.")
            return
        }

        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            state = .failed("Couldn’t start the Bluetooth search.")
            return
        }
        self.inquiry = inquiry
        state = .searching
        inquiry.inquiryLength = 8
        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            log.error("Bluetooth inquiry failed to start: \(result)")
            fail("Couldn’t start the Bluetooth search.")
            return
        }
        setTimeout(.seconds(12)) { [weak self] in
            guard let self, let inquiry = self.inquiry else { return }
            self.finishSearch(inquiry)
        }
    }

    func pair(_ candidate: Candidate) {
        guard case let .found(devices) = state, devices.contains(where: { $0.id == candidate.id }) else { return }
        if candidate.device.isPaired() {
            connect(candidate.device)
            return
        }

        guard let pairing = IOBluetoothDevicePair(device: candidate.device) else {
            state = .failed("Couldn’t pair with the controller.")
            return
        }
        self.pairing = pairing
        pairing.delegate = self
        state = .pairing
        let result = pairing.start()
        guard result == kIOReturnSuccess else {
            log.error("DualSense pairing failed to start: \(result)")
            fail("Couldn’t pair with the controller.")
            return
        }
        setTimeout(.seconds(20)) { [weak self] in
            self?.fail("Pairing timed out. Put the controller back in pairing mode and try again.")
        }
    }

    func cancel(connected: Bool = false) {
        timeout?.cancel()
        timeout = nil
        connectingDevice = nil
        if let inquiry {
            self.inquiry = nil
            inquiry.delegate = nil
            inquiry.stop()
        }
        if let pairing {
            self.pairing = nil
            pairing.delegate = nil
            if !connected { pairing.stop() }
        }
        state = .idle
    }

    private func fail(_ message: String) {
        cancel()
        state = .failed(message)
    }

    private func finishSearch(_ sender: IOBluetoothDeviceInquiry) {
        let matches = (sender.foundDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> Candidate? in
            guard let name = device.name, PairedDualSense.recognizes(name),
                let address = device.addressString
            else { return nil }
            return Candidate(id: address, name: name, device: device)
        }
        cancel()
        state =
            matches.isEmpty
            ? .failed("No DualSense found. Hold Create and PS until the light flashes, then try again.")
            : .found(matches)
    }

    private func connect(_ device: IOBluetoothDevice) {
        state = .connecting
        if !device.isConnected() {
            connectingDevice = device
            let result = device.openConnection(self)
            if result != kIOReturnSuccess {
                log.error("DualSense connection failed to start: \(result)")
                showPaired()
                return
            }
        }
        setTimeout(.seconds(8)) { [weak self] in self?.showPaired() }
    }

    private func showPaired() {
        timeout?.cancel()
        timeout = nil
        connectingDevice = nil
        state = .paired
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        Task { @MainActor in
            guard device === connectingDevice, status != kIOReturnSuccess else { return }
            log.error("DualSense connection failed: \(status)")
            showPaired()
        }
    }

    private func setTimeout(_ delay: Duration, action: @escaping @MainActor () -> Void) {
        timeout?.cancel()
        timeout = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            action()
        }
    }
}

extension DualSensePairing: IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        Task { @MainActor in
            guard let sender, sender === inquiry else { return }
            if error == kIOReturnSuccess {
                finishSearch(sender)
            } else {
                log.error("Bluetooth inquiry failed: \(error)")
                fail("Couldn’t search for the controller.")
            }
        }
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        Task { @MainActor in
            guard let sender = sender as? IOBluetoothDevicePair, sender === pairing else { return }
            self.pairing = nil
            sender.delegate = nil
            if error == kIOReturnSuccess, let device = sender.device() {
                connect(device)
            } else {
                log.error("DualSense pairing failed: \(error)")
                fail("Couldn’t pair with the controller.")
            }
        }
    }

    nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        requireSystemPairing(sender)
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        requireSystemPairing(sender)
    }

    private nonisolated func requireSystemPairing(_ sender: Any?) {
        Task { @MainActor in
            guard let sender = sender as? IOBluetoothDevicePair, sender === pairing else { return }
            fail("macOS needs to finish pairing in Bluetooth Settings.")
        }
    }
}
