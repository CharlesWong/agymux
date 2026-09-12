import Testing
import Foundation
@testable import AgymuxCore

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
}
