import Foundation

public enum QuotaGroup: String, Codable, CaseIterable, Sendable {
    case gemini
    case thirdParty = "third-party"
    case unknown

    public var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .thirdParty: "Claude / GPT"
        case .unknown: "Models"
        }
    }
}

public enum QuotaWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour = "5h"
    case weekly
    case daily
    case rolling
    case unknown

    public init(normalizing raw: String?) {
        let value = raw?.lowercased() ?? ""
        if value == "5h" || value.contains("5 hour") || value.contains("five hour") {
            self = .fiveHour
        } else if value.contains("week") || value == "w" {
            self = .weekly
        } else if value.contains("day") {
            self = .daily
        } else if value.contains("roll") {
            self = .rolling
        } else {
            self = .unknown
        }
    }

    public var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "W"
        case .daily: "D"
        case .rolling: "R"
        case .unknown: "Pool"
        }
    }
}

public enum QuotaScope: String, Codable, Sendable {
    case geminiFamily = "gemini-family"
    case thirdPartyFamily = "third-party-family"
    case providerPool = "provider-pool"
    case requestBucket = "request-bucket"
    case model
}

public enum QuotaSource: String, Codable, Sendable {
    case officialStatusLine = "official_statusline"
    case localGetUserStatus = "local_get_user_status"
    case cloudQuotaSummary = "cloud_quota_summary"
    case ptyUsage = "pty_usage"

    public var displayName: String {
        switch self {
        case .officialStatusLine: "Statusline Hook"
        case .localGetUserStatus: "Local LanguageServer"
        case .cloudQuotaSummary: "Google Cloud Quota API"
        case .ptyUsage: "AGY Usage"
        }
    }

    public var priority: Int {
        switch self {
        case .officialStatusLine: 600
        case .ptyUsage: 550
        case .localGetUserStatus: 500
        case .cloudQuotaSummary: 450
        }
    }
}

public enum QuotaConfidence: String, Codable, Sendable {
    case authoritative
    case high
    case advisory
    case unknown
}

public struct QuotaMetric: Codable, Hashable, Identifiable, Sendable {
    public let group: QuotaGroup
    public let scope: QuotaScope
    public let modelIDs: [String]
    public let window: QuotaWindowKind
    public let remainingFraction: Double?
    public let resetAt: Date?
    public let source: QuotaSource
    public let fetchedAt: Date
    public let confidence: QuotaConfidence

    public var id: String {
        "\(group.rawValue)|\(scope.rawValue)|\(window.rawValue)|\(source.rawValue)"
    }

    public var clampedRemainingFraction: Double? {
        remainingFraction.map { min(1.0, max(0.0, $0)) }
    }

    public func isFresh(at now: Date = .now) -> Bool {
        now.timeIntervalSince(fetchedAt) <= 15 * 60
    }

    public func isDepleted(at now: Date = .now) -> Bool {
        guard let fraction = clampedRemainingFraction else { return false }
        if fraction > 0.005 { return false }
        if let resetAt, resetAt <= now { return false }
        return true
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let profileID: String
    public var account: String?
    public var tier: String?
    public var fetchedAt: Date
    public var metrics: [QuotaMetric]
    public var warnings: [String]
    public var isCached: Bool

    public init(
        profileID: String,
        account: String? = nil,
        tier: String? = nil,
        fetchedAt: Date = .now,
        metrics: [QuotaMetric],
        warnings: [String] = [],
        isCached: Bool = false
    ) {
        self.profileID = profileID
        self.account = account
        self.tier = tier
        self.fetchedAt = fetchedAt
        self.metrics = metrics
        self.warnings = warnings
        self.isCached = isCached
    }

    public func metric(group: QuotaGroup, window: QuotaWindowKind) -> QuotaMetric? {
        metrics
            .filter { $0.group == group && $0.window == window }
            .max { $0.source.priority < $1.source.priority }
    }

    public var geminiFiveHour: QuotaMetric? {
        metric(group: .gemini, window: .fiveHour)
    }

    public var geminiWeekly: QuotaMetric? {
        metric(group: .gemini, window: .weekly)
    }

    public var thirdPartyFiveHour: QuotaMetric? {
        metric(group: .thirdParty, window: .fiveHour)
    }

    public var thirdPartyWeekly: QuotaMetric? {
        metric(group: .thirdParty, window: .weekly)
    }

    public var primaryFiveHour: QuotaMetric? {
        let candidates = [geminiFiveHour, thirdPartyFiveHour].compactMap { $0 }
        return candidates.min { ($0.clampedRemainingFraction ?? 1.0) < ($1.clampedRemainingFraction ?? 1.0) }
    }

    public var primaryWeekly: QuotaMetric? {
        let candidates = [geminiWeekly, thirdPartyWeekly].compactMap { $0 }
        return candidates.min { ($0.clampedRemainingFraction ?? 1.0) < ($1.clampedRemainingFraction ?? 1.0) }
    }

    public func isDepleted(for requestedModel: String? = nil, at now: Date = .now) -> Bool {
        let isClaudeRequested: Bool
        if let model = requestedModel?.lowercased() {
            isClaudeRequested = model.contains("claude") || model.contains("gpt") || model.contains("oss")
        } else {
            isClaudeRequested = false
        }

        if isClaudeRequested {
            if let t5 = thirdPartyFiveHour, t5.isDepleted(at: now) { return true }
            if let tw = thirdPartyWeekly, tw.isDepleted(at: now) { return true }
        } else {
            if let g5 = geminiFiveHour, g5.isDepleted(at: now) { return true }
            if let gw = geminiWeekly, gw.isDepleted(at: now) { return true }
        }
        return false
    }

    public func primaryResetDate(for requestedModel: String? = nil, at now: Date = .now) -> Date? {
        let isClaudeRequested: Bool
        if let model = requestedModel?.lowercased() {
            isClaudeRequested = model.contains("claude") || model.contains("gpt") || model.contains("oss")
        } else {
            isClaudeRequested = false
        }

        if isClaudeRequested {
            if let t5 = thirdPartyFiveHour, (t5.clampedRemainingFraction ?? 1.0) <= 0.20 {
                if let reset = t5.resetAt, reset > now { return reset }
            }
            if let tw = thirdPartyWeekly, (tw.clampedRemainingFraction ?? 1.0) <= 0.15 {
                if let reset = tw.resetAt, reset > now { return reset }
            }
            return [thirdPartyFiveHour?.resetAt, thirdPartyWeekly?.resetAt].compactMap { $0 }.filter { $0 > now }.min()
        } else {
            if let g5 = geminiFiveHour, (g5.clampedRemainingFraction ?? 1.0) <= 0.20 {
                if let reset = g5.resetAt, reset > now { return reset }
            }
            if let gw = geminiWeekly, (gw.clampedRemainingFraction ?? 1.0) <= 0.15 {
                if let reset = gw.resetAt, reset > now { return reset }
            }
            return [geminiFiveHour?.resetAt, geminiWeekly?.resetAt].compactMap { $0 }.filter { $0 > now }.min()
        }
    }
}
