// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol PSNCredentialCryptor: Sendable {
    func seal(_ data: Data) throws -> Data
    func open(_ data: Data) throws -> Data
}

struct DeviceCredentialCryptor: PSNCredentialCryptor {
    private struct Envelope: Codable {
        var version = 1
        var protectedKey: Data
        var encapsulatedKey: Data
        var ciphertext: Data
    }

    private enum Failure: LocalizedError {
        case unavailable, format
        var errorDescription: String? {
            switch self {
            case .unavailable: "Secure Enclave is unavailable. Framelift couldn't save the PlayStation sign-in securely."
            case .format: "The saved PlayStation sign-in uses an unsupported encryption format. Update Framelift before trying again."
            }
        }
    }

    private let info = Data("com.framelift.mac.psn.v1".utf8)

    func seal(_ data: Data) throws -> Data {
        guard SecureEnclave.isAvailable,
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage, nil)
        else { throw Failure.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context())
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
        // This representation is encrypted by the Secure Enclave; it isn't the raw private key.
        let envelope = Envelope(
            protectedKey: key.dataRepresentation, encapsulatedKey: sender.encapsulatedKey,
            ciphertext: try sender.seal(data))
        return try JSONEncoder().encode(envelope)
    }

    func open(_ data: Data) throws -> Data {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw Failure.format }
        guard SecureEnclave.isAvailable else { throw Failure.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: envelope.protectedKey,
            authenticationContext: context())
        var recipient = try HPKE.Recipient(
            privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
            encapsulatedKey: envelope.encapsulatedKey)
        return try recipient.open(envelope.ciphertext)
    }

    private func context() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
