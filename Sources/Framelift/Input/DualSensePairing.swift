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
        var isPaired: Bool { device.isPaired() }
    }

    enum State {
        case idle, searching, found([Candidate]), repairing, pairing, connecting
        case needsRepair(Candidate, String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairing: IOBluetoothDevicePair?
    private var connectingCandidate: Candidate?
    private var pairingCandidate: Candidate?
    private var repairTask: Task<Void, Never>?
    private var generation = 0
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
        let selected: Candidate?
        switch state {
        case .found(let devices): selected = devices.first { $0.id == candidate.id }
        case .needsRepair(let device, _): selected = device.id == candidate.id ? device : nil
        default: selected = nil
        }
        guard let selected else { return }
        if selected.isPaired { connect(selected) }
        else { startPairing(selected) }
    }

    func pairAgain(_ candidate: Candidate) {
        guard case .needsRepair(let selected, _) = state, selected.id == candidate.id else { return }
        cancel()
        state = .repairing
        let attempt = generation
        repairTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if selected.isPaired {
                    let saved = PairedDualSense(id: selected.id, name: selected.name, isConnected: selected.device.isConnected())
                    try await saved.perform(.unpair)
                }
                try Task.checkCancellation()
                guard let self, attempt == generation else { return }
                repairTask = nil
                startPairing(selected)
            } catch is CancellationError {
                return
            } catch {
                guard let self, attempt == generation else { return }
                fail("Couldn’t remove this controller’s old pairing. Forget it in Bluetooth Settings, then try again.")
            }
        }
    }

    private func startPairing(_ candidate: Candidate) {
        guard let pairing = IOBluetoothDevicePair(device: candidate.device) else {
            state = .failed("Couldn’t pair with the controller.")
            return
        }
        self.pairing = pairing
        pairingCandidate = candidate
        pairing.delegate = self
        state = .pairing
        let result = pairing.start()
        guard result == kIOReturnSuccess else {
            log.error("DualSense pairing failed to start: \(result)")
            connectionFailed(candidate, message: "Couldn’t pair with the controller.")
            return
        }
        setTimeout(.seconds(20)) { [weak self] in
            self?.connectionFailed(candidate, message: "Pairing timed out. Put the controller back in pairing mode and try again.")
        }
    }

    func cancel(connected: Bool = false) {
        generation += 1
        repairTask?.cancel()
        repairTask = nil
        timeout?.cancel()
        timeout = nil
        connectingCandidate = nil
        pairingCandidate = nil
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

    private func connect(_ candidate: Candidate) {
        state = .connecting
        connectingCandidate = candidate
        if !candidate.device.isConnected() {
            let result = candidate.device.openConnection(self, withPageTimeout: BluetoothHCIPageTimeout(kDefaultPageTimeout.rawValue), authenticationRequired: true)
            if result != kIOReturnSuccess {
                log.error("DualSense connection failed to start: \(result)")
                connectionFailed(candidate, message: "Couldn’t connect to the controller.")
                return
            }
        }
        setTimeout(.seconds(8)) { [weak self] in
            self?.connectionFailed(candidate, message: "The controller hasn’t connected for input.")
        }
    }

    private func connectionFailed(_ candidate: Candidate, message: String) {
        let savedPairing = candidate.isPaired
        cancel()
        state = savedPairing ? .needsRepair(candidate, message) : .failed(message)
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        Task { @MainActor in
            guard let candidate = connectingCandidate, device === candidate.device, status != kIOReturnSuccess else { return }
            log.error("DualSense connection failed: \(status)")
            connectionFailed(candidate, message: "Couldn’t reconnect. The controller may still be connected to the PS5, or its saved Mac pairing may be outdated.")
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
            let candidate = pairingCandidate
            self.pairing = nil
            pairingCandidate = nil
            sender.delegate = nil
            if error == kIOReturnSuccess, let candidate {
                connect(candidate)
            } else {
                log.error("DualSense pairing failed: \(error)")
                if let candidate { connectionFailed(candidate, message: "Couldn’t pair with the controller.") }
                else { fail("Couldn’t pair with the controller.") }
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
