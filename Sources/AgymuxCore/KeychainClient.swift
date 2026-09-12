import Darwin
import Foundation

public enum KeychainError: LocalizedError {
    case itemNotFound
    case unreadableData
    case timedOut
    case lockFailed
    case activationFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: "Antigravity Keychain item not found (service: gemini, account: antigravity)."
        case .unreadableData: "Could not read data from Keychain."
        case .timedOut: "Keychain operation timed out."
        case .lockFailed: "Could not acquire the switch lock."
        case .activationFailed(let detail): "Failed to activate profile: \(detail)"
        case .verificationFailed(let profile): "Live Keychain credential does not match profile '\(profile)'."
        }
    }
}

public final class KeychainClient: Sendable {
    public static let shared = KeychainClient()

    private let supportDirectory: URL
    private let lockURL: URL

    public init(supportDirectory: URL? = nil) {
        let dir = supportDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agymux", isDirectory: true)
        self.supportDirectory = dir
        self.lockURL = dir.appendingPathComponent("switch.lock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Read current live credential from macOS Keychain.
    public func readLiveCredential(timeout: TimeInterval = 10) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw KeychainError.timedOut
        }
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 44 { throw KeychainError.itemNotFound }
            throw KeychainError.unreadableData
        }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        return AgyCredential.normalizeCapturedSecret(raw)
    }

    /// Read stored credential blob for an aisw profile.
    public func readStoredCredential(profileName: String) -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aisw/profiles/antigravity", isDirectory: true)
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("keyring-secret.json")
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return nil }
        return AgyCredential.normalizeCapturedSecret(data)
    }

    /// Acquire exclusive file lock for switching profiles.
    public func acquireLock() throws -> Int32 {
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw KeychainError.lockFailed
        }
        return descriptor
    }

    public func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    /// Sanitizes any sensitive credential fragments or hex payloads from error messages.
    public static func sanitizeCredentialLeak(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{16,}", options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED_HEX]")
    }

    /// Update live Keychain item directly via /usr/bin/security and sync ~/.aisw/config.json
    public func directActivateProfile(_ profileName: String) throws {
        guard let stored = readStoredCredential(profileName: profileName) else {
            throw KeychainError.activationFailed("Profile \(profileName) has no stored credential")
        }

        let hex = stored.map { String(format: "%02x", $0) }.joined()

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-U",
            "-s", "gemini",
            "-a", "antigravity",
            "-X", hex
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.activationFailed("Failed to execute security: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = Self.sanitizeCredentialLeak(errMsg)
            throw KeychainError.activationFailed(sanitized.isEmpty ? "Direct Keychain update failed with code \(process.terminationStatus)" : sanitized)
        }

        // Sync ~/.aisw/config.json active profile
        syncAiswActiveProfile(profileName)
    }

    public func syncAiswActiveProfile(_ profileName: String) {
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aisw/config.json")
        guard let data = try? Data(contentsOf: configURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var active = (json["active"] as? [String: Any]) ?? [:]
        active["antigravity"] = profileName
        json["active"] = active
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: configURL)
        }
    }

    /// Activate a profile using aisw and verify Keychain state.
    public func activateProfile(
        _ profileName: String,
        aiswPath: String? = ExecutableLocator.find("aisw")
    ) async throws {
        let lock = try acquireLock()
        defer { releaseLock(lock) }

        // 1. Check if already active and matching
        if let stored = readStoredCredential(profileName: profileName),
           let live = try? readLiveCredential(),
           AgyCredential.representsSameAccount(stored, live) {
            return
        }

        var activated = false
        var lastError: String?

        // 2. Call aisw use antigravity <profileName> if available
        if let aisw = aiswPath {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: aisw)
            process.arguments = [
                "--non-interactive", "--quiet", "use", "antigravity", profileName, "--json"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    activated = true
                } else {
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    lastError = Self.sanitizeCredentialLeak(errMsg)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        // Fallback: If aisw was not found, failed, or was unpatched, activate directly via /usr/bin/security
        if !activated {
            do {
                try directActivateProfile(profileName)
                activated = true
            } catch {
                let detail = lastError ?? error.localizedDescription
                let sanitized = Self.sanitizeCredentialLeak(detail)
                throw KeychainError.activationFailed(sanitized.isEmpty ? "Exit code 1" : sanitized)
            }
        }

        // 3. Verify live credential matches target
        guard let storedTarget = readStoredCredential(profileName: profileName) else {
            throw KeychainError.verificationFailed(profileName)
        }
        guard let liveVerified = try? readLiveCredential(),
              AgyCredential.representsSameAccount(storedTarget, liveVerified) else {
            throw KeychainError.verificationFailed(profileName)
        }
    }
}
