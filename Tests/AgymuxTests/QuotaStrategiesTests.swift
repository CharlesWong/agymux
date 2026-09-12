import Testing
import Foundation
@testable import AgymuxCore

@Suite("QuotaStrategies Tests")
struct QuotaStrategiesTests {
    private func makeSnapshot(profileID: String, gemini5h: Double, thirdParty5h: Double, resetInMinutes: Double = 120) -> QuotaSnapshot {
        let resetAt = Date().addingTimeInterval(resetInMinutes * 60)
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
                group: .thirdParty,
                scope: .thirdPartyFamily,
                modelIDs: [],
                window: .fiveHour,
                remainingFraction: thirdParty5h,
                resetAt: resetAt,
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            )
        ]
        return QuotaSnapshot(profileID: profileID, metrics: metrics)
    }

    @Test("Max Headroom picks the profile with the highest bottleneck quota")
    func testMaxHeadroom() {
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.85)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.50, thirdParty5h: 0.40)

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
        // p1: 90% quota, resets in 4 hours
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90, resetInMinutes: 240)
        // p2: 30% quota, resets in 25 minutes
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.30, thirdParty5h: 0.30, resetInMinutes: 25)

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
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.10)
        // p2: 60% Gemini, but 80% Claude
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.60, thirdParty5h: 0.80)

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
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.90, thirdParty5h: 0.90)
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.90, thirdParty5h: 0.90)

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
        let snap = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.0)

        #expect(!snap.isDepleted(for: "gemini-3.8-flash-high"))
        #expect(!snap.isDepleted(for: "gemini-2.5-pro"))
        #expect(snap.isDepleted(for: "claude-sonnet-4-6"))
        #expect(snap.isDepleted(for: "claude-3-7-sonnet"))
    }

    @Test("Gemini request selects account with high Gemini quota even if Claude is depleted")
    func testGeminiSelectionWhenClaudeDepleted() {
        // p1: 95% Gemini, 0% Claude (like real-world mitnick162)
        let q1 = makeSnapshot(profileID: "p1", gemini5h: 0.95, thirdParty5h: 0.0)
        // p2: 20% Gemini, 50% Claude
        let q2 = makeSnapshot(profileID: "p2", gemini5h: 0.20, thirdParty5h: 0.50)

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
}
