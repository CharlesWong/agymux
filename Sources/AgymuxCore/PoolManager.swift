import Foundation

public enum ProfileCategory: String, Codable, CaseIterable, Sendable {
    case auto
    case reserved
}

public struct PoolConfiguration: Codable, Sendable {
    public var version: Int
    public var defaultStrategy: String
    public var defaultModel: String
    public var maxActiveThreadsPerProfile: Int
    public var reservedFallbackMode: String // "prompt", "never", "auto"
    public var reserved: [String]
    public var auto: [String]

    private enum CodingKeys: String, CodingKey {
        case version, defaultStrategy, defaultModel, maxActiveThreadsPerProfile, reservedFallbackMode, reserved, auto
    }

    public init(
        version: Int = 1,
        defaultStrategy: String = "smart",
        defaultModel: String = "gemini-3.8-flash-high",
        maxActiveThreadsPerProfile: Int = 3,
        reservedFallbackMode: String = "prompt",
        reserved: [String] = [],
        auto: [String] = []
    ) {
        self.version = version
        self.defaultStrategy = defaultStrategy
        self.defaultModel = defaultModel
        self.maxActiveThreadsPerProfile = maxActiveThreadsPerProfile
        self.reservedFallbackMode = reservedFallbackMode
        self.reserved = reserved
        self.auto = auto
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.defaultStrategy = try container.decodeIfPresent(String.self, forKey: .defaultStrategy) ?? "smart"
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? "gemini-3.8-flash-high"
        self.maxActiveThreadsPerProfile = try container.decodeIfPresent(Int.self, forKey: .maxActiveThreadsPerProfile) ?? 3
        self.reservedFallbackMode = try container.decodeIfPresent(String.self, forKey: .reservedFallbackMode) ?? "prompt"
        self.reserved = try container.decodeIfPresent([String].self, forKey: .reserved) ?? []
        self.auto = try container.decodeIfPresent([String].self, forKey: .auto) ?? []
    }
}

public final class PoolManager: Sendable {
    public static let shared = PoolManager()

    private let configURL: URL
    private let aiswConfigURL: URL

    public init(configURL: URL? = nil, aiswConfigURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agymux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.configURL = configURL ?? dir.appendingPathComponent("pools.json")
        self.aiswConfigURL = aiswConfigURL ?? home.appendingPathComponent(".aisw/config.json")
    }

    /// Normalizes model names (e.g. "gemini 3.8 flash high" -> "gemini-3.8-flash-high")
    public static func normalizeModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower == "gemini 3.8 flash high" || lower == "gemini-3.8-flash-high" || lower == "flash high" {
            return "gemini-3.8-flash-high"
        }
        if lower == "gemini 3.8 flash medium" || lower == "gemini-3.8-flash-medium" {
            return "gemini-3.8-flash-medium"
        }
        if lower == "gemini 3.8 flash low" || lower == "gemini-3.8-flash-low" {
            return "gemini-3.8-flash-low"
        }
        if lower == "gemini 3.7 flash high" || lower == "gemini-3.7-flash-high" {
            return "gemini-3.7-flash-high"
        }
        if lower == "gemini 3.1 pro high" || lower == "gemini-3.1-pro-high" {
            return "gemini-3.1-pro-high"
        }
        if lower == "claude sonnet 4.6" || lower == "claude-sonnet-4-6" {
            return "claude-sonnet-4-6"
        }
        if lower == "claude opus 4.6" || lower == "claude-opus-4-6-thinking" || lower.contains("claude opus 4.6") {
            return "claude-opus-4-6-thinking"
        }
        return trimmed.replacingOccurrences(of: " ", with: "-")
    }

    /// Discovers all known Antigravity profiles from ~/.aisw/config.json.
    public func discoverAiswProfiles() -> [String] {
        guard let data = try? Data(contentsOf: aiswConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [String: Any],
              let agyProfiles = profiles["antigravity"] as? [String: Any]
        else {
            // Fallback: check profile directory
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aisw/profiles/antigravity", isDirectory: true)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
            return contents.filter { !$0.hasPrefix(".") }
        }
        return Array(agyProfiles.keys).sorted()
    }

    /// Returns the resolved Google email address for a given profile.
    public func email(for profileName: String) -> String? {
        let secretURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aisw/profiles/antigravity", isDirectory: true)
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("keyring-secret.json")
        guard let data = try? Data(contentsOf: secretURL), !data.isEmpty else { return nil }
        return AgyCredential.emailIdentity(of: data)
    }

    /// Loads or creates the pool configuration.
    public func loadConfig() -> PoolConfiguration {
        let aiswProfiles = discoverAiswProfiles()

        guard let data = try? Data(contentsOf: configURL),
              var config = try? JSONDecoder().decode(PoolConfiguration.self, from: data)
        else {
            // Default configuration:
            // Reserved pool: profiles named "current" or "reserved", or matching environment overrides.
            let envReservedProfiles = ProcessInfo.processInfo.environment["AGYMUX_RESERVED_PROFILES"]?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
            let envReservedEmails = ProcessInfo.processInfo.environment["AGYMUX_RESERVED_EMAILS"]?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []

            var reserved: [String] = []
            var auto: [String] = []

            for p in aiswProfiles {
                let em = email(for: p)?.lowercased() ?? ""
                let pLower = p.lowercased()
                let isReserved = pLower == "current"
                    || pLower.contains("reserved")
                    || envReservedProfiles.contains(pLower)
                    || (!em.isEmpty && envReservedEmails.contains(em))

                if isReserved {
                    reserved.append(p)
                } else {
                    auto.append(p)
                }
            }

            let initial = PoolConfiguration(
                version: 1,
                defaultStrategy: "smart",
                defaultModel: "gemini-3.8-flash-high",
                maxActiveThreadsPerProfile: 3,
                reservedFallbackMode: "prompt",
                reserved: reserved.sorted(),
                auto: auto.sorted()
            )
            saveConfig(initial)
            return initial
        }

        // Ensure default is 3 if user had old 1
        if config.maxActiveThreadsPerProfile == 1 && config.version == 1 {
            config.maxActiveThreadsPerProfile = 3
        }

        // Merge any newly discovered aisw profiles not yet in config
        var changed = false
        let existing = Set(config.reserved + config.auto)
        let envReservedProfiles = ProcessInfo.processInfo.environment["AGYMUX_RESERVED_PROFILES"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        let envReservedEmails = ProcessInfo.processInfo.environment["AGYMUX_RESERVED_EMAILS"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []

        for p in aiswProfiles where !existing.contains(p) {
            let em = email(for: p)?.lowercased() ?? ""
            let pLower = p.lowercased()
            let isReserved = pLower == "current"
                || pLower.contains("reserved")
                || envReservedProfiles.contains(pLower)
                || (!em.isEmpty && envReservedEmails.contains(em))

            if isReserved {
                config.reserved.append(p)
            } else {
                config.auto.append(p)
            }
            changed = true
        }
        if changed {
            config.reserved.sort()
            config.auto.sort()
            saveConfig(config)
        }

        return config
    }

    public func saveConfig(_ config: PoolConfiguration) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL, options: [.atomic])
        }
    }

    public func setCategory(profile: String, category: ProfileCategory) {
        var config = loadConfig()
        config.reserved.removeAll { $0 == profile }
        config.auto.removeAll { $0 == profile }

        switch category {
        case .auto:
            config.auto.append(profile)
            config.auto.sort()
        case .reserved:
            config.reserved.append(profile)
            config.reserved.sort()
        }
        saveConfig(config)
    }

    public func setStrategy(_ strategy: String) {
        var config = loadConfig()
        config.defaultStrategy = strategy
        saveConfig(config)
    }

    public func setModel(_ model: String) {
        var config = loadConfig()
        config.defaultModel = Self.normalizeModelName(model)
        saveConfig(config)
    }

    public func setMaxThreads(_ maxThreads: Int) {
        var config = loadConfig()
        config.maxActiveThreadsPerProfile = max(1, maxThreads)
        saveConfig(config)
    }

    public func setFallbackMode(_ mode: String) {
        var config = loadConfig()
        config.reservedFallbackMode = mode
        saveConfig(config)
    }

    public func category(of profile: String) -> ProfileCategory? {
        let config = loadConfig()
        if config.reserved.contains(profile) { return .reserved }
        if config.auto.contains(profile) { return .auto }
        return nil
    }
}
