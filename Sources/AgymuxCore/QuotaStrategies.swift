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

        // 2. Extract per-window quota fractions
        let g5 = snapshot?.geminiFiveHour?.clampedRemainingFraction ?? 1.0
        let gw = snapshot?.geminiWeekly?.clampedRemainingFraction ?? 1.0
        let t5 = snapshot?.thirdPartyFiveHour?.clampedRemainingFraction ?? 1.0
        let tw = snapshot?.thirdPartyWeekly?.clampedRemainingFraction ?? 1.0

        let fiveHourFraction: Double
        let weeklyFraction: Double
        let fiveHourResetDate: Date?
        let weeklyResetDate: Date?

        if isClaudeRequested {
            fiveHourFraction = t5
            weeklyFraction = tw
            fiveHourResetDate = snapshot?.thirdPartyFiveHour?.resetAt
            weeklyResetDate = snapshot?.thirdPartyWeekly?.resetAt
        } else {
            fiveHourFraction = g5
            weeklyFraction = gw
            fiveHourResetDate = snapshot?.geminiFiveHour?.resetAt
            weeklyResetDate = snapshot?.geminiWeekly?.resetAt
        }

        // The bottleneck is always the lower of the two windows
        let quotaFraction = min(fiveHourFraction, weeklyFraction)

        // 3. Compute per-window time-to-reset
        let timeToReset5h = fiveHourResetDate.map { max(0, $0.timeIntervalSince(now)) } ?? 5 * 3600
        let timeToResetWeekly = weeklyResetDate.map { max(0, $0.timeIntervalSince(now)) } ?? 7 * 86400

        // Hard disqualifications
        var hardPenalty = 0.0
        if quotaFraction < 0.05 {
            hardPenalty -= 1_000.0 // Depleted account
        }
        // Weekly depletion is catastrophic — hard-penalty even at higher threshold
        if weeklyFraction < 0.10 {
            hardPenalty -= 2_000.0 // Weekly near-depletion (up to 7-day lockout)
        }
        if threads >= maxSlots {
            hardPenalty -= 500.0 * Double(threads - maxSlots + 1) // Over-capacity
        }

        // 4. Fresh 100% weekly quota detection (TOP PRIORITY)
        // When an account has 100% weekly quota, it must be used first to kick off
        // its 7-day rolling counter so that the reset timer begins immediately.
        let isFresh100Weekly = weeklyFraction >= 0.995 && fiveHourFraction >= 0.15
        let freshWeeklyKickoffBonus = isFresh100Weekly ? 100.0 : 0.0

        var score = 0.0
        var reasonParts: [String] = []

        if isFresh100Weekly {
            reasonParts.append("New 100% weekly quota (kick off 7d counter, TOP PRIORITY)")
        }

        switch strategy {
        case .smart:
            // Quota score: 40% weight on bottleneck, 10% bonus for weekly headroom
            let quotaScore = quotaFraction * 40.0
            let weeklyHeadroomBonus = weeklyFraction * 10.0 // Reward weekly headroom independently

            // Urgency scoring: weekly urgency ALWAYS ranks higher than 5h urgency
            // Weekly urgency: worth up to 30 points (dominates)
            // 5h urgency: worth up to 15 points (supplementary)
            var weeklyUrgencyScore = 0.0
            if timeToResetWeekly < 24 * 3600 && weeklyFraction >= 0.15 && !isFresh100Weekly {
                // Weekly reset within 24 hours and still usable => harvest it
                weeklyUrgencyScore = (1.0 - (timeToResetWeekly / (24 * 3600))) * 30.0
                reasonParts.append("Weekly resets in \(Int(timeToResetWeekly / 3600))h (+\(Int(weeklyUrgencyScore))pts)")
            }

            var fiveHourUrgencyScore = 0.0
            if timeToReset5h < 3600 && fiveHourFraction >= 0.15 && !isFresh100Weekly {
                fiveHourUrgencyScore = (1.0 - (timeToReset5h / 3600.0)) * 15.0
                reasonParts.append("5h resets in \(Int(timeToReset5h / 60))m (+\(Int(fiveHourUrgencyScore))pts)")
            }

            let concurrencyPenalty = (Double(threads) / Double(max(1, maxSlots))) * 25.0
            let affinityBonus = isCurrentlyActive ? 3.0 : 0.0

            score = quotaScore + weeklyHeadroomBonus + weeklyUrgencyScore + fiveHourUrgencyScore + freshWeeklyKickoffBonus - concurrencyPenalty + affinityBonus + hardPenalty
            reasonParts.append("Quota: \(Int(fiveHourFraction * 100))%/\(Int(weeklyFraction * 100))%W, Threads: \(threads)/\(maxSlots)")

        case .maxHeadroom:
            // Greedy on bottleneck quota, but weekly headroom gets extra weight, fresh 100% weekly dominates
            score = (weeklyFraction * 60.0) + (fiveHourFraction * 40.0) + freshWeeklyKickoffBonus - (Double(threads) * 40.0) + hardPenalty
            reasonParts.append("Headroom: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%")

        case .harvest:
            // Fresh 100% weekly quota kick-off takes TOP priority even over harvesting
            if isFresh100Weekly {
                score = 150.0 + (fiveHourFraction * 20.0) - (Double(threads) * 30.0) + hardPenalty
            } else {
                var harvestBonus = 0.0
                var hasHarvest = false
                if timeToResetWeekly < 24 * 3600 && weeklyFraction >= 0.15 {
                    let urgency = (24 * 3600 - timeToResetWeekly) / (24 * 3600)
                    harvestBonus += (urgency * 60.0) + (weeklyFraction * 20.0)
                    hasHarvest = true
                    reasonParts.append("Weekly harvest: resets in \(Int(timeToResetWeekly / 3600))h")
                }
                if timeToReset5h < 3600 && fiveHourFraction >= 0.15 {
                    let urgency5h = (3600.0 - timeToReset5h) / 3600.0
                    harvestBonus += (urgency5h * 40.0) + (fiveHourFraction * 15.0)
                    hasHarvest = true
                    reasonParts.append("5h harvest: resets in \(Int(timeToReset5h / 60))m")
                }
                if hasHarvest {
                    // Flat harvest activation bonus ensures harvest always beats non-harvest profiles
                    score = 50.0 + harvestBonus + (weeklyFraction * 10.0) - (Double(threads) * 30.0) + hardPenalty
                } else {
                    // No harvest opportunity: conservative quota-weighted fallback
                    score = (weeklyFraction * 30.0) + (fiveHourFraction * 20.0) - (Double(threads) * 30.0) + hardPenalty
                    reasonParts.append("Standard: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%")
                }
            }

        case .balanced:
            // Balanced drain with weekly weighted heavier
            score = (weeklyFraction * 40.0) + (fiveHourFraction * 20.0) + freshWeeklyKickoffBonus - (Double(threads) * 50.0) + hardPenalty
            reasonParts.append("Balanced: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, \(threads) threads")

        case .modelAdaptive:
            // Model-specific selection, weekly dominates
            score = (weeklyFraction * 50.0) + (fiveHourFraction * 30.0) + freshWeeklyKickoffBonus - (Double(threads) * 30.0) + hardPenalty
            if isClaudeRequested {
                reasonParts.append("Claude: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%")
            } else {
                reasonParts.append("Gemini: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%")
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
