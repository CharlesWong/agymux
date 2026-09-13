import Darwin
import Foundation

public final class SessionSupervisor: Sendable {
    public static let shared = SessionSupervisor()

    private let concurrencyGuard = ConcurrencyGuard.shared
    private let poolManager = PoolManager.shared
    private let quotaBroker = QuotaBroker.shared
    private let keychainClient = KeychainClient.shared

    public init() {}

    /// Executes `agy` with full supervision, automatically migrating to a new profile if quota runs out.
    public func runSupervised(
        realAgyPath: String,
        initialProfile: String,
        arguments: [String],
        strategy: QuotaStrategy,
        requestedModel: String?
    ) async throws -> Int32 {
        let isInteractive = !arguments.contains("-p") && !arguments.contains("--print")
        if isInteractive && isatty(STDIN_FILENO) != 0 {
            // Interactive terminal mode: activate profile, register PID, and execv directly
            // so terminal raw mode, colors, cursor, events, and signals work natively.
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

            execDirect(realAgyPath: realAgyPath, arguments: arguments)
        }

        var currentProfile = initialProfile
        var currentArgs = arguments
        var attempts = 0
        let maxMigrations = 4

        var lastFailedOutput: Data?

        while attempts < maxMigrations {
            attempts += 1

            // 1. Activate selected profile in Keychain
            try await keychainClient.activateProfile(currentProfile)

            // 2. Launch child process
            let (exitCode, conversationId, quotaExhausted, outputData) = try await spawnChild(
                realAgyPath: realAgyPath,
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

            if candidateBest == nil || (candidateBest?.quotaRemaining ?? 0.0) < 0.05 {
                // Auto pool depleted - check configurable fallback to reserved pool
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

                    if let br = bestReserved, br.quotaRemaining >= 0.05 {
                        if fallbackMode == "auto" {
                            fputs("\u{001B}[1;33m[agymux] Auto Pool depleted; auto-fallback to reserved profile '\(br.profileName)'.\u{001B}[0m\n", stderr)
                            candidateBest = br
                        } else if fallbackMode == "prompt" && isatty(STDIN_FILENO) != 0 {
                            let emailLabel = poolManager.email(for: br.profileName).map { " (\($0))" } ?? ""
                            fputs("\n\u{001B}[1;33m[agymux] All Auto Pool profiles are depleted.\u{001B}[0m\n", stderr)
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

            guard let best = candidateBest, best.quotaRemaining >= 0.05 else {
                fputs("\u{001B}[1;31m[agymux] No available profile has sufficient quota (>5%).\u{001B}[0m\n", stderr)
                if let lastData = lastFailedOutput {
                    FileHandle.standardOutput.write(lastData)
                }
                return exitCode
            }

            fputs("\u{001B}[1;32m[agymux] Resuming session on '\(best.profileName)' (\(Int(best.quotaRemaining * 100))% quota remaining)…\u{001B}[0m\n", stderr)

            // 6. Update arguments for resume
            currentProfile = best.profileName
            if let convId = resolvedConversationId {
                ConversationStickinessStore.shared.recordUsage(
                    conversationId: convId,
                    profileName: best.profileName,
                    model: requestedModel ?? "gemini-3.8-flash-high"
                )
                var newArgs = currentArgs.filter {
                    $0 != "-c" && $0 != "--continue" && !$0.hasPrefix("--conversation")
                }
                newArgs.insert(contentsOf: ["--conversation", convId], at: 0)
                currentArgs = newArgs
            } else if !currentArgs.contains("-c") && !currentArgs.contains("--continue") {
                currentArgs.insert("-c", at: 0)
            }
        }

        if let lastData = lastFailedOutput {
            FileHandle.standardOutput.write(lastData)
        }
        return 1
    }

    private func execDirect(realAgyPath: String, arguments: [String]) -> Never {
        let strings: [UnsafeMutablePointer<CChar>?] = ([realAgyPath] + arguments).map { strdup($0) } + [nil]
        defer { strings.compactMap { $0 }.forEach { free($0) } }
        strings.withUnsafeBufferPointer { buffer in
            _ = execv(realAgyPath, UnsafeMutablePointer(mutating: buffer.baseAddress))
        }
        fputs("agymux: could not exec \(realAgyPath): \(String(cString: strerror(errno)))\n", stderr)
        Darwin.exit(126)
    }

    private func spawnChild(
        realAgyPath: String,
        profileName: String,
        arguments: [String],
        requestedModel: String?
    ) async throws -> (exitCode: Int32, conversationId: String?, quotaExhausted: Bool, outputData: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: realAgyPath)
        process.arguments = arguments
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

        try? concurrencyGuard.registerSession(
            pid: childPid,
            profileName: profileName,
            conversationId: detectedConvId,
            cwd: FileManager.default.currentDirectoryPath,
            arguments: arguments
        )
        defer {
            concurrencyGuard.unregisterSession(pid: childPid)
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
}
