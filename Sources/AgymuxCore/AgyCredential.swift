import Foundation

/// Identity and comparison utilities for Antigravity OAuth credentials.
/// Credentials live in macOS Keychain (service: `gemini`, account: `antigravity`).
public enum AgyCredential {
    public static let keyringPrefix = "go-keyring-base64:"

    private struct Payload: Decodable {
        struct Token: Decodable {
            let refreshToken: String?
            let accessToken: String?

            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
                case accessToken = "access_token"
            }
        }

        let token: Token
    }

    /// Strips trailing newlines appended by `/usr/bin/security`.
    public static func normalizeCapturedSecret(_ data: Data) -> Data {
        guard data.last == 0x0A else { return data }
        return Data(data.dropLast())
    }

    /// Extracts the stable account refresh token from raw data.
    public static func refreshTokenIdentity(of data: Data) -> String? {
        let normalized = normalizeCapturedSecret(data)
        guard !normalized.isEmpty,
              let text = String(data: normalized, encoding: .utf8)
        else { return nil }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base64Part: String
        if cleanText.hasPrefix(keyringPrefix) {
            base64Part = String(cleanText.dropFirst(keyringPrefix.count))
        } else {
            base64Part = cleanText
        }

        guard let decoded = Data(base64Encoded: base64Part) ?? cleanText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: decoded),
              let rt = payload.token.refreshToken,
              !rt.isEmpty
        else { return nil }

        return rt
    }

    /// Whether two credential blobs authenticate the same account.
    /// Access token rotation does NOT change account identity.
    public static func representsSameAccount(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = normalizeCapturedSecret(lhs)
        let right = normalizeCapturedSecret(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        guard let leftIdentity = refreshTokenIdentity(of: left),
              let rightIdentity = refreshTokenIdentity(of: right)
        else { return false }
        return leftIdentity == rightIdentity
    }

    /// Extracts the email address from id_token JWT claims if present in the secret blob.
    public static func emailIdentity(of data: Data) -> String? {
        let normalized = normalizeCapturedSecret(data)
        guard !normalized.isEmpty,
              let text = String(data: normalized, encoding: .utf8)
        else { return nil }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base64Part = cleanText.hasPrefix(keyringPrefix)
            ? String(cleanText.dropFirst(keyringPrefix.count))
            : cleanText

        guard let decoded = Data(base64Encoded: base64Part) ?? cleanText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let idToken = json["id_token"] as? String
        else { return nil }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payloadB64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payloadB64.count % 4 != 0 {
            payloadB64.append("=")
        }

        guard let payloadData = Data(base64Encoded: payloadB64),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }

        return claims["email"] as? String
    }

    /// Synchronizes the active profile's credentials directly to Antigravity CLI's native
    /// token cache (`~/.gemini/antigravity-cli/antigravity-oauth-token`).
    public static func syncAntigravityOAuthTokenFile(
        fromSecretData rawData: Data,
        profileEmail: String? = nil,
        overrideURL: URL? = nil
    ) {
        let normalized = normalizeCapturedSecret(rawData)
        guard let text = String(data: normalized, encoding: .utf8) else { return }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base64Part = cleanText.hasPrefix(keyringPrefix)
            ? String(cleanText.dropFirst(keyringPrefix.count))
            : cleanText
        guard let jsonBytes = Data(base64Encoded: base64Part) ?? cleanText.data(using: .utf8) else { return }

        var finalData = jsonBytes
        if var json = (try? JSONSerialization.jsonObject(with: jsonBytes)) as? [String: Any] {
            if json["auth_method"] == nil {
                json["auth_method"] = "consumer"
            }
            if json["id_token_email"] == nil {
                let email = profileEmail ?? emailIdentity(of: rawData)
                if let email {
                    json["id_token_email"] = email
                }
            }
            if let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                finalData = formatted
            }
        }

        let tokenFileURL: URL
        if let overrideURL {
            tokenFileURL = overrideURL
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tokenFileURL = dir.appendingPathComponent("antigravity-oauth-token")
        }
        try? finalData.write(to: tokenFileURL, options: [.atomic, .completeFileProtection])
    }
}
