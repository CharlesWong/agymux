import Testing
import Foundation
@testable import AgymuxCore

@Suite("PoolManager Tests")
struct PoolManagerTests {
    @Test("Default configuration segregates auto and reserved pools with limit 3")
    func testDefaultConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("pools.json")
        let aiswURL = tempDir.appendingPathComponent("aisw_config.json")

        let aiswMock: [String: Any] = [
            "profiles": [
                "antigravity": [
                    "current": [:],
                    "charleswongjy": [:],
                    "quavolve": [:],
                    "mitnick162": [:]
                ]
            ]
        ]
        let aiswData = try JSONSerialization.data(withJSONObject: aiswMock)
        try aiswData.write(to: aiswURL)

        let manager = PoolManager(configURL: configURL, aiswConfigURL: aiswURL)
        let config = manager.loadConfig()

        #expect(config.maxActiveThreadsPerProfile == 3)
        #expect(config.defaultStrategy == "smart")
        #expect(config.reservedFallbackMode == "prompt")
    }

    @Test("Changing category moves profile between pools")
    func testCategoryChange() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("pools.json")
        let aiswURL = tempDir.appendingPathComponent("aisw_config.json")

        let aiswMock: [String: Any] = [
            "profiles": [
                "antigravity": [
                    "quavolve": [:]
                ]
            ]
        ]
        let aiswData = try JSONSerialization.data(withJSONObject: aiswMock)
        try aiswData.write(to: aiswURL)

        let manager = PoolManager(configURL: configURL, aiswConfigURL: aiswURL)
        _ = manager.loadConfig()

        #expect(manager.category(of: "quavolve") == .auto)

        manager.setCategory(profile: "quavolve", category: .reserved)
        #expect(manager.category(of: "quavolve") == .reserved)

        manager.setCategory(profile: "quavolve", category: .auto)
        #expect(manager.category(of: "quavolve") == .auto)
    }

    @Test("Configurable fallback mode and thread limits")
    func testConfigurationUpdates() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("pools.json")
        let aiswURL = tempDir.appendingPathComponent("aisw_config.json")
        let manager = PoolManager(configURL: configURL, aiswConfigURL: aiswURL)

        manager.setMaxThreads(5)
        #expect(manager.loadConfig().maxActiveThreadsPerProfile == 5)

        manager.setFallbackMode("never")
        #expect(manager.loadConfig().reservedFallbackMode == "never")

        manager.setStrategy("harvest")
        #expect(manager.loadConfig().defaultStrategy == "harvest")
    }

    @Test("Configurable default model and normalization")
    func testModelConfiguration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("pools.json")
        let aiswURL = tempDir.appendingPathComponent("aisw_config.json")
        let manager = PoolManager(configURL: configURL, aiswConfigURL: aiswURL)

        #expect(manager.loadConfig().defaultModel == "gemini-3.8-flash-high")

        manager.setModel("claude sonnet 4.6")
        #expect(manager.loadConfig().defaultModel == "claude-sonnet-4-6")

        manager.setModel("gemini 3.8 flash high")
        #expect(manager.loadConfig().defaultModel == "gemini-3.8-flash-high")

        manager.setModel("Claude Opus 4.6 (Thinking)")
        #expect(manager.loadConfig().defaultModel == "claude-opus-4-6-thinking")
    }
}
