// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

final class PSNCredentialStore: @unchecked Sendable {
    static let standard = PSNCredentialStore(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Framelift/Credentials", isDirectory: true))

    enum Failure: LocalizedError {
        case read, write, permissions

        var errorDescription: String? {
            switch self {
            case .read: "Couldn't read the saved PlayStation sign-in. Try again or sign in again."
            case .write: "Couldn't save the PlayStation sign-in on this Mac. Check available storage and try again."
            case .permissions: "Couldn't protect the saved PlayStation sign-in. Check the Framelift Application Support folder's permissions."
            }
        }
    }

    let directory: URL
    private let lock = NSLock()
    private let cryptor: any PSNCredentialCryptor
    private let name = "psn.enc"

    init(directory: URL, cryptor: any PSNCredentialCryptor = DeviceCredentialCryptor()) {
        self.directory = directory
        self.cryptor = cryptor
    }

    func load() throws -> PSNAuthorization? {
        try lock.withLock {
            let dir = try openDirectory()
            defer { close(dir) }
            guard let encrypted = try read(in: dir) else { return nil }
            do {
                return try JSONDecoder().decode(PSNAuthorization.self, from: cryptor.open(encrypted))
            } catch { throw Failure.read }
        }
    }

    func save(_ authorization: PSNAuthorization) throws {
        let data = try cryptor.seal(JSONEncoder().encode(authorization))
        try lock.withLock {
            let dir = try openDirectory()
            defer { close(dir) }
            try write(data, in: dir)
        }
    }

    func clear() throws {
        try lock.withLock {
            let dir = try openDirectory()
            defer { close(dir) }
            guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else { throw Failure.write }
            guard fsync(dir) == 0 else { throw Failure.write }
        }
    }

    private func openDirectory() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { throw Failure.permissions }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.permissions }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else {
            close(fd)
            throw Failure.permissions
        }
        return fd
    }

    private func read(in dir: Int32) throws -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.read
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0
        else { throw Failure.permissions }
        guard info.st_size > 0, info.st_size <= 65536 else { throw Failure.read }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.read }
                offset += count
            }
        }
        return data
    }

    private func write(_ data: Data, in dir: Int32) throws {
        guard data.count <= 65536 else { throw Failure.write }
        let temporary = ".psn-\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.write }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw Failure.permissions }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.write }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, temporary, dir, name) == 0, fsync(dir) == 0 else { throw Failure.write }
    }
}
