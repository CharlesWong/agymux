import Darwin
import Foundation

public struct SessionRecord: Codable, Sendable {
    public let pid: Int32
    public let profileName: String
    public let conversationId: String?
    public let startedAt: Date
    public let cwd: String
    public let arguments: [String]

    public init(
        pid: Int32,
        profileName: String,
        conversationId: String?,
        startedAt: Date = .now,
        cwd: String,
        arguments: [String]
    ) {
        self.pid = pid
        self.profileName = profileName
        self.conversationId = conversationId
        self.startedAt = startedAt
        self.cwd = cwd
        self.arguments = arguments
    }
}

public final class ConcurrencyGuard: Sendable {
    public static let shared = ConcurrencyGuard()

    private let sessionsDirectory: URL

    public init(sessionsDirectory: URL? = nil) {
        let dir = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agymux/sessions", isDirectory: true)
        self.sessionsDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Prune dead PID records from the sessions directory.
    @discardableResult
    public func pruneStaleSessions() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var prunedCount = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent) else {
                try? FileManager.default.removeItem(at: file)
                prunedCount += 1
                continue
            }

            // Check process liveness
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: file)
                prunedCount += 1
                continue
            }

            // Check running executable path
            var buffer = [CChar](repeating: 0, count: 4096)
            let pathLen = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if pathLen <= 0 {
                try? FileManager.default.removeItem(at: file)
                prunedCount += 1
                continue
            }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            let binaryName = URL(fileURLWithPath: path).lastPathComponent.lowercased()

            let isAgyProcess = binaryName == "agy"
                || binaryName == "agyctl"
                || binaryName.contains("agymux")
                || binaryName.hasPrefix("agy.")
                || binaryName.contains("test")
                || binaryName.contains("runner")
            if !isAgyProcess {
                try? FileManager.default.removeItem(at: file)
                prunedCount += 1
            }
        }
        return prunedCount
    }

    /// Returns list of all currently active sessions.
    public func activeSessions() -> [SessionRecord] {
        pruneStaleSessions()

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files.compactMap { file -> SessionRecord? in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionRecord.self, from: data)
            else { return nil }
            return record
        }
    }

    /// Count of active CLI threads using a given profile.
    public func activeThreadCount(for profileName: String) -> Int {
        activeSessions().filter { $0.profileName == profileName }.count
    }

    /// Dictionary of [profileName: activeThreadCount].
    public func allActiveThreadCounts() -> [String: Int] {
        let sessions = activeSessions()
        var counts: [String: Int] = [:]
        for s in sessions {
            counts[s.profileName, default: 0] += 1
        }
        return counts
    }

    /// Register a new managed CLI session.
    public func registerSession(
        pid: Int32,
        profileName: String,
        conversationId: String?,
        cwd: String = FileManager.default.currentDirectoryPath,
        arguments: [String] = []
    ) throws {
        let record = SessionRecord(
            pid: pid,
            profileName: profileName,
            conversationId: conversationId,
            startedAt: .now,
            cwd: cwd,
            arguments: arguments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = sessionsDirectory.appendingPathComponent("\(pid).json")
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Unregister a finished session.
    public func unregisterSession(pid: Int32) {
        let url = sessionsDirectory.appendingPathComponent("\(pid).json")
        try? FileManager.default.removeItem(at: url)
    }
}
