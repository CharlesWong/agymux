import Foundation
import Darwin
import Testing
@testable import AgymuxCore

struct ManagedAgyLaunchTests {
    @Test func streamInputDeliversExactBytesAndEOFToChildWhilePrintReceivesNoInput() throws {
        let frame = Data("{\"event\":\"user\",\"message\":{\"content\":\"fictional pipe test\"}}\n".utf8)
        for (arguments, expected) in [(["--input-format", "stream-json", "--print="], frame), (["--print=fictional prompt"], Data())] {
            let launch = try ManagedAgyLaunch(realAgyPath: "/bin/cat", profileName: "fictional", officialArguments: arguments, launcherPath: "/bin/cat")
            let input = Pipe()
            let output = Pipe()
            try input.fileHandleForWriting.write(contentsOf: frame)
            try input.fileHandleForWriting.close()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            launch.configurePrintIO(child, capture: output, input: input.fileHandleForReading, output: output.fileHandleForWriting, error: .nullDevice)
            try child.run()
            try? output.fileHandleForWriting.close()
            let actual = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            #expect(child.terminationStatus == 0)
            #expect(actual == expected)
            try input.fileHandleForReading.close()
            try output.fileHandleForReading.close()
        }
    }
    @Test func streamDriverReceivesReadyAndResponseBeforeClosingItsInput() throws {
        let launch = try ManagedAgyLaunch(realAgyPath: "/bin/sh", profileName: "fictional", officialArguments: ["--input-format=stream-json", "--print="], launcherPath: "/bin/sh")
        let input = Pipe(), output = Pipe(), capture = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf 'ready\\n'; IFS= read -r frame; printf '%s\\n' \"$frame\"; cat >/dev/null"]
        launch.configurePrintIO(child, capture: capture, input: input.fileHandleForReading, output: output.fileHandleForWriting, error: .nullDevice)
        try child.run()
        try output.fileHandleForWriting.close()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() }; try? input.fileHandleForWriting.close() }
        func readAvailable(_ count: Int) throws -> Data {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2000) == 1 else { throw NSError(domain: "StreamIOTest", code: 1) }
            return output.fileHandleForReading.readData(ofLength: count)
        }
        #expect(try readAvailable(6) == Data("ready\n".utf8))
        let frame = Data("fictional frame\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: frame)
        #expect(try readAvailable(frame.count) == frame)
        #expect(child.isRunning)
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
    }
    @Test func streamInputRecognizesOptionsWithoutConsumingPromptLiterals() throws {
        let cases: [([String], Bool)] = [
            (["--print=", "--input-format", "stream-json"], true),
            (["--input-format=stream-json", "--print="], true),
            (["--input-format", "stream-json", "--input-format=text", "--print="], false),
            (["--print=", "--input-format", "text"], false),
            (["--print", "--input-format=stream-json"], false),
            (["-p", "--input-format", "stream-json"], false),
            (["--", "--input-format=stream-json"], false),
            (["a positional prompt", "--input-format", "stream-json"], false),
            (["--model", "fake", "--input-format", "stream-json", "--print="], true),
        ]
        for (arguments, expected) in cases {
            let launch = try ManagedAgyLaunch(realAgyPath: "/usr/bin/true", profileName: "fictional", officialArguments: arguments, launcherPath: "/usr/bin/true")
            #expect(launch.usesStreamJSONInput == expected)
        }
    }
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
