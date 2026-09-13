import Darwin
import Foundation

public enum KeychainError: LocalizedError, Equatable {
    case itemNotFound
    case unreadableData
    case timedOut
    case lockFailed
    case recoveryPending
    case activationFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: "Antigravity Keychain item not found (service: gemini, account: antigravity)."
        case .unreadableData: "Could not read data from Keychain."
        case .timedOut: "Keychain operation timed out."
        case .lockFailed: "Could not acquire the switch lock."
        case .recoveryPending: "An interrupted account switch needs recovery. Reopen Agy Switchboard and choose Recover before launching AGY."
        case .activationFailed(let detail): "Failed to activate profile: \(detail)"
        case .verificationFailed(let profile): "Live Keychain credential or configured profile does not match profile '\(profile)'."
        }
    }
}

public struct BridgeExecutionResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public final class KeychainClient: Sendable {
    public static let shared = KeychainClient()

    public typealias BridgeRunner = @Sendable (String, [String], TimeInterval) throws -> BridgeExecutionResult
    public typealias LiveCredentialReader = @Sendable (TimeInterval) throws -> Data
    public typealias BridgeLocator = @Sendable () -> String?

    private let homeDirectory: URL
    private let supportDirectory: URL
    private let lockURL: URL
    private let pendingSwitchURL: URL
    private let aiswConfigURL: URL
    private let bridgeRunner: BridgeRunner
    private let liveCredentialReader: LiveCredentialReader
    private let bridgeLocator: BridgeLocator

    /// `supportDirectory` is an explicit test override. The production default
    /// deliberately matches Agy Switchboard's shared lock and recovery journal.
    public init(
        supportDirectory: URL? = nil,
        homeDirectory: URL? = nil,
        bridgeRunner: BridgeRunner? = nil,
        liveCredentialReader: LiveCredentialReader? = nil,
        bridgeLocator: BridgeLocator? = nil
    ) {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = supportDirectory ?? home
            .appendingPathComponent("Library/Application Support/AgySwitcher", isDirectory: true)
        self.homeDirectory = home
        self.supportDirectory = dir
        self.lockURL = dir.appendingPathComponent("switch.lock")
        self.pendingSwitchURL = dir.appendingPathComponent("recovery/pending-switch.json")
        self.aiswConfigURL = home.appendingPathComponent(".aisw/config.json")
        self.bridgeRunner = bridgeRunner ?? Self.runBridge
        self.liveCredentialReader = liveCredentialReader ?? Self.readSecurityCredential
        self.bridgeLocator = bridgeLocator ?? { ExecutableLocator.find("aisw") }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Read current live credential from macOS Keychain.
    public func readLiveCredential(timeout: TimeInterval = 10) throws -> Data {
        try liveCredentialReader(timeout)
    }

    private static func readSecurityCredential(timeout: TimeInterval) throws -> Data {
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
        let path = homeDirectory
            .appendingPathComponent(".aisw/profiles/antigravity", isDirectory: true)
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("keyring-secret.json")
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return nil }
        return AgyCredential.normalizeCapturedSecret(data)
    }

    /// Acquire exclusive file lock for switching profiles.
    public func acquireLock() throws -> Int32 {
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
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

    /// Activates only through Switchboard's credential-only bridge, then checks
    /// both the selected AISW profile and the live Keychain identity.
    public func activateProfile(
        _ profileName: String,
        aiswPath: String? = nil
    ) async throws {
        let lock = try acquireLock()
        defer { releaseLock(lock) }
        guard !FileManager.default.fileExists(atPath: pendingSwitchURL.path) else { throw KeychainError.recoveryPending }
        guard let storedTarget = readStoredCredential(profileName: profileName) else {
            throw KeychainError.activationFailed("Profile \(profileName) has no stored credential")
        }
        let liveMatches = (try? readLiveCredential()).map { AgyCredential.representsSameAccount(storedTarget, $0) } ?? false
        if liveMatches && configuredProfile() == profileName { return }

        guard let locatedBridge = bridgeLocator() else {
            throw KeychainError.activationFailed("Agy Switchboard's credential-only aisw-switchboard bridge is required")
        }
        let bridge = aiswPath ?? locatedBridge
        guard Self.isSwitcherBridge(bridge),
              aiswPath == nil || URL(fileURLWithPath: bridge).resolvingSymlinksInPath().path == URL(fileURLWithPath: locatedBridge).resolvingSymlinksInPath().path else {
            throw KeychainError.activationFailed("Agy Switchboard's credential-only aisw-switchboard bridge is required")
        }
        try verifyBridgeCapability(bridge)
        let result: BridgeExecutionResult
        do {
            result = try bridgeRunner(bridge, ["--non-interactive", "--quiet", "use", "antigravity", profileName, "--json"], 40)
        } catch {
            throw KeychainError.activationFailed(Self.sanitizeCredentialLeak(error.localizedDescription))
        }
        guard result.exitCode == 0 else {
            let detail = Self.sanitizeCredentialLeak(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            throw KeychainError.activationFailed(detail.isEmpty ? "Switchboard bridge exited with code \(result.exitCode)" : detail)
        }
        guard configuredProfile() == profileName,
              let liveVerified = try? readLiveCredential(),
              AgyCredential.representsSameAccount(storedTarget, liveVerified) else {
            throw KeychainError.verificationFailed(profileName)
        }
    }

    private func configuredProfile() -> String? {
        guard let data = try? Data(contentsOf: aiswConfigURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["active"] as? [String: Any] else { return nil }
        return active["antigravity"] as? String
    }

    private func verifyBridgeCapability(_ bridge: String) throws {
        let result: BridgeExecutionResult
        do { result = try bridgeRunner(bridge, ["--non-interactive", "--quiet", "version", "--json"], 10) }
        catch { throw KeychainError.activationFailed("Could not run Agy Switchboard bridge: \(Self.sanitizeCredentialLeak(error.localizedDescription))") }
        guard result.exitCode == 0,
              let data = result.standardOutput.data(using: .utf8),
              let version = try? JSONDecoder().decode(BridgeCapabilities.self, from: data),
              version.version == "0.3.8",
              version.cliAPI == 1,
              version.credentialOnly else {
            throw KeychainError.activationFailed("Agy Switchboard's credential-only aisw-switchboard bridge is required")
        }
    }

    private static func isSwitcherBridge(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "aisw-switchboard"
    }

    private struct BridgeCapabilities: Decodable {
        let version: String
        let cliAPI: Int
        let credentialOnly: Bool

        enum CodingKeys: String, CodingKey {
            case version
            case cliAPI = "cli_api_version"
            case credentialOnly = "antigravity_credential_only"
        }
    }

    /// Uses a separate process group so a timed-out bridge and any children are
    /// killed and reaped before the caller can release Switchboard's lock.
    static func runBridge(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> BridgeExecutionResult {
        let outputFD = try makeUnlinkedOutputFile()
        defer { Darwin.close(outputFD) }
        let errorFD = try makeUnlinkedOutputFile()
        defer { Darwin.close(errorFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorFD, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in
            environment.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, executable, &actions, &attributes,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress!),
                    UnsafeMutablePointer(mutating: envBuffer.baseAddress!))
            }
        }
        guard spawnResult == 0 else { throw KeychainError.activationFailed("Could not start Agy Switchboard bridge") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw KeychainError.activationFailed("Could not monitor Agy Switchboard bridge")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw KeychainError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let output = readOutputFile(outputFD)
        let error = readOutputFile(errorFD)
        // Darwin does not expose the W* function-like macros to Swift. A zero
        // wait status is the only success status; callers only need success vs.
        // failure because bridge stderr carries the useful diagnostic.
        let exitCode: Int32 = status == 0 ? 0 : 1
        return BridgeExecutionResult(exitCode: exitCode, standardOutput: output, standardError: error)
    }

    private static func makeUnlinkedOutputFile() throws -> Int32 {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agymux-bridge-\(UUID().uuidString)").path
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw KeychainError.activationFailed("Could not prepare Agy Switchboard bridge") }
        Darwin.unlink(path)
        return fd
    }

    private static func readOutputFile(_ descriptor: Int32) -> String {
        lseek(descriptor, 0, SEEK_SET)
        return String(decoding: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile(), as: UTF8.self)
    }
}
