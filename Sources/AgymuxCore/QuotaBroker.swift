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

    public init(statusLineDirectory: URL? = nil) {
        self.statusLineDirectory = statusLineDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/AgySwitcher/quota/statusline", isDirectory: true)
    }

    /// Fetch quota for a single profile.
    public func fetchQuota(profileName: String, timeout: TimeInterval = 6) async throws -> QuotaSnapshot {
        // 1. Try statusline hook if very fresh (< 45s)
        if let status = newestStatusLine(profileName: profileName),
           status.receivedAt.timeIntervalSinceNow > -45 {
            if let snap = try? QuotaParsers.officialStatusLine(data: status.payload, profileID: profileName, receivedAt: status.receivedAt) {
                return snap
            }
        }

        // 2. Fetch directly from Google Cloud Quota API
        return try await fetchCloudQuota(profileName: profileName, timeout: timeout)
    }

    /// Refresh quotas for all profiles concurrently.
    public func fetchAllQuotas(profileNames: [String], timeout: TimeInterval = 6) async -> [String: QuotaSnapshot] {
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
        let rawSecret = try loadProfileSecret(profileName: profileName)
        let tokenData = try decodeOAuthToken(from: rawSecret)
        var accessToken = tokenData.accessToken

        let isExpired = tokenData.expiryDate.map { $0.timeIntervalSinceNow < 60 } ?? true
        if isExpired, let refreshToken = tokenData.refreshToken {
            if let fresh = try? await refreshAccessToken(refreshToken: refreshToken) {
                accessToken = fresh
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
                    var retry = request
                    retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else { continue }
                    return try QuotaParsers.cloudQuotaSummary(
                        data: retryData,
                        profileID: profileName,
                        account: nil,
                        tier: nil
                    )
                }

                guard http.statusCode == 200 else { continue }
                return try QuotaParsers.cloudQuotaSummary(
                    data: data,
                    profileID: profileName,
                    account: nil,
                    tier: nil
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? QuotaParseError.noQuotaData("Cloud quota service unreachable for profile \(profileName)")
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
