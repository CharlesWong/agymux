import Foundation

public struct StickinessRecord: Codable, Sendable {
    public let conversationId: String
    public var profileName: String
    public var model: String
    public var lastUsedAt: Date

    public init(
        conversationId: String,
        profileName: String,
        model: String,
        lastUsedAt: Date = .now
    ) {
        self.conversationId = conversationId
        self.profileName = profileName
        self.model = model
        self.lastUsedAt = lastUsedAt
    }
}

public struct StickinessConfiguration: Codable, Sendable {
    public var version: Int
    public var minStickinessQuota: Double // Default 0.25 (25%)
    public var records: [String: StickinessRecord]

    public init(
        version: Int = 1,
        minStickinessQuota: Double = 0.25,
        records: [String: StickinessRecord] = [:]
    ) {
        self.version = version
        self.minStickinessQuota = minStickinessQuota
        self.records = records
    }
}

public final class ConversationStickinessStore: Sendable {
    public static let shared = ConversationStickinessStore()

    private let storeURL: URL

    public init(storeURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agymux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.storeURL = storeURL ?? dir.appendingPathComponent("stickiness.json")
    }

    public func loadConfig() -> StickinessConfiguration {
        guard let data = try? Data(contentsOf: storeURL) else {
            return StickinessConfiguration()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var config = try? decoder.decode(StickinessConfiguration.self, from: data) else {
            return StickinessConfiguration()
        }
        if config.minStickinessQuota < 0.20 && config.version == 1 {
            config.minStickinessQuota = 0.25
        }
        return config
    }

    public func saveConfig(_ config: StickinessConfiguration) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            try? data.write(to: storeURL, options: [.atomic])
        }
    }

    /// Record or update the sticky profile associated with a conversation.
    public func recordUsage(conversationId: String, profileName: String, model: String) {
        var config = loadConfig()
        config.records[conversationId] = StickinessRecord(
            conversationId: conversationId,
            profileName: profileName,
            model: model,
            lastUsedAt: .now
        )
        // Keep registry bounded to newest 500 records
        if config.records.count > 500 {
            let sorted = config.records.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
            var trimmed: [String: StickinessRecord] = [:]
            for r in sorted.prefix(400) {
                trimmed[r.conversationId] = r
            }
            config.records = trimmed
        }
        saveConfig(config)
    }

    /// Return the sticky profile for a conversation if known.
    public func stickyProfile(for conversationId: String) -> String? {
        loadConfig().records[conversationId]?.profileName
    }

    /// Return the full stickiness record for a conversation if known.
    public func record(for conversationId: String) -> StickinessRecord? {
        loadConfig().records[conversationId]
    }

    /// Check if the sticky profile has sufficient remaining quota and capacity.
    public func evaluateStickiness(
        profileName: String,
        snapshot: QuotaSnapshot?,
        activeThreads: Int,
        maxSlots: Int,
        requestedModel: String?,
        threshold: Double = 0.15,
        now: Date = .now
    ) -> (isSufficient: Bool, quotaRemaining: Double, reason: String) {
        // 0. Snapshot presence check
        guard let snapshot = snapshot else {
            return (false, 0.0, "No quota snapshot available for profile '\(profileName)'")
        }

        // 1. Thread capacity check
        if activeThreads >= maxSlots {
            return (false, 0.0, "Profile is at concurrency capacity (\(activeThreads)/\(maxSlots) threads)")
        }

        // 2. Depletion check
        if snapshot.isDepleted(for: requestedModel, at: now) {
            return (false, 0.0, "Profile quota is depleted")
        }

        // 3. Bottleneck quota fraction check
        let isClaudeRequested = QuotaSnapshot.isThirdPartyModel(requestedModel)

        let g5 = snapshot.geminiFiveHour?.clampedRemainingFraction ?? 0.0
        let gw = snapshot.geminiWeekly?.clampedRemainingFraction ?? 0.0
        let t5 = snapshot.thirdPartyFiveHour?.clampedRemainingFraction ?? 0.0
        let tw = snapshot.thirdPartyWeekly?.clampedRemainingFraction ?? 0.0

        let fFrac = isClaudeRequested ? t5 : g5
        let wFrac = isClaudeRequested ? tw : gw
        let bottleneckQuota = min(fFrac, wFrac)

        let fPct = Int((fFrac * 100).rounded())
        let wPct = Int((wFrac * 100).rounded())
        let pct = Int((bottleneckQuota * 100).rounded())
        let reqPct = Int((threshold * 100).rounded())

        if bottleneckQuota < threshold {
            return (false, bottleneckQuota, "Remaining quota (\(pct)% [5h: \(fPct)%, Wk: \(wPct)%]) is below stickiness threshold (\(reqPct)%)")
        }

        return (true, bottleneckQuota, "Sufficient headroom (\(pct)% quota [5h: \(fPct)%, Wk: \(wPct)%]) for cache reuse")
    }

    /// Detects the newest conversation ID across ~/.gemini/antigravity-cli, prioritizing conversations belonging to the given workspace.
    public func detectLatestConversationId(forWorkspace workspacePath: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)

        let targetDir = workspacePath ?? FileManager.default.currentDirectoryPath
        let normalizedTarget = URL(fileURLWithPath: targetDir).resolvingSymlinksInPath().path

        // 1. Query conversation_summaries.db for workspace-scoped conversations
        let dbURL = baseDir.appendingPathComponent("conversation_summaries.db")
        if FileManager.default.fileExists(atPath: dbURL.path),
           let convId = queryLatestWorkspaceConversation(dbPath: dbURL.path, workspacePath: normalizedTarget) {
            return convId
        }

        // 2. Check active sessions in ~/.agymux/sessions/ for matching cwd
        let sessionDir = home.appendingPathComponent(".agymux/sessions", isDirectory: true)
        if let sessionFiles = try? FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            struct SessionInfo: Decodable {
                let cwd: String?
                let conversationId: String?
            }
            var matchingSessions: [(String, Date)] = []
            for file in sessionFiles where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let info = try? JSONDecoder().decode(SessionInfo.self, from: data),
                   let conv = info.conversationId, !conv.isEmpty,
                   let cwd = info.cwd, !cwd.isEmpty,
                   URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == normalizedTarget,
                   let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = vals.contentModificationDate {
                    matchingSessions.append((conv, date))
                }
            }
            if let latestSession = matchingSessions.sorted(by: { $0.1 > $1.1 }).first {
                return latestSession.0
            }
        }

        // 3. Fallback to newest conversation globally across brain/ and conversations/
        var candidateURLs: [(URL, Date)] = []

        let brainDir = baseDir.appendingPathComponent("brain", isDirectory: true)
        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in dirs {
                if let vals = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = vals.contentModificationDate {
                    candidateURLs.append((dir, date))
                }
            }
        }

        let convDir = baseDir.appendingPathComponent("conversations", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: convDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension == "db" {
                if let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = vals.contentModificationDate {
                    candidateURLs.append((file.deletingPathExtension(), date))
                }
            }
        }

        let sorted = candidateURLs.sorted { $0.1 > $1.1 }
        return sorted.first?.0.lastPathComponent
    }

    private func queryLatestWorkspaceConversation(dbPath: String, workspacePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let escapedPath = workspacePath.replacingOccurrences(of: "'", with: "''")
        process.arguments = [
            dbPath,
            "SELECT conversation_id FROM conversation_summaries WHERE workspace_uris LIKE '%\(escapedPath)%' ORDER BY last_modified_time DESC LIMIT 1;"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
