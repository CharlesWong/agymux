import Testing
import Foundation
@testable import AgymuxCore

private final class MutableCredential: @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
}

private final class MutableCount: @unchecked Sendable {
    var value = 0
}

@Suite("KeychainClient Tests")
struct KeychainClientTests {
    @Test("Acquires and releases POSIX file switch.lock cleanly")
    func testLockAcquireAndRelease() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agymux_test_lock_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = KeychainClient(supportDirectory: tempDir)
        let lock1 = try client.acquireLock()
        #expect(lock1 >= 0)

        // Verify lock file exists
        let lockPath = tempDir.appendingPathComponent("switch.lock").path
        #expect(FileManager.default.fileExists(atPath: lockPath))

        client.releaseLock(lock1)

        // Can acquire again after release
        let lock2 = try client.acquireLock()
        #expect(lock2 >= 0)
        client.releaseLock(lock2)
    }

    @Test("Stored credential reading returns nil for nonexistent profile")
    func testStoredCredentialNonexistent() {
        let client = KeychainClient()
        let cred = client.readStoredCredential(profileName: "non_existent_profile_xyz_99999")
        #expect(cred == nil)
    }

    @Test("Uses the Switchboard shared lock location by default")
    func testDefaultSharedLockLocation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let client = KeychainClient(homeDirectory: home)
        let descriptor = try client.acquireLock()
        client.releaseLock(descriptor)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/AgySwitcher/switch.lock").path))
    }

    @Test("Matching live identity still invokes bridge when configured profile differs")
    func testMatchingIdentityRepairsConfiguredProfileWithoutTouchingWorkspace() async throws {
        let fixture = try makeFixture(active: "other")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let live = MutableCredential(fixture.target)
        let calls = MutableCredential(Data())
        let runner: KeychainClient.BridgeRunner = { _, arguments, _ in
            if arguments.contains("version") { return bridgeVersion() }
            calls.data = Data("called".utf8)
            try writeActive("target", home: fixture.home)
            return BridgeExecutionResult(exitCode: 0)
        }
        let client = KeychainClient(homeDirectory: fixture.home, bridgeRunner: runner,
            liveCredentialReader: { _ in live.data }, bridgeLocator: { "/fake/aisw-switchboard" })
        try await client.activateProfile("target")
        #expect(calls.data == Data("called".utf8))
        #expect(readText(fixture.settings) == "shared settings")
        #expect(readText(fixture.conversation) == "shared conversation")
    }

    @Test("Missing, unsafe, and failing bridges never use a fallback write")
    func testBridgeFailuresHaveNoFallback() async throws {
        let fixture = try makeFixture(active: "other")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let live = MutableCredential(Data("other".utf8))
        let calls = MutableCount()
        let missing = KeychainClient(homeDirectory: fixture.home, liveCredentialReader: { _ in live.data }, bridgeLocator: { nil })
        await #expect(throws: KeychainError.self) { try await missing.activateProfile("target") }
        #expect(live.data == Data("other".utf8))
        let unsafe = KeychainClient(homeDirectory: fixture.home, bridgeRunner: { _, arguments, _ in
            calls.value += 1
            return arguments.contains("version") ? BridgeExecutionResult(exitCode: 0, standardOutput: #"{"version":"0.3.8","cli_api_version":1}"#) : BridgeExecutionResult(exitCode: 0)
        }, liveCredentialReader: { _ in live.data }, bridgeLocator: { "/fake/aisw-switchboard" })
        await #expect(throws: KeychainError.self) { try await unsafe.activateProfile("target") }
        #expect(calls.value == 1) // version check only; use was never attempted
        #expect(live.data == Data("other".utf8))
        let numericMarker = KeychainClient(homeDirectory: fixture.home, bridgeRunner: { _, _, _ in
            BridgeExecutionResult(exitCode: 0, standardOutput: #"{"version":"0.3.8","cli_api_version":1,"antigravity_credential_only":1}"#)
        }, liveCredentialReader: { _ in live.data }, bridgeLocator: { "/fake/aisw-switchboard" })
        await #expect(throws: KeychainError.self) { try await numericMarker.activateProfile("target") }
        #expect(live.data == Data("other".utf8))
        let failing = KeychainClient(homeDirectory: fixture.home, bridgeRunner: { _, arguments, _ in
            arguments.contains("version") ? bridgeVersion() : BridgeExecutionResult(exitCode: 17, standardError: "bridge failed")
        }, liveCredentialReader: { _ in live.data }, bridgeLocator: { "/fake/aisw-switchboard" })
        await #expect(throws: KeychainError.self) { try await failing.activateProfile("target") }
        #expect(live.data == Data("other".utf8))
    }

    @Test("Blocks activation while Switchboard recovery is pending")
    func testPendingRecoveryBlocksBeforeBridge() async throws {
        let fixture = try makeFixture(active: "other")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let journal = fixture.support.appendingPathComponent("recovery/pending-switch.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: journal)
        let calls = MutableCount()
        let client = KeychainClient(homeDirectory: fixture.home, bridgeRunner: { _, _, _ in calls.value += 1; return bridgeVersion() }, liveCredentialReader: { _ in Data("other".utf8) }, bridgeLocator: { "/fake/aisw-switchboard" })
        await #expect(throws: KeychainError.recoveryPending) { try await client.activateProfile("target") }
        #expect(calls.value == 0)
    }

    @Test("Rejects successful bridge output when post-switch identity verification differs")
    func testVerificationMismatchFails() async throws {
        let fixture = try makeFixture(active: "other")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let client = KeychainClient(homeDirectory: fixture.home, bridgeRunner: { _, arguments, _ in
            if arguments.contains("version") { return bridgeVersion() }
            try writeActive("target", home: fixture.home)
            return BridgeExecutionResult(exitCode: 0)
        }, liveCredentialReader: { _ in Data("other".utf8) }, bridgeLocator: { "/fake/aisw-switchboard" })
        await #expect(throws: KeychainError.verificationFailed("target")) { try await client.activateProfile("target") }
    }

    @Test("Timed-out bridge is reaped with its process group before returning")
    func testBridgeTimeoutKillsLateWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late-write")
        let script = directory.appendingPathComponent("aisw-switchboard")
        let source = "#!/bin/sh\n(sleep 0.4; echo late > '\(marker.path)') &\nsleep 5\n"
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(throws: KeychainError.timedOut) { try KeychainClient.runBridge(script.path, [], 0.05) }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

private struct KeychainFixture {
    let home: URL
    let support: URL
    let target: Data
    let settings: URL
    let conversation: URL
}

private func makeFixture(active: String) throws -> KeychainFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("agymux_keychain_\(UUID().uuidString)")
    let profile = home.appendingPathComponent(".aisw/profiles/antigravity/target")
    let support = home.appendingPathComponent("Library/Application Support/AgySwitcher")
    let gemini = home.appendingPathComponent(".gemini/antigravity-cli")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
    try Data("target".utf8).write(to: profile.appendingPathComponent("keyring-secret.json"))
    try writeActive(active, home: home)
    let settings = gemini.appendingPathComponent("settings.json")
    let conversation = gemini.appendingPathComponent("conversation.json")
    try Data("shared settings".utf8).write(to: settings)
    try Data("shared conversation".utf8).write(to: conversation)
    return KeychainFixture(home: home, support: support, target: Data("target".utf8), settings: settings, conversation: conversation)
}

private func writeActive(_ profile: String, home: URL) throws {
    let config = home.appendingPathComponent(".aisw/config.json")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["active": ["antigravity": profile]]).write(to: config)
}

private func bridgeVersion() -> BridgeExecutionResult {
    BridgeExecutionResult(exitCode: 0, standardOutput: #"{"version":"0.3.8","cli_api_version":1,"antigravity_credential_only":true}"#)
}

private func readText(_ url: URL) -> String? { try? String(contentsOf: url) }
