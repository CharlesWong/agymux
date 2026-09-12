import Testing
import Foundation
@testable import AgymuxCore

@Suite("ConcurrencyGuard Tests")
struct ConcurrencyGuardTests {
    @Test("Registration and unregistration tracks active sessions")
    func testSessionRegistration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let guardInstance = ConcurrencyGuard(sessionsDirectory: tempDir)

        // Register current process PID
        let currentPid = ProcessInfo.processInfo.processIdentifier
        try guardInstance.registerSession(
            pid: currentPid,
            profileName: "quavolve",
            conversationId: "test-conv-123",
            cwd: "/tmp",
            arguments: ["run"]
        )

        let sessions = guardInstance.activeSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == currentPid)
        #expect(sessions.first?.profileName == "quavolve")
        #expect(guardInstance.activeThreadCount(for: "quavolve") == 1)
        #expect(guardInstance.activeThreadCount(for: "other") == 0)

        guardInstance.unregisterSession(pid: currentPid)
        #expect(guardInstance.activeSessions().isEmpty)
    }

    @Test("Pruner cleans up non-existent PIDs")
    func testPrunerRemovesDeadPids() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let guardInstance = ConcurrencyGuard(sessionsDirectory: tempDir)

        // Fabricate a record with an impossible high PID (e.g. 9999999)
        let fakePid: Int32 = 9999999
        let record = SessionRecord(
            pid: fakePid,
            profileName: "dead_profile",
            conversationId: nil,
            startedAt: .now,
            cwd: "/tmp",
            arguments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: tempDir.appendingPathComponent("\(fakePid).json"))

        let pruned = guardInstance.pruneStaleSessions()
        #expect(pruned == 1)
        #expect(guardInstance.activeSessions().isEmpty)
    }
}
