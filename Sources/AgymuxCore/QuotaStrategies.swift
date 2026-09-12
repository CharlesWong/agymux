import Foundation

public enum QuotaStrategy: String, CaseIterable, Codable, Sendable {
    case smart
    case maxHeadroom = "max-headroom"
    case harvest
    case balanced
    case modelAdaptive = "model-adaptive"

    public var displayName: String {
        switch self {
        case .smart: "SmartScore (Composite Multi-Objective)"
        case .maxHeadroom: "Max Headroom (Greedy Maximum Quota)"
        case .harvest: "Window Harvesting (Earliest-Reset First)"
        case .balanced: "Water-Leveling (Balanced Proportional Drain)"
        case .modelAdaptive: "Model-Targeted Adaptive"
        }
    }
}

public struct ScoredProfile: Sendable {
    public let profileName: String
    public let score: Double
    public let quotaRemaining: Double
    public let activeThreads: Int
    public let rationale: String
}

public enum QuotaStrategies {
    /// Select the best profile given candidates, quota snapshots, active thread counts, and strategy.
    public static func selectBestProfile(
        candidates: [String],
        quotas: [String: QuotaSnapshot],
        activeThreads: [String: Int],
        maxSlotsPerProfile: Int = 1,
        requestedModel: String? = nil,
        currentlyActive: String? = nil,
        strategy: QuotaStrategy = .smart,
        now: Date = .now
    ) -> ScoredProfile? {
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.map { candidate in
            scoreCandidate(
                profileName: candidate,
                snapshot: quotas[candidate],
                threads: activeThreads[candidate, default: 0],
                maxSlots: maxSlotsPerProfile,
                requestedModel: requestedModel,
                isCurrentlyActive: candidate == currentlyActive,
                strategy: strategy,
                now: now
            )
        }

        // Return highest scoring candidate
        return scored.max(by: { $0.score < $1.score })
    }

    private static func scoreCandidate(
        profileName: String,
        snapshot: QuotaSnapshot?,
        threads: Int,
        maxSlots: Int,
        requestedModel: String?,
        isCurrentlyActive: Bool,
        strategy: QuotaStrategy,
        now: Date
    ) -> ScoredProfile {
        // 1. Determine model family target
        let isClaudeRequested: Bool
        if let model = requestedModel?.lowercased() {
            isClaudeRequested = model.contains("claude") || model.contains("gpt") || model.contains("oss")
        } else {
            isClaudeRequested = false
        }

        // 2. Extract bottleneck quota fraction
        let g5 = snapshot?.geminiFiveHour?.clampedRemainingFraction ?? 1.0
        let gw = snapshot?.geminiWeekly?.clampedRemainingFraction ?? 1.0
        let t5 = snapshot?.thirdPartyFiveHour?.clampedRemainingFraction ?? 1.0
        let tw = snapshot?.thirdPartyWeekly?.clampedRemainingFraction ?? 1.0

        let quotaFraction: Double
        if isClaudeRequested {
            quotaFraction = min(t5, tw)
        } else {
            quotaFraction = min(g5, gw)
        }

        let resetDate = snapshot?.primaryResetDate(for: requestedModel, at: now)
        let timeToReset = resetDate.map { max(0, $0.timeIntervalSince(now)) } ?? 5 * 3600

        // Hard disqualifications
        var hardPenalty = 0.0
        if quotaFraction < 0.05 {
            hardPenalty -= 1_000.0 // Depleted account
        }
        if threads >= maxSlots {
            hardPenalty -= 500.0 * Double(threads - maxSlots + 1) // Over-capacity
        }

        var score = 0.0
        var reasonParts: [String] = []

        switch strategy {
        case .smart:
            // 50 * Quota + 20 * Urgency - 30 * (Threads/MaxSlots) + Affinity
            let quotaScore = quotaFraction * 50.0
            var urgencyScore = 0.0
            if timeToReset < 3600 && quotaFraction >= 0.15 {
                urgencyScore = (1.0 - (timeToReset / 3600.0)) * 20.0
                reasonParts.append("Window resets in \(Int(timeToReset / 60))m (+\(Int(urgencyScore))pts)")
            }
            let concurrencyPenalty = (Double(threads) / Double(max(1, maxSlots))) * 30.0
            let affinityBonus = isCurrentlyActive ? 5.0 : 0.0

            score = quotaScore + urgencyScore - concurrencyPenalty + affinityBonus + hardPenalty
            reasonParts.append("Quota: \(Int(quotaFraction * 100))%, Threads: \(threads)/\(maxSlots)")

        case .maxHeadroom:
            // Purely greedy on available bottleneck quota, with penalty for active threads
            score = (quotaFraction * 100.0) - (Double(threads) * 40.0) + hardPenalty
            reasonParts.append("Max Headroom quota: \(Int(quotaFraction * 100))%")

        case .harvest:
            // Prioritizes expiring window if quota >= 15%
            if timeToReset < 3600 && quotaFraction >= 0.15 {
                let urgency = (3600.0 - timeToReset) / 3600.0
                score = (urgency * 80.0) + (quotaFraction * 20.0) - (Double(threads) * 30.0) + hardPenalty
                reasonParts.append("Harvesting: resets in \(Int(timeToReset / 60))m")
            } else {
                score = (quotaFraction * 50.0) - (Double(threads) * 30.0) + hardPenalty
                reasonParts.append("Standard quota: \(Int(quotaFraction * 100))%")
            }

        case .balanced:
            // Balances usage to drain evenly
            score = (quotaFraction * 60.0) - (Double(threads) * 50.0) + hardPenalty
            reasonParts.append("Balanced load: \(Int(quotaFraction * 100))%, \(threads) threads")

        case .modelAdaptive:
            // Strongly keys on requested model
            if isClaudeRequested {
                score = (min(t5, tw) * 80.0) - (Double(threads) * 30.0) + hardPenalty
                reasonParts.append("Claude targeted: \(Int(min(t5, tw) * 100))%")
            } else {
                score = (min(g5, gw) * 80.0) - (Double(threads) * 30.0) + hardPenalty
                reasonParts.append("Gemini targeted: \(Int(min(g5, gw) * 100))%")
            }
        }

        return ScoredProfile(
            profileName: profileName,
            score: score,
            quotaRemaining: quotaFraction,
            activeThreads: threads,
            rationale: reasonParts.joined(separator: ", ")
        )
    }
}
