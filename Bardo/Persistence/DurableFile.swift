#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Crash-safe, owner-only file publication shared by Bardo's stores.
///
/// Data is written to a same-directory temporary file, flushed to stable storage and
/// then renamed over the destination, so readers only ever see the previous or the
/// complete new contents. Recordings and transcripts are private: directories are
/// created as 0700 and files as 0600.
enum DurableFile {
    static let privateDirectoryPermissions: Int16 = 0o700
    static let privateFilePermissions: Int16 = 0o600

    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case write(path: String, description: String)
        case rename(path: String, description: String)

        var errorDescription: String? {
            switch self {
            case .write(let path, let description):
                return String(localized: "Could not write \(path): \(description)")
            case .rename(let path, let description):
                return String(localized: "Could not publish \(path): \(description)")
            }
        }
    }

    static func write(_ data: Data, to destinationURL: URL, temporaryPrefix: String) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent("\(temporaryPrefix)-\(UUID().uuidString).tmp")

        do {
            try writeSynchronously(data, to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Failure.write(path: destinationURL.lastPathComponent, description: error.localizedDescription)
        }

        do {
            try rename(from: temporaryURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        synchronizeDirectory(directoryURL)
    }

    /// Atomically replaces `destinationURL` with `sourceURL` on the same volume.
    static func rename(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw Failure.rename(
                path: destinationURL.lastPathComponent,
                description: String(cString: strerror(errno))
            )
        }
    }

    static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        restrictToOwner(url, permissions: privateDirectoryPermissions)
    }

    /// Best effort: tightens permissions of files Bardo did not create itself.
    static func restrictToOwner(_ url: URL, permissions: Int16 = privateFilePermissions) {
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func writeSynchronously(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(privateFilePermissions))
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }

        // fsync pushes the bytes to the drive; F_FULLFSYNC would also flush the drive
        // cache but costs tens of milliseconds per small manifest on every edit.
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
