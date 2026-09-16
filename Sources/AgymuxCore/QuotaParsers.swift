import Foundation

public enum QuotaParseError: LocalizedError, Equatable {
    case invalidJSON
    case noQuotaData(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "Quota response was not valid JSON."
        case .noQuotaData(let detail): detail ?? "The data source returned no quota information."
        }
    }
}

public enum QuotaParsers {
    public static func cloudQuotaSummary(
        data: Data,
        profileID: String,
        account: String?,
        tier: String?,
        fetchedAt: Date = .now
    ) throws -> QuotaSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let groups = root["groups"] as? [[String: Any]]
        else {
            throw QuotaParseError.invalidJSON
        }

        var metrics: [QuotaMetric] = []
        for group in groups {
            let groupDisplayName = string(group["displayName"]) ?? ""
            let normalizedGroup = quotaGroup(groupDisplayName)
            let scope: QuotaScope = normalizedGroup == .thirdParty ? .thirdPartyFamily : .geminiFamily
            let modelsDesc = string(group["description"]) ?? ""
            let models = modelsDesc.replacingOccurrences(of: "Models within this group: ", with: "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                let bucketId = string(bucket["bucketId"]) ?? ""
                let windowRaw = string(bucket["window"]) ?? bucketId
                let window = QuotaWindowKind(normalizing: windowRaw)
                let isDisabled = (bucket["disabled"] as? Bool) ?? false
                let description = string(bucket["description"])?.lowercased() ?? ""
                let isExhaustedByDesc = description.contains("hit your weekly limit")
                    || description.contains("limit does not currently apply")

                var remaining = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"])
                if isDisabled || isExhaustedByDesc {
                    remaining = 0.0
                }
                let resetAt = date(bucket["resetTime"] ?? bucket["reset_time"])
                guard remaining != nil || resetAt != nil else { continue }
                metrics.append(
                    QuotaMetric(
                        group: normalizedGroup,
                        scope: scope,
                        modelIDs: models,
                        window: window,
                        remainingFraction: remaining,
                        resetAt: resetAt,
                        source: .cloudQuotaSummary,
                        fetchedAt: fetchedAt,
                        confidence: .high
                    )
                )
            }
        }

        // Enforce group-level cascading exhaustion: if weekly quota is depleted (<= 0.5%),
        // any 5-hour limit in that same family is completely disabled and unusable.
        var resolvedMetrics: [QuotaMetric] = []
        let grouped = Dictionary(grouping: metrics, by: { $0.group })
        for (_, groupMetrics) in grouped {
            let weekly = groupMetrics.first(where: { $0.window == .weekly })
            let weeklyDepleted = (weekly?.clampedRemainingFraction ?? 1.0) <= 0.005
            for m in groupMetrics {
                if weeklyDepleted && m.window == .fiveHour && (m.remainingFraction ?? 0.0) > 0.0 {
                    resolvedMetrics.append(
                        QuotaMetric(
                            group: m.group,
                            scope: m.scope,
                            modelIDs: m.modelIDs,
                            window: m.window,
                            remainingFraction: 0.0,
                            resetAt: m.resetAt,
                            source: m.source,
                            fetchedAt: m.fetchedAt,
                            confidence: m.confidence
                        )
                    )
                } else {
                    resolvedMetrics.append(m)
                }
            }
        }

        guard !resolvedMetrics.isEmpty else { throw QuotaParseError.noQuotaData(nil) }
        return QuotaSnapshot(
            profileID: profileID,
            account: account,
            tier: tier,
            fetchedAt: fetchedAt,
            metrics: resolvedMetrics,
            warnings: [],
            isCached: false
        )
    }

    public static func officialStatusLine(
        data: Data,
        profileID: String,
        receivedAt: Date = .now
    ) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quota = root["quota"] as? [String: Any]
        else { throw QuotaParseError.noQuotaData(nil) }

        let definitions: [(String, QuotaGroup, QuotaScope, QuotaWindowKind)] = [
            ("gemini-5h", .gemini, .geminiFamily, .fiveHour),
            ("gemini-weekly", .gemini, .geminiFamily, .weekly),
            ("3p-5h", .thirdParty, .thirdPartyFamily, .fiveHour),
            ("3p-weekly", .thirdParty, .thirdPartyFamily, .weekly),
        ]
        let metrics = definitions.compactMap { key, group, scope, window -> QuotaMetric? in
            guard let bucket = quota[key] as? [String: Any] else { return nil }
            let remaining = number(bucket["remaining_fraction"] ?? bucket["remainingFraction"])
            let resetAt = date(bucket["reset_time"] ?? bucket["resetTime"])
                ?? number(bucket["reset_in_seconds"] ?? bucket["resetInSeconds"])
                    .map { receivedAt.addingTimeInterval($0) }
            guard remaining != nil || resetAt != nil else { return nil }
            return QuotaMetric(
                group: group,
                scope: scope,
                modelIDs: [],
                window: window,
                remainingFraction: remaining,
                resetAt: resetAt,
                source: .officialStatusLine,
                fetchedAt: receivedAt,
                confidence: .authoritative
            )
        }
        guard !metrics.isEmpty else { throw QuotaParseError.noQuotaData(nil) }
        return QuotaSnapshot(
            profileID: profileID,
            account: string(root["account"]),
            tier: string(root["tier"]),
            fetchedAt: receivedAt,
            metrics: metrics,
            warnings: [],
            isCached: false
        )
    }

    public static func quotaGroup(_ raw: String) -> QuotaGroup {
        let value = raw.lowercased()
        if value.contains("gemini") || value.contains("google") { return .gemini }
        if value.contains("claude") || value.contains("gpt") || value.contains("oss") || value.contains("third") {
            return .thirdParty
        }
        return .unknown
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }
}
