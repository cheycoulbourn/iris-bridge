import Foundation
import Darwin

/// A public certificate pin shared with the sandboxed Mac app. No admin token, device token, or private
/// key crosses this boundary. Directory-relative, no-follow operations prevent symlink redirection.
public enum LocalBridgeIdentity {
    public struct Descriptor: Codable, Equatable { public var version: Int = 1; public var fingerprint: String }
    public static var groupContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.agentcy.iris.prototype")
    }
    public static let directoryName = "IrisBridge"
    public static let fileName = "local-identity.json"
    private static var unavailable: Error { BridgeError.message("Could not prepare a secure local Iris connection.") }

    public static func write(fingerprint: String, groupContainer: URL = groupContainer) throws {
        try write(fingerprint: fingerprint, groupContainer: groupContainer, expectedOwner: geteuid())
    }
    static func write(fingerprint: String, groupContainer: URL, expectedOwner: uid_t) throws {
        let pin = fingerprint.lowercased()
        guard pin.utf8.count == 64, pin.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw unavailable }
        let group = open(groupContainer.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard group >= 0 else { throw unavailable }
        defer { close(group) }
        var groupInfo = stat()
        guard fstat(group, &groupInfo) == 0, groupInfo.st_uid == expectedOwner,
              groupInfo.st_mode & 0o022 == 0 else { throw unavailable }
        guard mkdirat(group, directoryName, 0o700) == 0 || errno == EEXIST else { throw unavailable }
        let directory = openat(group, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw unavailable }
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == expectedOwner,
              directoryInfo.st_mode & 0o022 == 0, fchmod(directory, 0o700) == 0 else { throw unavailable }
        var fileInfo = stat()
        let existing = fstatat(directory, fileName, &fileInfo, AT_SYMLINK_NOFOLLOW)
        guard (existing == -1 && errno == ENOENT) ||
              (existing == 0 && fileInfo.st_uid == expectedOwner && fileInfo.st_mode & S_IFMT == S_IFREG) else { throw unavailable }
        let temporary = ".local-identity-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw unavailable }
        defer { close(file); unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(Descriptor(fingerprint: pin))
        try data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { throw unavailable }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, address.advanced(by: offset), buffer.count - offset)
                if written == -1 && errno == EINTR { continue }
                guard written > 0 else { throw unavailable }
                offset += written
            }
        }
        guard fsync(file) == 0, renameat(directory, temporary, directory, fileName) == 0 else { throw unavailable }
    }
}
