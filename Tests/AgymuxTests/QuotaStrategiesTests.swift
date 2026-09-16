import Testing
import Foundation
@testable import AgymuxCore

@Suite("QuotaStrategies Tests")
struct QuotaStrategiesTests {
    private func makeSnapshot(
        profileID: String,
        gemini5h: Double,
        thirdParty5h: Double,
        geminiWeekly: Double = 1.0,
        thirdPartyWeekly: Double = 1.0,
        resetInMinutes: Double = 120,
        weeklyResetInHours: Double = 72
    ) -> QuotaSnapshot {
        let resetAt = Date().addingTimeInterval(resetInMinutes * 60)
        let weeklyResetAt = Date().addingTimeInterval(weeklyResetInHours * 3600)
        let metrics: [QuotaMetric] = [
            QuotaMetric(
                group: .gemini,
                scope: .geminiFamily,
                modelIDs: [],
                window: .fiveHour,
                remainingFraction: gemini5h,
                resetAt: resetAt,
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            ),
            QuotaMetric(
                group: .gemini,
                scope: .geminiFamily,
                modelIDs: [],
                window: .weekly,
                remainingFraction: geminiWeekly,
                resetAt: weeklyResetAt,
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            ),
            QuotaMetric(
                group: .thirdParty,
                scope: .thirdPartyFamily,
                modelIDs: [],
                window: .fiveHour,
                remainingFraction: thirdParty5h,
                resetAt: resetAt,
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            ),
            QuotaMetric(
                group: .thirdParty,
                scope: .thirdPartyFamily,
                modelIDs: [],
                window: .weekly,
                remainingFraction: thirdPartyWeekly,
                resetAt: weeklyResetAt,
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            )
        ]
        return QuotaSnapshot(profileID: profileID, metrics: metrics)
    }

    @Test("Max Headroom picks the profile with the highest bottleneck quota")
    func testMaxHeadroom() {
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.85, geminiWeekly: 0.80)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.50, thirdParty5h: 0.40, geminiWeekly: 0.40)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .maxHeadroom
        )

        #expect(best?.profileName == "p1")
    }

    @Test("Window Harvesting picks profile resetting in <60min with >=15% quota")
    func testWindowHarvesting() {
        // p1: 90% 5h quota, resets in 4 hours; 60% weekly
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90,
                              geminiWeekly: 0.60, thirdPartyWeekly: 0.60,
                              resetInMinutes: 240)
        // p2: 30% 5h quota, resets in 25 minutes (harvest!); 60% weekly
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.30, thirdParty5h: 0.30,
                              geminiWeekly: 0.60, thirdPartyWeekly: 0.60,
                              resetInMinutes: 25)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .harvest
        )

        #expect(best?.profileName == "p2")
    }

    @Test("Model-Adaptive selects Claude-healthy profile when Claude is requested")
    func testModelAdaptive() {
        // p1: 95% Gemini, but 10% Claude
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.10, geminiWeekly: 0.95, thirdPartyWeekly: 0.10)
        // p2: 60% Gemini, but 80% Claude
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.60, thirdParty5h: 0.80, geminiWeekly: 0.60, thirdPartyWeekly: 0.80)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let bestClaude = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            requestedModel: "claude-3-7-sonnet",
            strategy: .modelAdaptive
        )
        #expect(bestClaude?.profileName == "p2")

        let bestGemini = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            requestedModel: "gemini-2.5-pro",
            strategy: .modelAdaptive
        )
        #expect(bestGemini?.profileName == "p1")
    }

    @Test("Concurrency penalty penalizes active thread competition")
    func testConcurrencyPenalty() {
        // Both profiles have 90% quota, but p1 has 1 active thread and p2 has 0
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90, geminiWeekly: 0.90)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.90, thirdParty5h: 0.90, geminiWeekly: 0.90)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 1, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            maxSlotsPerProfile: 1,
            strategy: .smart
        )

        #expect(best?.profileName == "p2")
    }

    @Test("Model-specific depletion checks accurately segregate Gemini from Claude")
    func testModelSpecificDepletion() {
        // Snapshot with 95% Gemini but 0% Claude
        let snap = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.0, geminiWeekly: 0.95, thirdPartyWeekly: 0.0)

        #expect(!snap.isDepleted(for: "gemini-3.8-flash-high"))
        #expect(!snap.isDepleted(for: "gemini-2.5-pro"))
        #expect(snap.isDepleted(for: "claude-sonnet-4-6"))
        #expect(snap.isDepleted(for: "claude-3-7-sonnet"))
    }

    @Test("Gemini request selects account with high Gemini quota even if Claude is depleted")
    func testGeminiSelectionWhenClaudeDepleted() {
        // p1: 95% Gemini, 0% Claude (like real-world mitnick162)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.0, geminiWeekly: 0.95, thirdPartyWeekly: 0.0)
        // p2: 20% Gemini, 50% Claude
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.20, thirdParty5h: 0.50, geminiWeekly: 0.20, thirdPartyWeekly: 0.50)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            requestedModel: "gemini-3.8-flash-high",
            strategy: .smart
        )

        #expect(best?.profileName == "p1")
        #expect((best?.quotaRemaining ?? 0) >= 0.90)
    }

    @Test("Weekly urgency dominates 5-hour urgency in smart strategy")
    func testWeeklyUrgencyDominates5h() {
        // p1: high 5h quota resetting soon (25min), but high weekly quota resetting in 5 days
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.40, thirdParty5h: 0.40,
                              geminiWeekly: 0.90, thirdPartyWeekly: 0.90,
                              resetInMinutes: 25, weeklyResetInHours: 120)
        // p2: medium 5h quota resetting in 4 hours, but weekly quota resetting in 12 hours (urgent!)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.70, thirdParty5h: 0.70,
                              geminiWeekly: 0.50, thirdPartyWeekly: 0.50,
                              resetInMinutes: 240, weeklyResetInHours: 12)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .smart
        )

        // p2 should win because its weekly window is about to reset (12h) giving it up to 30 urgency pts
        // even though p1 has a 5h window resetting sooner (25m)
        #expect(best?.profileName == "p2")
    }

    @Test("Weekly near-depletion triggers hard penalty disqualifying the profile")
    func testWeeklyNearDepletionHardPenalty() {
        // p1: 95% 5h but only 8% weekly (near-depleted weekly = catastrophic)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.95,
                              geminiWeekly: 0.08, thirdPartyWeekly: 0.08)
        // p2: 50% 5h and 50% weekly (healthy)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.50, thirdParty5h: 0.50,
                              geminiWeekly: 0.50, thirdPartyWeekly: 0.50)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .smart
        )

        // p2 should win despite lower 5h — p1's weekly is near-depleted
        #expect(best?.profileName == "p2")
    }

    @Test("Fresh 100% weekly quota kick-off takes TOP priority in smart strategy")
    func testFresh100WeeklyKickoffSmartPriority() {
        // p1: 90% 5h, 75% weekly, resets soon (urgent)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90,
                              geminiWeekly: 0.75, thirdPartyWeekly: 0.75,
                              resetInMinutes: 20, weeklyResetInHours: 10)
        // p2: fresh 100% weekly quota (needs kick-off to start 7-day clock!), 80% 5h
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.80, thirdParty5h: 0.80,
                              geminiWeekly: 1.0, thirdPartyWeekly: 1.0,
                              resetInMinutes: 180, weeklyResetInHours: 168)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .smart
        )

        // p2 must win because fresh 100% weekly quota has top priority to kick off counter
        #expect(best?.profileName == "p2")
        #expect(best?.rationale.contains("TOP PRIORITY") == true)
    }

    @Test("Fresh 100% weekly quota kick-off takes TOP priority in harvest strategy")
    func testFresh100WeeklyKickoffHarvestPriority() {
        // p1: 5h window expiring in 15 mins (strong harvest candidate)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.50, thirdParty5h: 0.50,
                              geminiWeekly: 0.60, thirdPartyWeekly: 0.60,
                              resetInMinutes: 15)
        // p2: fresh 100% weekly quota
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.80, thirdParty5h: 0.80,
                              geminiWeekly: 1.0, thirdPartyWeekly: 1.0,
                              resetInMinutes: 240)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .harvest
        )

        #expect(best?.profileName == "p2")
        #expect(best?.rationale.contains("TOP PRIORITY") == true)
    }

    @Test("QuotaSnapshot helper correctly identifies fresh 100% weekly quota")
    func testHasFresh100WeeklyHelper() {
        let freshSnap = makeSnapshot(profileID: "fresh", gemini5h: 0.90, thirdParty5h: 0.90,
                                     geminiWeekly: 1.0, thirdPartyWeekly: 0.50)
        #expect(freshSnap.hasFresh100Weekly(for: "gemini-3.8-flash-high"))
        #expect(!freshSnap.hasFresh100Weekly(for: "claude-sonnet-4-6"))

        let depleted5hSnap = makeSnapshot(profileID: "bad5h", gemini5h: 0.05, thirdParty5h: 0.90,
                                          geminiWeekly: 1.0, thirdPartyWeekly: 1.0)
        #expect(!depleted5hSnap.hasFresh100Weekly(for: "gemini-3.8-flash-high"))
    }

    @Test("Process-balanced tiering prefers idle profile with 0 threads over 1 thread even if idle profile has lower quota")
    func testProcessBalancedTieringPreferZeroThreads() {
        // p1: 95% quota, but has 1 active thread
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.95,
                              geminiWeekly: 0.95, thirdPartyWeekly: 0.95)
        // p2: 60% quota, but has 0 active threads (completely idle)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.60, thirdParty5h: 0.60,
                              geminiWeekly: 0.60, thirdPartyWeekly: 0.60)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 1, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            maxSlotsPerProfile: 3,
            strategy: .smart
        )

        // p2 MUST win because process-balanced load distribution prevents dogpiling onto p1
        #expect(best?.profileName == "p2")
        #expect(best?.activeThreads == 0)
    }

    @Test("Weekly expiry urgency prioritizes profile resetting in 2 hours with 25% weekly quota over 5-day reset")
    func testWeeklyExpiryHarvestUrgency() {
        // p1: 60% weekly quota resetting in 5 days (120h)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90,
                              geminiWeekly: 0.60, thirdPartyWeekly: 0.60,
                              resetInMinutes: 240, weeklyResetInHours: 120)
        // p2: 25% weekly quota resetting in 2 hours (urgent harvest before wipeout!)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.80, thirdParty5h: 0.80,
                              geminiWeekly: 0.25, thirdPartyWeekly: 0.25,
                              resetInMinutes: 240, weeklyResetInHours: 2)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .smart
        )

        // p2 MUST win because its weekly window resets in 2 hours with 25% quota remaining
        #expect(best?.profileName == "p2")
        #expect(best?.rationale.contains("Weekly resets in") == true)
        #expect(best?.rationale.contains("25% W left") == true)
    }

    @Test("Distant weekly reset conserves low quota profile")
    func testDistantWeeklyLockoutConservation() {
        // p1: 15% weekly quota resetting in 5 days (120h) - low quota with distant reset
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.80, thirdParty5h: 0.80,
                              geminiWeekly: 0.15, thirdPartyWeekly: 0.15,
                              resetInMinutes: 240, weeklyResetInHours: 120)
        // p2: 35% weekly quota resetting in 5 days (120h)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.80, thirdParty5h: 0.80,
                              geminiWeekly: 0.35, thirdPartyWeekly: 0.35,
                              resetInMinutes: 240, weeklyResetInHours: 120)

        let quotas = ["p1": q1, "p2": q2]
        let threads = ["p1": 0, "p2": 0]

        let best = QuotaStrategies.selectBestProfile(
            candidates: ["p1", "p2"],
            quotas: quotas,
            activeThreads: threads,
            strategy: .smart
        )

        #expect(best?.profileName == "p2")
    }
}
