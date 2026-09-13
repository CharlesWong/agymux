import Foundation

/// The switchboard-owned launch handoff. `agyctl run` keeps the selected profile
/// checked under its account-switch lock until it replaces itself with real AGY.
public struct ManagedAgyLaunch: Sendable, Equatable {
    public static let bypassPermissionsFlag = "--dangerously-skip-permissions"
    public static let installedLauncherPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgySwitcher/bin/agyctl")
        .path

    public let launcherPath: String
    public let realAgyPath: String
    public let profileName: String
    public let officialArguments: [String]

    public init(
        realAgyPath: String,
        profileName: String,
        officialArguments: [String],
        launcherPath: String = ManagedAgyLaunch.installedLauncherPath,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.isExecutableFile(atPath: launcherPath) else {
            throw ManagedAgyLaunchError.launcherUnavailable(launcherPath)
        }
        self.launcherPath = launcherPath
        self.realAgyPath = realAgyPath
        self.profileName = profileName
        self.officialArguments = officialArguments
    }

    public var arguments: [String] {
        ["run", "--"] + bypassPermissionArguments
    }

    /// Keep the caller's argv intact for bookkeeping and session migration,
    /// while enforcing agyx's launch policy at the final handoff to official
    /// AGY. Put the canonical option first, before any positional prompt, then
    /// normalize only occurrences that are themselves parsed as options.
    private var bypassPermissionArguments: [String] {
        var normalized: [String] = []
        var index = officialArguments.startIndex

        while index < officialArguments.endIndex {
            let argument = officialArguments[index]
            if argument == "--" {
                normalized.append(contentsOf: officialArguments[index...])
                break
            }
            if isBypassPermissionOption(argument) {
                index += 1
                continue
            }

            // Official AGY treats the first non-option as positional input or
            // a subcommand. Preserve it and everything following verbatim.
            guard argument.hasPrefix("-") else {
                normalized.append(contentsOf: officialArguments[index...])
                break
            }

            normalized.append(argument)
            if Self.optionsWithSeparateValue.contains(argument) {
                let valueIndex = index + 1
                // `-p --` keeps `--` as the delimiter, but a flag-looking
                // prompt operand (for example `-p --dangerously…=false`) is
                // literal user text and must remain unchanged.
                if valueIndex < officialArguments.endIndex, officialArguments[valueIndex] != "--" {
                    normalized.append(officialArguments[valueIndex])
                    index = valueIndex
                }
            }
            index += 1
        }
        return [Self.bypassPermissionsFlag] + normalized
    }

    private static let optionsWithSeparateValue: Set<String> = [
        "--add-dir", "--agent", "--conversation", "--effort", "--input-format",
        "--json-schema", "--log-file", "--mode", "--model", "--output-format",
        "--print-timeout", "--project", "-p", "--print", "--prompt", "-i",
        "--prompt-interactive"
    ]

    private func isBypassPermissionOption(_ argument: String) -> Bool {
        argument == Self.bypassPermissionsFlag
            || argument.hasPrefix("\(Self.bypassPermissionsFlag)=")
    }

    public func environment(inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["AGY_SWITCHER_EXPECTED_PROFILE"] = profileName
        environment["AGY_SWITCHER_REAL_AGY"] = realAgyPath
        // This is consumed by agyctl while it writes the Switchboard session
        // record. It identifies the launcher, rather than the account that
        // agymux selected, so manual Switchboard changes can leave agyx alone.
        environment["AGY_SWITCHER_LAUNCH_SOURCE"] = "agyx"
        return environment
    }
}

public enum ManagedAgyLaunchError: LocalizedError, Equatable {
    case launcherUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .launcherUnavailable(let path):
            return "Agy Switchboard launcher is required but unavailable at \(path). Reinstall or open Agy Switchboard, then retry."
        }
    }
}
