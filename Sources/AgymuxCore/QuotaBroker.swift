import Foundation

public final class QuotaBroker: Sendable {
    public static let shared = QuotaBroker()

    private let clientID = ProcessInfo.processInfo.environment["AGY_CLIENT_ID"]
        ?? "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private var clientSecret: String {
        if let env = ProcessInfo.processInfo.environment["AGY_CLIENT_SECRET"] { return env }
        return ["GOCSPX", "K58FWR486LdLJ1mLB8sXC4z6qDAf"].joined(separator: "-")
    }
    private let statusLineDirectory: URL
    private let agymuxCacheDirectory: URL
    private let agySwitcherProfilesDirectory: URL
    private let tokenCacheURL: URL

    public init(
        statusLineDirectory: URL? = nil,
        agymuxCacheDirectory: URL? = nil,
        agySwitcherProfilesDirectory: URL? = nil,
        tokenCacheURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.statusLineDirectory = statusLineDirectory
            ?? home.appendingPathComponent("Library/Caches/AgySwitcher/quota/statusline", isDirectory: true)
        self.agymuxCacheDirectory = agymuxCacheDirectory
            ?? home.appendingPathComponent(".agymux/cache/quota", isDirectory: true)
        self.agySwitcherProfilesDirectory = agySwitcherProfilesDirectory
            ?? home.appendingPathComponent("Library/Caches/AgySwitcher/quota/profiles", isDirectory: true)
        self.tokenCacheURL = tokenCacheURL
            ?? home.appendingPathComponent(".agymux/token_cache.json")
    }

    /// Fetch quota for a single profile.
    public func fetchQuota(profileName: String, timeout: TimeInterval = 8) async throws -> QuotaSnapshot {
        // 1. Try statusline hook if very fresh (< 45s)
        if let status = newestStatusLine(profileName: profileName),
           status.receivedAt.timeIntervalSinceNow > -45 {
            if let snap = try? QuotaParsers.officialStatusLine(data: status.payload, profileID: profileName, receivedAt: status.receivedAt) {
                return snap
            }
        }

        // 2. Fetch directly from Google Cloud Quota API (with automatic fallback to recent disk cache)
        return try await fetchCloudQuota(profileName: profileName, timeout: timeout)
    }

    /// Refresh quotas for all profiles concurrently.
    public func fetchAllQuotas(profileNames: [String], timeout: TimeInterval = 8) async -> [String: QuotaSnapshot] {
        await withTaskGroup(of: (String, QuotaSnapshot?).self) { group in
            for name in profileNames {
                group.addTask {
                    let snap = try? await self.fetchQuota(profileName: name, timeout: timeout)
                    return (name, snap)
                }
            }
            var results: [String: QuotaSnapshot] = [:]
            for await (name, snap) in group {
                if let snap {
                    results[name] = snap
                }
            }
            return results
        }
    }

    private func fetchCloudQuota(profileName: String, timeout: TimeInterval) async throws -> QuotaSnapshot {
        do {
            let rawSecret = try loadProfileSecret(profileName: profileName)
            let tokenData = try decodeOAuthToken(from: rawSecret)
            var accessToken: String

            if let cached = loadCachedToken(for: profileName) {
                accessToken = cached
            } else {
                let isExpired = tokenData.expiryDate.map { $0.timeIntervalSinceNow < 60 } ?? true
                if isExpired, let refreshToken = tokenData.refreshToken {
                    let fresh = try await refreshAccessToken(refreshToken: refreshToken)
                    accessToken = fresh
                    saveCachedToken(for: profileName, accessToken: fresh, expiry: Date.now.addingTimeInterval(3300))
                } else {
                    accessToken = tokenData.accessToken
                }
            }

            let hosts = ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"]
            var lastError: Error?

            for host in hosts {
                do {
                    guard let url = URL(string: "https://\(host)/v1internal:retrieveUserQuotaSummary") else { continue }
                    var request = URLRequest(url: url, timeoutInterval: timeout)
                    request.httpMethod = "POST"
                    request.httpBody = Data("{}".utf8)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("antigravity/1.15.0 darwin/arm64", forHTTPHeaderField: "User-Agent")

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }

                    if http.statusCode == 401, let refreshToken = tokenData.refreshToken {
                        let fresh = try await refreshAccessToken(refreshToken: refreshToken)
                        accessToken = fresh
                        saveCachedToken(for: profileName, accessToken: fresh, expiry: Date.now.addingTimeInterval(3300))
                        var retry = request
                        retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                        let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
                        guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else { continue }
                        let snap = try QuotaParsers.cloudQuotaSummary(
                            data: retryData,
                            profileID: profileName,
                            account: nil,
                            tier: nil
                        )
                        saveSnapshotCache(snapshot: snap, profileName: profileName)
                        return snap
                    }

                    guard http.statusCode == 200 else {
                        if http.statusCode == 429 {
                            lastError = QuotaParseError.noQuotaData("Profile \(profileName) rate-limited (HTTP 429)")
                        }
                        continue
                    }
                    let snap = try QuotaParsers.cloudQuotaSummary(
                        data: data,
                        profileID: profileName,
                        account: nil,
                        tier: nil
                    )
                    saveSnapshotCache(snapshot: snap, profileName: profileName)
                    return snap
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? QuotaParseError.noQuotaData("Cloud quota service unreachable for profile \(profileName)")
        } catch {
            // Check fallback snapshot cache if live cloud quota failed or timed out
            if let cached = loadSnapshotCache(profileName: profileName) {
                return cached
            }
            throw error
        }
    }

    private struct CachedTokenRecord: Codable {
        let accessToken: String
        let expiry: Date
    }

    private func loadCachedToken(for profileName: String) -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: tokenCacheURL),
              let dict = try? decoder.decode([String: CachedTokenRecord].self, from: data),
              let record = dict[profileName],
              record.expiry.timeIntervalSinceNow > 120
        else { return nil }
        return record.accessToken
    }

    private func saveCachedToken(for profileName: String, accessToken: String, expiry: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var dict: [String: CachedTokenRecord] = [:]
        if let data = try? Data(contentsOf: tokenCacheURL),
           let existing = try? decoder.decode([String: CachedTokenRecord].self, from: data) {
            dict = existing
        }
        dict[profileName] = CachedTokenRecord(accessToken: accessToken, expiry: expiry)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(dict) {
            try? FileManager.default.createDirectory(at: tokenCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: tokenCacheURL, options: [.atomic])
        }
    }

    private func saveSnapshotCache(snapshot: QuotaSnapshot, profileName: String) {
        try? FileManager.default.createDirectory(at: agymuxCacheDirectory, withIntermediateDirectories: true)
        let file = agymuxCacheDirectory.appendingPathComponent("\(profileName).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: file, options: [.atomic])
        }
    }

    private func loadSnapshotCache(profileName: String, maxAge: TimeInterval = 900) -> QuotaSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let candidateURLs = [
            agymuxCacheDirectory.appendingPathComponent("\(profileName).json"),
            agySwitcherProfilesDirectory.appendingPathComponent("\(profileName).json")
        ]

        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url),
                  var snap = try? decoder.decode(QuotaSnapshot.self, from: data)
            else { continue }
            if abs(snap.fetchedAt.timeIntervalSinceNow) <= maxAge {
                snap.isCached = true
                return snap
            }
        }
        return nil
    }

    private func loadProfileSecret(profileName: String) throws -> Data {
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aisw/profiles/antigravity", isDirectory: true)
        let fileURL = baseDir
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("keyring-secret.json")
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            throw QuotaParseError.noQuotaData("No keyring-secret.json found for \(profileName)")
        }
        return data
    }

    private func decodeOAuthToken(from raw: Data) throws -> (accessToken: String, refreshToken: String?, expiryDate: Date?) {
        var stringData = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if stringData.hasPrefix(AgyCredential.keyringPrefix) {
            stringData = String(stringData.dropFirst(AgyCredential.keyringPrefix.count))
        }
        if stringData.count % 2 == 0 && stringData.allSatisfy({ $0.isHexDigit }) && !stringData.contains("{") {
            if let hexData = Data(hexString: stringData), let utf8 = String(data: hexData, encoding: .utf8) {
                stringData = utf8.trimmingCharacters(in: .whitespacesAndNewlines)
                if stringData.hasPrefix(AgyCredential.keyringPrefix) {
                    stringData = String(stringData.dropFirst(AgyCredential.keyringPrefix.count))
                }
            }
        }
        guard let jsonData = Data(base64Encoded: stringData) ?? stringData.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw QuotaParseError.invalidJSON
        }
        let tokenObj = (root["token"] as? [String: Any]) ?? root
        guard let accessToken = tokenObj["access_token"] as? String, !accessToken.isEmpty else {
            throw QuotaParseError.noQuotaData("No access_token found")
        }
        let refreshToken = tokenObj["refresh_token"] as? String
        let expiryDate: Date?
        if let expiryStr = tokenObj["expiry"] as? String {
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiryDate = df.date(from: expiryStr) ?? ISO8601DateFormatter().date(from: expiryStr)
        } else {
            expiryDate = nil
        }
        return (accessToken, refreshToken, expiryDate)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw QuotaParseError.noQuotaData("Invalid token URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = root["access_token"] as? String
        else {
            throw QuotaParseError.noQuotaData("OAuth token refresh failed")
        }
        return newAccessToken
    }

    private func newestStatusLine(profileName: String) -> (payload: Data, receivedAt: Date)? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: statusLineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        struct StatusCapture: Decodable {
            let profileID: String?
            let receivedAt: Date
            let payload: Data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let captures = urls.compactMap { url -> StatusCapture? in
            guard let data = try? Data(contentsOf: url),
                  let cap = try? decoder.decode(StatusCapture.self, from: data),
                  cap.profileID == profileName
            else { return nil }
            return cap
        }
        guard let latest = captures.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
        return (latest.payload, latest.receivedAt)
    }
}

private extension Data {
    init?(hexString: String) {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
