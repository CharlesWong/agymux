import Testing
import Foundation
@testable import AgymuxCore

@Suite("ConversationStickiness Tests")
struct ConversationStickinessTests {
    private func makeSnapshot(geminiQuota: Double, isDepleted: Bool = false) -> QuotaSnapshot {
        let metrics: [QuotaMetric] = [
            QuotaMetric(
                group: .gemini,
                scope: .geminiFamily,
                modelIDs: [],
                window: .fiveHour,
                remainingFraction: isDepleted ? 0.0 : geminiQuota,
                resetAt: Date().addingTimeInterval(3600),
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            ),
            QuotaMetric(
                group: .gemini,
                scope: .geminiFamily,
                modelIDs: [],
                window: .weekly,
                remainingFraction: isDepleted ? 0.0 : geminiQuota,
                resetAt: Date().addingTimeInterval(86400),
                source: .cloudQuotaSummary,
                fetchedAt: .now,
                confidence: .high
            )
        ]
        return QuotaSnapshot(profileID: "test-profile", metrics: metrics)
    }

    @Test("Record and retrieve sticky profile for conversation")
    func testRecordAndRetrieve() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stickiness_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("stickiness.json")
        let store = ConversationStickinessStore(storeURL: storeURL)

        store.recordUsage(
            conversationId: "conv-1234",
            profileName: "everestmountaineer",
            model: "gemini-3.8-flash-high"
        )

        let sticky = store.stickyProfile(for: "conv-1234")
        #expect(sticky == "everestmountaineer")

        let nonExistent = store.stickyProfile(for: "conv-unknown")
        #expect(nonExistent == nil)
    }

    @Test("Stickiness is maintained when profile has >=15% quota and available slots")
    func testStickinessMaintained() {
        let store = ConversationStickinessStore()
        let snap = makeSnapshot(geminiQuota: 0.85)

        let eval = store.evaluateStickiness(
            profileName: "everestmountaineer",
            snapshot: snap,
            activeThreads: 1,
            maxSlots: 3,
            requestedModel: "gemini-3.8-flash-high",
            threshold: 0.15
        )

        #expect(eval.isSufficient == true)
        #expect(eval.quotaRemaining == 0.85)
    }

    @Test("Stickiness breaks when profile quota is below threshold")
    func testStickinessBreaksLowQuota() {
        let store = ConversationStickinessStore()
        let snap = makeSnapshot(geminiQuota: 0.08) // 8% < 15%

        let eval = store.evaluateStickiness(
            profileName: "everestmountaineer",
            snapshot: snap,
            activeThreads: 0,
            maxSlots: 3,
            requestedModel: "gemini-3.8-flash-high",
            threshold: 0.15
        )

        #expect(eval.isSufficient == false)
        #expect(eval.reason.contains("below stickiness threshold"))
    }

    @Test("Stickiness breaks when profile is at max capacity")
    func testStickinessBreaksMaxCapacity() {
        let store = ConversationStickinessStore()
        let snap = makeSnapshot(geminiQuota: 0.90)

        let eval = store.evaluateStickiness(
            profileName: "everestmountaineer",
            snapshot: snap,
            activeThreads: 3,
            maxSlots: 3, // Full capacity
            requestedModel: "gemini-3.8-flash-high",
            threshold: 0.15
        )

        #expect(eval.isSufficient == false)
        #expect(eval.reason.contains("capacity"))
    }

    @Test("Stickiness breaks when profile is depleted")
    func testStickinessBreaksDepleted() {
        let store = ConversationStickinessStore()
        let snap = makeSnapshot(geminiQuota: 0.0, isDepleted: true)

        let eval = store.evaluateStickiness(
            profileName: "everestmountaineer",
            snapshot: snap,
            activeThreads: 0,
            maxSlots: 3,
            requestedModel: "gemini-3.8-flash-high",
            threshold: 0.15
        )

        #expect(eval.isSufficient == false)
    }
}
