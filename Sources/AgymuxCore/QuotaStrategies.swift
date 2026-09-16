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
    public let maxSlots: Int
    public let rationale: String

    public var isEligible: Bool {
        activeThreads < maxSlots && quotaRemaining >= 0.05 && score > -500.0
    }
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
        let isClaudeRequested = QuotaSnapshot.isThirdPartyModel(requestedModel)

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
            hardPenalty -= 10_000.0 // Depleted account (either 5h or weekly is exhausted)
        }
        if weeklyFraction < 0.10 {
            hardPenalty -= 2_000.0 // Weekly near-depletion (<10% locks account for up to 7 days)
        }
        if threads >= maxSlots {
            hardPenalty -= 10_000.0 * Double(threads - maxSlots + 1) // Over-capacity
        }

        // Low fuel buffer penalties:
        // Prevent assigning work to accounts that are close to hitting quota walls when healthy accounts exist.
        var low5hPenalty = 0.0
        if fiveHourFraction < 0.25 {
            low5hPenalty += (0.25 - fiveHourFraction) * 120.0
            if fiveHourFraction < 0.12 {
                // Critical 5h near-depletion buffer: steep penalty to ensure any healthy idle profile is picked instead
                low5hPenalty += 40.0
            }
        }

        var lowWeeklyPenalty = 0.0
        if weeklyFraction < 0.15 {
            // Weekly depletion buffer (up to 7-day lockout)
            lowWeeklyPenalty += (0.15 - weeklyFraction) * 150.0 + 35.0
        }

        // Process-balanced load distribution (-120 pts per active thread):
        // 0 active processes is strongly preferred over 1 active process when accounts have healthy quota.
        // However, a healthy 1-thread account will beat a critical near-depleted (<12%) 0-thread account.
        let processTierPenalty = Double(threads) * 120.0

        // 4. Fresh 100% weekly quota detection (TOP PRIORITY)
        // When an account has 100% weekly quota, it should be used to kick off
        // its 7-day rolling counter so that the reset timer begins, provided it has healthy 5h fuel (>= 40%).
        let isFresh100Weekly = weeklyFraction >= 0.995 && fiveHourFraction >= 0.40
        let freshWeeklyKickoffBonus = isFresh100Weekly ? 50.0 : 0.0

        var reasonParts: [String] = []

        if isFresh100Weekly {
            reasonParts.append("New 100% weekly quota (kick off 7d counter, TOP PRIORITY)")
        }

        // Weekly Quota Expiry Urgency:
        // Weekly quota is a 7-day rolling window: unused weekly quota expires upon reset.
        // CRITICAL: A profile CANNOT harvest weekly quota if its 5h quota is low (< 25%)!
        // Gated by fiveHourFraction >= 0.25 and scaled by 5h fuel availability.
        var weeklyUrgencyScore = 0.0
        if timeToResetWeekly < 48 * 3600 && weeklyFraction >= 0.15 && fiveHourFraction >= 0.25 && !isFresh100Weekly {
            let urgencyRatio = max(0.0, 1.0 - (timeToResetWeekly / (48.0 * 3600.0)))
            let fuelMultiplier = min(1.0, fiveHourFraction / 0.50)
            weeklyUrgencyScore = urgencyRatio * (25.0 + weeklyFraction * 35.0) * fuelMultiplier
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

        if low5hPenalty > 0 {
            reasonParts.append("5h low (\(Int(fiveHourFraction * 100))%), avoiding")
        }
        if lowWeeklyPenalty > 0 {
            reasonParts.append("Weekly low (\(Int(weeklyFraction * 100))%), avoiding")
        }

        var score = 0.0

        switch strategy {
        case .smart:
            // Quota score: Bottleneck (min of 5h & W) anchors the score (0..50),
            // 5h gives immediate execution runway (0..25), Weekly gives reserve pool (0..15)
            let quotaScore = (quotaFraction * 50.0) + (fiveHourFraction * 25.0) + (weeklyFraction * 15.0)
            let affinityBonus = isCurrentlyActive ? 3.0 : 0.0

            score = quotaScore + weeklyUrgencyScore + freshWeeklyKickoffBonus
                - distantLockoutPenalty - low5hPenalty - lowWeeklyPenalty - processTierPenalty
                + affinityBonus + hardPenalty
            reasonParts.append("Quota: \(Int(fiveHourFraction * 100))% 5h / \(Int(weeklyFraction * 100))% W, Threads: \(threads)/\(maxSlots)")

        case .maxHeadroom:
            score = (quotaFraction * 60.0) + (fiveHourFraction * 25.0) + (weeklyFraction * 15.0)
                + freshWeeklyKickoffBonus - low5hPenalty - lowWeeklyPenalty - processTierPenalty + hardPenalty
            reasonParts.append("Headroom: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")

        case .harvest:
            // Weekly harvest takes top priority IF 5h has runway (>= 25%)
            if isFresh100Weekly {
                score = 120.0 + (quotaFraction * 20.0) - low5hPenalty - processTierPenalty + hardPenalty
            } else if timeToResetWeekly < 48 * 3600 && weeklyFraction >= 0.15 && fiveHourFraction >= 0.25 {
                let urgency = max(0.0, 1.0 - (timeToResetWeekly / (48.0 * 3600.0)))
                let harvestBonus = 60.0 + (urgency * 40.0) + (weeklyFraction * 30.0)
                score = harvestBonus - low5hPenalty - processTierPenalty + hardPenalty
                reasonParts.append("Weekly harvest: resets in \(Int(timeToResetWeekly / 3600))h (\(Int(weeklyFraction * 100))% W left)")
            } else if timeToReset5h < 3600 && fiveHourFraction >= 0.20 {
                let urgency5h = (3600.0 - timeToReset5h) / 3600.0
                let harvestBonus = 50.0 + (urgency5h * 30.0) + (fiveHourFraction * 15.0)
                score = harvestBonus - low5hPenalty - processTierPenalty + hardPenalty
                reasonParts.append("5h harvest fallback: resets in \(Int(timeToReset5h / 60))m")
            } else {
                score = (quotaFraction * 50.0) + (fiveHourFraction * 20.0) + (weeklyFraction * 15.0)
                    - low5hPenalty - lowWeeklyPenalty - processTierPenalty + hardPenalty
                reasonParts.append("Standard: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, Threads: \(threads)")
            }

        case .balanced:
            score = (quotaFraction * 50.0) + (fiveHourFraction * 25.0) + (weeklyFraction * 25.0)
                + freshWeeklyKickoffBonus - low5hPenalty - lowWeeklyPenalty - processTierPenalty + hardPenalty
            reasonParts.append("Balanced: 5h=\(Int(fiveHourFraction * 100))%, W=\(Int(weeklyFraction * 100))%, \(threads) threads")

        case .modelAdaptive:
            score = (quotaFraction * 50.0) + (fiveHourFraction * 25.0) + (weeklyFraction * 15.0)
                + freshWeeklyKickoffBonus - low5hPenalty - lowWeeklyPenalty - processTierPenalty + hardPenalty
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
            maxSlots: maxSlots,
            rationale: reasonParts.joined(separator: ", ")
        )
    }
}
