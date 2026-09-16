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
            hardPenalty -= 10_000.0 * Double(threads - maxSlots + 1) // Over-capacity
        }

        // Process-balanced load distribution:
        // Prioritize by active process count per profile (-150 pts per active thread).
        // A profile with 0 active processes will ALWAYS be preferred over a profile with 1 active process,
        // ensuring new tasks spread out across all idle profiles instead of crowding/dogpiling a single profile.
        let processTierPenalty = Double(threads) * 150.0

        // 4. Fresh 100% weekly quota detection (TOP PRIORITY)
        // When an account has 100% weekly quota, it must be used first to kick off
        // its 7-day rolling counter so that the reset timer begins immediately.
        let isFresh100Weekly = weeklyFraction >= 0.995 && fiveHourFraction >= 0.15
        let freshWeeklyKickoffBonus = isFresh100Weekly ? 80.0 : 0.0

        var score = 0.0
        var reasonParts: [String] = []

        if isFresh100Weekly {
            reasonParts.append("New 100% weekly quota (kick off 7d counter, TOP PRIORITY)")
        }

        // Weekly Quota Expiry Urgency:
        // 5-hour quota resets frequently every 5 hours and is NOT the bottleneck.
        // Weekly quota is a 7-day rolling window: any unused weekly quota expires into thin air upon reset.
        // Profiles with weekly reset within 48h and usable balance must be urgently harvested.
        var weeklyUrgencyScore = 0.0
        if timeToResetWeekly < 48 * 3600 && weeklyFraction >= 0.10 && !isFresh100Weekly {
            let urgencyRatio = max(0.0, 1.0 - (timeToResetWeekly / (48.0 * 3600.0)))
            weeklyUrgencyScore = urgencyRatio * (25.0 + weeklyFraction * 35.0)
            let hoursLeft = Int(timeToResetWeekly / 3600)
            let minsLeft = Int((timeToResetWeekly.truncatingRemainder(dividingBy: 3600)) / 60)
            let timeStr = hoursLeft > 0 ? "\(hoursLeft)h \(minsLeft)m" : "\(minsLeft)m"
            reasonParts.append("Weekly resets in \(timeStr) with \(Int(weeklyFraction * 100))% W left (+\(Int(weeklyUrgencyScore))pts urgency)")
        }

        // Distant weekly lockout conservation penalty:
        // If an account has low weekly quota (< 20%) and reset is far (> 3 days),
        // penalize using it to avoid locking out the account for days.
        var distantLockoutPenalty = 0.0
        if timeToResetWeekly > 72 * 3600 && weeklyFraction < 0.20 {
            distantLockoutPenalty = (0.20 - weeklyFraction) * 60.0
            reasonParts.append("Weekly reset in \(Int(timeToResetWeekly / 86400))d with low quota, conserving")
        }

        switch strategy {
        case .smart:
            // Quota score: Weekly quota is the strategic asset (weighted 40), 5h is secondary (weighted 15)
            let quotaScore = (weeklyFraction * 40.0) + (fiveHourFraction * 15.0)
            let weeklyHeadroomBonus = weeklyFraction * 10.0
            let affinityBonus = isCurrentlyActive ? 3.0 : 0.0

            score = quotaScore + weeklyHeadroomBonus + weeklyUrgencyScore + freshWeeklyKickoffBonus - distantLockoutPenalty - processTierPenalty + affinityBonus + hardPenalty
            reasonParts.append("Quota: \(Int(fiveHourFraction * 100))% 5h / \(Int(weeklyFraction * 100))% W, Threads: \(threads)/\(maxSlots)")

        case .maxHeadroom:
            score = (weeklyFraction * 60.0) + (fiveHourFraction * 20.0) + freshWeeklyKickoffBonus - processTierPenalty + hardPenalty
            reasonParts.append("Headroom: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")

        case .harvest:
            // Weekly harvest takes top priority: expiring weekly quota must be used before reset!
            if isFresh100Weekly {
                score = 150.0 + (fiveHourFraction * 15.0) - processTierPenalty + hardPenalty
            } else if timeToResetWeekly < 48 * 3600 && weeklyFraction >= 0.10 {
                let urgency = max(0.0, 1.0 - (timeToResetWeekly / (48.0 * 3600.0)))
                let harvestBonus = 60.0 + (urgency * 40.0) + (weeklyFraction * 30.0)
                score = harvestBonus - processTierPenalty + hardPenalty
                reasonParts.append("Weekly harvest: resets in \(Int(timeToResetWeekly / 3600))h (\(Int(weeklyFraction * 100))% W left)")
            } else if timeToReset5h < 3600 && fiveHourFraction >= 0.15 {
                let urgency5h = (3600.0 - timeToReset5h) / 3600.0
                let harvestBonus = 30.0 + (urgency5h * 20.0) + (fiveHourFraction * 10.0)
                score = harvestBonus - processTierPenalty + hardPenalty
                reasonParts.append("5h harvest fallback: resets in \(Int(timeToReset5h / 60))m")
            } else {
                score = (weeklyFraction * 30.0) + (fiveHourFraction * 15.0) - processTierPenalty + hardPenalty
                reasonParts.append("Standard: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")
            }

        case .balanced:
            score = (weeklyFraction * 50.0) + (fiveHourFraction * 15.0) + freshWeeklyKickoffBonus - processTierPenalty + hardPenalty
            reasonParts.append("Balanced: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, \(threads) threads")

        case .modelAdaptive:
            score = (weeklyFraction * 50.0) + (fiveHourFraction * 20.0) + freshWeeklyKickoffBonus - processTierPenalty + hardPenalty
            if isClaudeRequested {
                reasonParts.append("Claude: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")
            } else {
                reasonParts.append("Gemini: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")
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
