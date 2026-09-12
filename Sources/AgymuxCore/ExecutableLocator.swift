import Foundation

public enum ExecutableLocator {
    public static func find(_ name: String, extraPaths: [String] = []) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

        var candidates: [String] = extraPaths
        if let custom = ProcessInfo.processInfo.environment["AGY_SWITCHER_REAL_AGY"], name == "agy" {
            candidates.append(custom)
        }
        if name == "aisw" {
            candidates.append("\(home)/Library/Application Support/AgySwitcher/bin/aisw-switchboard")
            candidates.append("/Volumes/External/dev/common/agentfusion/switcher/Vendor/aisw-switchboard")
            candidates.append("/opt/homebrew/bin/aisw-switchboard")
            candidates.append("/usr/local/bin/aisw-switchboard")
            candidates.append("\(home)/.local/bin/aisw-switchboard")
        }

        let standardPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        candidates.append(contentsOf: standardPaths)

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: pathEnv.split(separator: ":").map { "\($0)/\(name)" })
        }

        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard resolved != currentExecutable, fileManager.isExecutableFile(atPath: resolved) else {
                continue
            }
            return resolved
        }
        return nil
    }
}
