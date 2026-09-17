import Foundation

public enum PreferencesStoreError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case corrupted(String)
    case unsupportedVersion(Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "Could not read Mousü preferences: \(reason)"
        case .corrupted(let reason): "Mousü preferences are damaged and were left untouched: \(reason)"
        case .unsupportedVersion(let version): "Preferences version \(version) is unsupported and was left untouched."
        case .writeFailed(let reason): "Could not save Mousü preferences: \(reason)"
        }
    }
}

/// Call from a single serial owner. Writes replace the file atomically.
public struct PreferencesStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Preferences {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Preferences()
        } catch {
            throw PreferencesStoreError.unreadable(error.localizedDescription)
        }
        return try Self.decode(data)
    }

    public func save(_ preferences: Preferences) throws {
        guard preferences.version == Preferences.currentVersion else {
            throw PreferencesStoreError.unsupportedVersion(preferences.version)
        }
        // A caller that falls back to defaults after a failed load must not destroy the source.
        // Only a genuinely missing file is empty; inaccessible directories are not.
        _ = try load()
        var validated = preferences
        validated.normalize()
        try validated.validateModelProfiles()
        // Session identities cannot survive process restart, even if accidentally passed by UI.
        validated.removeSessionProfileState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(validated)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // A login helper needs to reopen settings throughout the user session.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PreferencesStoreError.writeFailed(error.localizedDescription)
        }
    }

    public static func decode(_ data: Data) throws -> Preferences {
        struct Version: Decodable { var version: Int }
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(Version.self, from: data).version
        } catch {
            throw PreferencesStoreError.corrupted(error.localizedDescription)
        }
        guard (1...Preferences.currentVersion).contains(version) else {
            throw PreferencesStoreError.unsupportedVersion(version)
        }
        do {
            var result = try decoder.decode(Preferences.self, from: data)
            result.normalize()
            try result.validateModelProfiles()
            result.removeSessionProfileState()
            return result
        } catch {
            throw PreferencesStoreError.corrupted(error.localizedDescription)
        }
    }
}
