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
    public var minStickinessQuota: Double // Default 0.15 (15%)
    public var records: [String: StickinessRecord]

    public init(
        version: Int = 1,
        minStickinessQuota: Double = 0.15,
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
        guard let config = try? decoder.decode(StickinessConfiguration.self, from: data) else {
            return StickinessConfiguration()
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
        // 1. Thread capacity check
        if activeThreads >= maxSlots {
            return (false, 0.0, "Profile is at concurrency capacity (\(activeThreads)/\(maxSlots) threads)")
        }

        // 2. Depletion check
        if snapshot?.isDepleted(for: requestedModel, at: now) == true {
            return (false, 0.0, "Profile quota is depleted")
        }

        // 3. Bottleneck quota fraction check
        let isClaudeRequested: Bool
        if let model = requestedModel?.lowercased() {
            isClaudeRequested = model.contains("claude") || model.contains("gpt") || model.contains("oss")
        } else {
            isClaudeRequested = false
        }

        let g5 = snapshot?.geminiFiveHour?.clampedRemainingFraction ?? 1.0
        let gw = snapshot?.geminiWeekly?.clampedRemainingFraction ?? 1.0
        let t5 = snapshot?.thirdPartyFiveHour?.clampedRemainingFraction ?? 1.0
        let tw = snapshot?.thirdPartyWeekly?.clampedRemainingFraction ?? 1.0

        let bottleneckQuota = isClaudeRequested ? min(t5, tw) : min(g5, gw)

        if bottleneckQuota < threshold {
            let pct = Int(bottleneckQuota * 100)
            let reqPct = Int(threshold * 100)
            return (false, bottleneckQuota, "Remaining quota (\(pct)%) is below stickiness threshold (\(reqPct)%)")
        }

        let pct = Int(bottleneckQuota * 100)
        return (true, bottleneckQuota, "Sufficient headroom (\(pct)% quota) for cache reuse")
    }

    /// Detects the newest conversation ID across ~/.gemini/antigravity-cli/conversations/ and brain/
    public func detectLatestConversationId() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)

        var candidateURLs: [(URL, Date)] = []

        // Check brain/
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

        // Check conversations/*.db
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
}
