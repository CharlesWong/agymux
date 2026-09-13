import Foundation
import Testing
@testable import AgymuxCore

struct ManagedAgyLaunchTests {
    @Test func buildsSwitchboardCommandAndBoundEnvironmentWithoutChangingOfficialArguments() throws {
        let fixture = try launcherFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let officialArguments = ["-c", "--conversation", "conversation-42", "--model", "flash"]
        let launch = try ManagedAgyLaunch(
            realAgyPath: "/opt/agy/agy",
            profileName: "work",
            officialArguments: officialArguments,
            launcherPath: fixture.launcher.path
        )

        #expect(launch.launcherPath == fixture.launcher.path)
        #expect(launch.arguments == ["run", "--", "--dangerously-skip-permissions", "-c", "--conversation", "conversation-42", "--model", "flash"])
        #expect(launch.officialArguments == officialArguments)
        #expect(launch.environment(inheriting: ["PATH": "/usr/bin", "KEEP": "yes"]) == [
            "PATH": "/usr/bin",
            "KEEP": "yes",
            "AGY_SWITCHER_EXPECTED_PROFILE": "work",
            "AGY_SWITCHER_REAL_AGY": "/opt/agy/agy",
            "AGY_SWITCHER_LAUNCH_SOURCE": "agyx"
        ])
    }

    @Test func failsBeforeActivationWhenInstalledLauncherIsUnavailable() {
        #expect(throws: ManagedAgyLaunchError.launcherUnavailable("/missing/agyctl")) {
            try ManagedAgyLaunch(
                realAgyPath: "/opt/agy/agy",
                profileName: "work",
                officialArguments: ["--print"],
                launcherPath: "/missing/agyctl"
            )
        }
    }

    @Test func insertsBypassFlagBeforeTheOfficialArgumentDelimiter() throws {
        let fixture = try launcherFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let launch = try ManagedAgyLaunch(
            realAgyPath: "/opt/agy/agy",
            profileName: "work",
            officialArguments: ["--print", "--", "prompt beginning with dashes"],
            launcherPath: fixture.launcher.path
        )

        #expect(launch.arguments == [
            "run", "--", "--dangerously-skip-permissions", "--print", "--", "prompt beginning with dashes"
        ])
    }

    @Test func doesNotDuplicateAnExplicitBypassFlag() throws {
        let fixture = try launcherFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let launch = try ManagedAgyLaunch(
            realAgyPath: "/opt/agy/agy",
            profileName: "work",
            officialArguments: ["-c", "--dangerously-skip-permissions", "--", "prompt"],
            launcherPath: fixture.launcher.path
        )

        #expect(launch.arguments.filter { $0 == "--dangerously-skip-permissions" }.count == 1)
        #expect(launch.arguments == ["run", "--", "--dangerously-skip-permissions", "-c", "--", "prompt"])
    }

    @Test func normalizesFalseBypassFlagWithoutChangingDelimiterPrompt() throws {
        let fixture = try launcherFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let launch = try ManagedAgyLaunch(
            realAgyPath: "/opt/agy/agy",
            profileName: "work",
            officialArguments: [
                "--dangerously-skip-permissions=false", "--print", "--", "--dangerously-skip-permissions=false"
            ],
            launcherPath: fixture.launcher.path
        )

        #expect(launch.arguments == [
            "run", "--", "--dangerously-skip-permissions", "--print", "--", "--dangerously-skip-permissions=false"
        ])
    }

    @Test func preservesFlagLookingPrintPromptOperand() throws {
        let launch = try launchFixture(arguments: ["-p", "--dangerously-skip-permissions=false"])

        #expect(launch.arguments == [
            "run", "--", "--dangerously-skip-permissions", "-p", "--dangerously-skip-permissions=false"
        ])
    }

    @Test func prependsBypassFlagBeforePlainPositionalPrompt() throws {
        let launch = try launchFixture(arguments: ["plain prompt"])

        #expect(launch.arguments == ["run", "--", "--dangerously-skip-permissions", "plain prompt"])
    }

    @Test func normalizesFalseOptionBeforePrintPrompt() throws {
        let launch = try launchFixture(arguments: [
            "--dangerously-skip-permissions=false", "-p", "prompt"
        ])

        #expect(launch.arguments == ["run", "--", "--dangerously-skip-permissions", "-p", "prompt"])
    }

    private func launchFixture(arguments: [String]) throws -> ManagedAgyLaunch {
        let fixture = try launcherFixture()
        // Construction checks the executable; inspecting the launch descriptor
        // afterwards does not require keeping the fixture on disk.
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        return try ManagedAgyLaunch(
            realAgyPath: "/opt/agy/agy",
            profileName: "work",
            officialArguments: arguments,
            launcherPath: fixture.launcher.path
        )
    }

    private func launcherFixture() throws -> (folder: URL, launcher: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedAgyLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = folder.appendingPathComponent("agyctl")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return (folder, launcher)
    }
}
