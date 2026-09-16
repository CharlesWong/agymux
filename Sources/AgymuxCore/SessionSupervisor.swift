import Darwin
import Foundation

public final class SessionSupervisor: Sendable {
    public static let shared = SessionSupervisor()

    private let concurrencyGuard = ConcurrencyGuard.shared
    private let poolManager = PoolManager.shared
    private let quotaBroker = QuotaBroker.shared
    private let keychainClient = KeychainClient.shared
    private let managedAgyLauncherPath: String

    public init(managedAgyLauncherPath: String = ManagedAgyLaunch.installedLauncherPath) {
        self.managedAgyLauncherPath = managedAgyLauncherPath
    }

    /// Executes `agy` with full supervision, automatically migrating to a new profile if quota runs out.
    public func runSupervised(
        realAgyPath: String,
        initialProfile: String,
        arguments: [String],
        strategy: QuotaStrategy,
        requestedModel: String?,
        entrySignalState: ExecSignalState
    ) async throws -> Int32 {
        let isInteractive = !arguments.contains("-p") && !arguments.contains("--print")
        if isInteractive && isatty(STDIN_FILENO) != 0 {
            let launch = try ManagedAgyLaunch(
                realAgyPath: realAgyPath,
                profileName: initialProfile,
                officialArguments: arguments,
                launcherPath: managedAgyLauncherPath
            )
            // Interactive terminal mode: activate profile, register PID, then exec the
            // switchboard handoff so terminal raw mode, colors, cursor, and signals work natively.
            try await keychainClient.activateProfile(initialProfile)

            var detectedConvId: String?
            for (i, arg) in arguments.enumerated() {
                if arg == "--conversation", i + 1 < arguments.count {
                    detectedConvId = arguments[i + 1]
                } else if arg.hasPrefix("--conversation=") {
                    detectedConvId = String(arg.dropFirst("--conversation=".count))
                }
            }
            if detectedConvId == nil && (arguments.contains("-c") || arguments.contains("--continue")) {
                detectedConvId = detectLatestConversationId()
            }

            try? concurrencyGuard.registerSession(
                pid: getpid(),
                profileName: initialProfile,
                conversationId: detectedConvId,
                cwd: FileManager.default.currentDirectoryPath,
                arguments: arguments
            )

            if let convId = detectedConvId ?? detectLatestConversationId() {
                ConversationStickinessStore.shared.recordUsage(
                    conversationId: convId,
                    profileName: initialProfile,
                    model: requestedModel ?? "gemini-3.8-flash-high"
                )
            }

            try execDirect(launch, entrySignalState: entrySignalState)
        }

        var currentProfile = initialProfile
        var currentArgs = arguments
        var attempts = 0
        let maxMigrations = 4

        var lastFailedOutput: Data?

        while attempts < maxMigrations {
            attempts += 1

            // Resolve the switchboard handoff before changing credentials, so a
            // missing launcher cannot leave the selected profile changed without a launch.
            let launch = try ManagedAgyLaunch(
                realAgyPath: realAgyPath,
                profileName: currentProfile,
                officialArguments: currentArgs,
                launcherPath: managedAgyLauncherPath
            )

            // 1. Activate selected profile in Keychain
            try await keychainClient.activateProfile(currentProfile)

            // 2. Launch child process
            let (exitCode, conversationId, quotaExhausted, outputData) = try await spawnChild(
                launch: launch,
                profileName: currentProfile,
                arguments: currentArgs,
                requestedModel: requestedModel
            )
            lastFailedOutput = outputData

            // 3. If exit was clean or not due to quota wall, finish
            if !quotaExhausted || exitCode == 0 {
                return exitCode
            }

            // 4. Handle Quota Wall Migration
            fputs("\n\u{001B}[1;33m[agymux] Profile '\(currentProfile)' hit quota limit.\u{001B}[0m\n", stderr)

            // Find conversation ID to resume
            let resolvedConversationId = conversationId ?? detectLatestConversationId()
            fputs("\u{001B}[1;36m[agymux] Preparing seamless migration for conversation \(resolvedConversationId ?? "latest")…\u{001B}[0m\n", stderr)

            let config = poolManager.loadConfig()
            let candidates = config.auto.filter { $0 != currentProfile }
            let quotas = await quotaBroker.fetchAllQuotas(profileNames: candidates)
            let threads = concurrencyGuard.allActiveThreadCounts()

            var candidateBest = QuotaStrategies.selectBestProfile(
                candidates: candidates,
                quotas: quotas,
                activeThreads: threads,
                maxSlotsPerProfile: config.maxActiveThreadsPerProfile,
                requestedModel: requestedModel,
                currentlyActive: currentProfile,
                strategy: strategy
            )

            if candidateBest == nil || candidateBest?.isEligible != true {
                // Auto pool depleted or at capacity - check configurable fallback to reserved pool
                let fallbackMode = config.reservedFallbackMode.lowercased()
                let reservedCandidates = config.reserved.filter { $0 != currentProfile }

                if !reservedCandidates.isEmpty {
                    let resQuotas = await quotaBroker.fetchAllQuotas(profileNames: reservedCandidates)
                    let bestReserved = QuotaStrategies.selectBestProfile(
                        candidates: reservedCandidates,
                        quotas: resQuotas,
                        activeThreads: threads,
                        maxSlotsPerProfile: config.maxActiveThreadsPerProfile,
                        requestedModel: requestedModel,
                        currentlyActive: currentProfile,
                        strategy: strategy
                    )

                    if let br = bestReserved, br.isEligible {
                        if fallbackMode == "auto" {
                            fputs("\u{001B}[1;33m[agymux] Auto Pool depleted or at capacity; auto-fallback to reserved profile '\(br.profileName)'.\u{001B}[0m\n", stderr)
                            candidateBest = br
                        } else if fallbackMode == "prompt" && isatty(STDIN_FILENO) != 0 {
                            let emailLabel = poolManager.email(for: br.profileName).map { " (\($0))" } ?? ""
                            fputs("\n\u{001B}[1;33m[agymux] All Auto Pool profiles are depleted or at capacity.\u{001B}[0m\n", stderr)
                            fputs("\u{001B}[1;36m[agymux] Unlock reserved profile '\(br.profileName)'\(emailLabel) to continue? [y/N]: \u{001B}[0m", stderr)
                            fflush(stderr)

                            if let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                               line == "y" || line == "yes" {
                                candidateBest = br
                            }
                        }
                    }
                }
            }

            guard let best = candidateBest, best.isEligible else {
                fputs("\u{001B}[1;31m[agymux] No available profile has sufficient quota (>5%) or free capacity.\u{001B}[0m\n", stderr)
                if let lastData = lastFailedOutput {
                    FileHandle.standardOutput.write(lastData)
                }
                return exitCode
            }

            fputs("\u{001B}[1;32m[agymux] Resuming session on '\(best.profileName)' (\(Int(best.quotaRemaining * 100))% quota remaining)…\u{001B}[0m\n", stderr)

            // 6. Update session reservation & arguments for resume
            currentProfile = best.profileName
            try? concurrencyGuard.registerSession(
                pid: getpid(),
                profileName: currentProfile,
                conversationId: resolvedConversationId,
                cwd: FileManager.default.currentDirectoryPath,
                arguments: currentArgs
            )
            if let convId = resolvedConversationId {
                ConversationStickinessStore.shared.recordUsage(
                    conversationId: convId,
                    profileName: best.profileName,
                    model: requestedModel ?? "gemini-3.8-flash-high"
                )
            }
            currentArgs = Self.rewriteArgumentsForResume(arguments: currentArgs, conversationId: resolvedConversationId)
        }

        if let lastData = lastFailedOutput {
            FileHandle.standardOutput.write(lastData)
        }
        return 1
    }

    private func execDirect(_ launch: ManagedAgyLaunch, entrySignalState: ExecSignalState) throws -> Never {
        // Replacing from a Swift worker must restore the shell's signal mask
        // atomically. Raw execv would carry blocked SIGTTIN into AGY and turn a
        // background terminal read into EIO instead of normal job control.
        try entrySignalState.replaceProcess(
            executable: launch.launcherPath,
            arguments: launch.arguments,
            environment: launch.environment()
        )
    }

    private func spawnChild(
        launch: ManagedAgyLaunch,
        profileName: String,
        arguments: [String],
        requestedModel: String?
    ) async throws -> (exitCode: Int32, conversationId: String?, quotaExhausted: Bool, outputData: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.launcherPath)
        process.arguments = launch.arguments
        process.environment = launch.environment()
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Capture initial conversation id if passed in arguments
        var detectedConvId: String?
        for (i, arg) in arguments.enumerated() {
            if arg == "--conversation", i + 1 < arguments.count {
                detectedConvId = arguments[i + 1]
            } else if arg.hasPrefix("--conversation=") {
                detectedConvId = String(arg.dropFirst("--conversation=".count))
            }
        }

        // Non-interactive / print mode: capture stdout/stderr to detect quota messages
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let childPid = process.processIdentifier

        let parentAlreadyRegistered = concurrencyGuard.activeSessions().contains { $0.pid == Darwin.getpid() }
        if !parentAlreadyRegistered {
            try? concurrencyGuard.registerSession(
                pid: childPid,
                profileName: profileName,
                conversationId: detectedConvId,
                cwd: FileManager.default.currentDirectoryPath,
                arguments: arguments
            )
        }
        defer {
            if !parentAlreadyRegistered {
                concurrencyGuard.unregisterSession(pid: childPid)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outputText = String(decoding: data, as: UTF8.self)
        let hasQuotaError = outputText.contains("RESOURCE_EXHAUSTED")
            || outputText.contains("Quota exceeded")
            || outputText.contains("exhausted your 5-hour quota")
            || outputText.contains("Your quota will reset in")
            || outputText.contains("rate limit reached")

        // Only forward output immediately if there was NO quota error
        // If quota failed, the supervisor will migrate to the next profile
        if !hasQuotaError {
            FileHandle.standardOutput.write(data)
        }

        return (process.terminationStatus, detectedConvId, hasQuotaError, data)
    }

    /// Detects the newest conversation ID across ~/.gemini/antigravity-cli/
    private func detectLatestConversationId() -> String? {
        ConversationStickinessStore.shared.detectLatestConversationId()
    }

    /// Rewrites arguments for session resumption/migration cleanly without dangling or duplicated options.
    public static func rewriteArgumentsForResume(arguments: [String], conversationId: String?) -> [String] {
        guard let convId = conversationId else {
            if !arguments.contains("-c") && !arguments.contains("--continue") {
                return ["-c"] + arguments
            }
            return arguments
        }

        var newArgs: [String] = []
        var skipNext = false
        for (index, arg) in arguments.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "-c" || arg == "--continue" {
                continue
            }
            if arg == "--conversation" {
                if index + 1 < arguments.endIndex {
                    skipNext = true
                }
                continue
            }
            if arg.hasPrefix("--conversation=") {
                continue
            }
            newArgs.append(arg)
        }
        return ["--conversation", convId] + newArgs
    }
}
