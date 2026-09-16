import Testing
import Foundation
@testable import AgymuxCore

@Suite("QuotaParsers Tests")
struct QuotaParsersTests {
    @Test("Parses Google Cloud PA Quota Summary response correctly")
    func testCloudQuotaSummaryParsing() throws {
        let jsonString = """
        {
            "groups": [
                {
                    "displayName": "Gemini",
                    "description": "Models within this group: gemini-3.8-flash, gemini-2.5-pro",
                    "buckets": [
                        {
                            "bucketId": "gemini-5h",
                            "window": "5h",
                            "remainingFraction": 0.85,
                            "resetTime": "2026-09-12T18:00:00Z"
                        },
                        {
                            "bucketId": "gemini-weekly",
                            "window": "weekly",
                            "remainingFraction": 0.65,
                            "resetTime": "2026-09-18T00:00:00Z"
                        }
                    ]
                },
                {
                    "displayName": "Claude and Third Party",
                    "description": "Models within this group: claude-sonnet-4-6",
                    "buckets": [
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "remainingFraction": 0.40,
                            "resetTime": "2026-09-12T16:30:00Z"
                        },
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "remainingFraction": 0.10,
                            "resetTime": "2026-09-17T00:00:00Z"
                        }
                    ]
                }
            ]
        }
        """

        let data = Data(jsonString.utf8)
        let snapshot = try QuotaParsers.cloudQuotaSummary(
            data: data,
            profileID: "test-profile",
            account: "test@example.com",
            tier: "pro"
        )

        #expect(snapshot.profileID == "test-profile")
        #expect(snapshot.account == "test@example.com")
        #expect(snapshot.tier == "pro")

        let g5 = try #require(snapshot.geminiFiveHour)
        #expect(g5.clampedRemainingFraction == 0.85)
        #expect(g5.window == .fiveHour)
        #expect(g5.group == .gemini)

        let gw = try #require(snapshot.geminiWeekly)
        #expect(gw.clampedRemainingFraction == 0.65)
        #expect(gw.window == .weekly)

        let t5 = try #require(snapshot.thirdPartyFiveHour)
        #expect(t5.clampedRemainingFraction == 0.40)
        #expect(t5.group == .thirdParty)

        let tw = try #require(snapshot.thirdPartyWeekly)
        #expect(tw.clampedRemainingFraction == 0.10)
    }

    @Test("Parses official statusline hook JSON format")
    func testOfficialStatusLineParsing() throws {
        let jsonString = """
        {
            "account": "dev@example.com",
            "tier": "enterprise",
            "quota": {
                "gemini-5h": {
                    "remaining_fraction": 0.92,
                    "reset_in_seconds": 3600
                },
                "gemini-weekly": {
                    "remaining_fraction": 0.70,
                    "reset_in_seconds": 86400
                },
                "3p-5h": {
                    "remaining_fraction": 0.50,
                    "reset_in_seconds": 1800
                },
                "3p-weekly": {
                    "remaining_fraction": 0.05,
                    "reset_in_seconds": 43200
                }
            }
        }
        """

        let data = Data(jsonString.utf8)
        let refDate = Date(timeIntervalSince1970: 1700000000)
        let snapshot = try QuotaParsers.officialStatusLine(
            data: data,
            profileID: "status-profile",
            receivedAt: refDate
        )

        #expect(snapshot.account == "dev@example.com")
        #expect(snapshot.tier == "enterprise")
        #expect(snapshot.geminiFiveHour?.clampedRemainingFraction == 0.92)
        #expect(snapshot.thirdPartyWeekly?.clampedRemainingFraction == 0.05)
        #expect(snapshot.geminiFiveHour?.resetAt == refDate.addingTimeInterval(3600))
    }

    @Test("Throws invalidJSON on garbage input")
    func testInvalidJSONHandling() {
        let badData = Data("not json at all".utf8)
        #expect(throws: QuotaParseError.self) {
            try QuotaParsers.cloudQuotaSummary(
                data: badData,
                profileID: "bad",
                account: nil,
                tier: nil
            )
        }
    }

    @Test("Disabled bucket and 0 weekly limit resolves remaining quota to 0.0")
    func testDisabledAndCascadingDepletionParsing() throws {
        let jsonString = """
        {
            "groups": [
                {
                    "displayName": "Claude and GPT models",
                    "description": "Models within this group: Claude Opus, Claude Sonnet",
                    "buckets": [
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "remainingFraction": 0,
                            "resetTime": "2026-09-19T03:16:55Z",
                            "description": "You have hit your weekly limit, it refreshes in 2 days, 4 hours."
                        },
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "disabled": true,
                            "remainingFraction": 1,
                            "resetTime": "2026-09-17T03:39:13Z",
                            "description": "You have hit your weekly limit, the 5-hour limit does not currently apply."
                        }
                    ]
                }
            ]
        }
        """

        let data = Data(jsonString.utf8)
        let snapshot = try QuotaParsers.cloudQuotaSummary(
            data: data,
            profileID: "depleted-claude",
            account: "test@example.com",
            tier: "pro"
        )

        let tw = try #require(snapshot.thirdPartyWeekly)
        #expect(tw.clampedRemainingFraction == 0.0)

        let t5 = try #require(snapshot.thirdPartyFiveHour)
        #expect(t5.clampedRemainingFraction == 0.0)
        #expect(snapshot.isDepleted(for: "claude-3-7-sonnet"))
    }
}
