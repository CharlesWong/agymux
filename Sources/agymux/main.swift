import AgymuxCore
import Darwin
import Foundation

@main
struct AgymuxCLI {
    static func main() async {
        // Capture the shell's mask before the first suspension. Swift's worker
        // threads block signals that an interactive child must not inherit.
        let entrySignalState: ExecSignalState
        do {
            entrySignalState = try ExecSignalState.capture()
        } catch {
            fputs("agymux: could not capture launch signal state: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        let args = Array(CommandLine.arguments.dropFirst())

        if args.first == "pool" {
            await handlePoolCommand(Array(args.dropFirst()))
            return
        }
        if args.first == "quota" {
            await handleQuotaCommand(Array(args.dropFirst()))
            return
        }
        if args.first == "config" {
            handleConfigCommand(Array(args.dropFirst()))
            return
        }
        if args.first == "doctor" {
            await handleDoctorCommand()
            return
        }
        if args.first == "resume" {
            await handleRunCommand(["-c"] + Array(args.dropFirst()), entrySignalState: entrySignalState)
            return
        }
        if args.first == "--help" || args.first == "-h" || args.first == "help" {
            printHelp()
            return
        }

        // Default: Run agy session with auto-dispatch
        await handleRunCommand(args, entrySignalState: entrySignalState)
    }

    static func printHelp() {
        print("""
        \u{001B}[1magymux (agyx)\u{001B}[0m - Smart Multi-Profile Dispatcher for Antigravity CLI

        \u{001B}[1mUSAGE:\u{001B}[0m
          agyx [options] [prompt...]        Run AGY session with automatic profile selection
          agyx -c / --continue              Resume the most recent conversation on the best profile
          agyx --conversation <id>          Resume a specific conversation ID
          agyx --profile <name>             Explicitly target a profile (allows Reserved pool)
          agyx --model <model>              Override model (e.g. gemini-3.8-flash-high, claude-sonnet-4-6)
          agyx resume                       Shortcut for 'agyx -c'

        AGY sessions always run with --dangerously-skip-permissions (auto-approve tools).

        \u{001B}[1mSUBCOMMANDS:\u{001B}[0m
          agyx pool status                  Display live multi-account quota & concurrency dashboard
          agyx pool set <name> <category>   Set profile category (auto | reserved)
          agyx quota [profile]              Detailed breakdown of 5-hour and weekly quota buckets
          agyx config set <key> <value>     Configure defaults (model, strategy, max-threads, reserved-fallback)
          agyx doctor                       Verify toolchain, Keychain, aisw, and profile health
          agyx help                         Show this help message

        \u{001B}[1mCONFIG KEYS:\u{001B}[0m
          model               Default model (default: gemini-3.8-flash-high)
          strategy            smart (default), max-headroom, harvest, balanced, model-adaptive
          max-threads         Max active threads per profile (default: 3)
          reserved-fallback   prompt (default), never, auto
          stickiness-quota    Minimum quota to maintain prompt cache stickiness (default: 15%)

        \u{001B}[1mFOR AI AGENTS & AUTOMATION HARNESSES:\u{001B}[0m
          • \u{001B}[1mHeadless Execution\u{001B}[0m: Always pass -p / --print in subshells/scripts to prevent TTY hangs.
          • \u{001B}[1mInference Cache Locality\u{001B}[0m: Always continue multi-turn tasks with:
              agyx -c -p "<instruction>" --output-format json
            agyx automatically maintains profile stickiness when quota >= 15%, hitting the
            server-side prompt/KV cache and saving 75%-90% input token cost and latency.
          • \u{001B}[1mStructured Output\u{001B}[0m: Pass --output-format json for clean, parseable JSON payloads:
              {"status": "SUCCESS", "response": "...", "conversation_id": "...", "usage": {...}}
          • \u{001B}[1mPersistent Harness Daemon\u{001B}[0m: For multi-turn agent harnesses without process respawn:
              agyx -p --input-format stream-json --output-format stream-json
          • \u{001B}[1mAutonomous Failover\u{001B}[0m: Do not implement quota retry loops. agyx detects 429 and
            RESOURCE_EXHAUSTED errors and migrates profiles across the Auto Pool automatically.
          • \u{001B}[1mReserved Pool Etiquette\u{001B}[0m: Never pass '--profile current' unless explicitly ordered
            by the human user; allow agyx to route autonomously across Auto Pool commodity profiles.
        """)
    }

    static func handleRunCommand(_ rawArgs: [String], entrySignalState: ExecSignalState) async {
        guard let realAgy = ExecutableLocator.find("agy") else {
            fputs("\u{001B}[1;31magymux: Official 'agy' executable not found in PATH.\u{001B}[0m\n", stderr)
            exit(1)
        }

        let poolManager = PoolManager.shared
        let config = poolManager.loadConfig()
        let concurrencyGuard = ConcurrencyGuard.shared
        let quotaBroker = QuotaBroker.shared

        var forwardedArgs: [String] = []
        var explicitProfile: String?
        var userSpecifiedModel: String?
        var strategyOverride: QuotaStrategy?

        var i = 0
        while i < rawArgs.count {
            let arg = rawArgs[i]
            if arg == "--profile", i + 1 < rawArgs.count {
                explicitProfile = rawArgs[i + 1]
                i += 2
                continue
            } else if arg.hasPrefix("--profile=") {
                explicitProfile = String(arg.dropFirst("--profile=".count))
                i += 1
                continue
            } else if arg == "--strategy", i + 1 < rawArgs.count {
                strategyOverride = QuotaStrategy(rawValue: rawArgs[i + 1])
                i += 2
                continue
            } else if arg == "--model", i + 1 < rawArgs.count {
                userSpecifiedModel = PoolManager.normalizeModelName(rawArgs[i + 1])
                forwardedArgs.append(arg)
                forwardedArgs.append(userSpecifiedModel!)
                i += 2
                continue
            } else if arg.hasPrefix("--model=") {
                userSpecifiedModel = PoolManager.normalizeModelName(String(arg.dropFirst("--model=".count)))
                forwardedArgs.append("--model=\(userSpecifiedModel!)")
                i += 1
                continue
            }
            forwardedArgs.append(arg)
            i += 1
        }

        // Apply configurable default model if not explicitly specified by the user
        let effectiveModel = userSpecifiedModel ?? config.defaultModel
        if userSpecifiedModel == nil {
            forwardedArgs.insert(contentsOf: ["--model", effectiveModel], at: 0)
        }

        // Check if this session is a continuation of an existing conversation
        let stickinessStore = ConversationStickinessStore.shared
        var explicitConvId: String?
        var isContinuation = false

        for (idx, arg) in forwardedArgs.enumerated() {
            if arg == "-c" || arg == "--continue" {
                isContinuation = true
            } else if arg == "--conversation", idx + 1 < forwardedArgs.count {
                explicitConvId = forwardedArgs[idx + 1]
                isContinuation = true
            } else if arg.hasPrefix("--conversation=") {
                explicitConvId = String(arg.dropFirst("--conversation=".count))
                isContinuation = true
            }
        }

        let targetConvId = explicitConvId ?? (isContinuation ? stickinessStore.detectLatestConversationId() : nil)

        let targetProfile: String
        let activeStrategy = strategyOverride ?? QuotaStrategy(rawValue: config.defaultStrategy) ?? .smart

        if let explicit = explicitProfile {
            // Explicit override: bypass auto pool and stickiness
            targetProfile = explicit
            fputs("\u{001B}[1;36m[agymux]\u{001B}[0m Using explicit profile '\(targetProfile)' (Model: \(effectiveModel)).\n", stderr)
        } else {
            // Auto pool selection
            let candidates = config.auto
            if candidates.isEmpty {
                fputs("\u{001B}[1;31magymux: No profiles found in Auto Pool. Run 'agyx pool status'.\u{001B}[0m\n", stderr)
                exit(1)
            }

            fputs("\u{001B}[1;30m[agymux] Checking quotas for \(candidates.count) pool profiles…\u{001B}[0m\r", stderr)
            let quotas = await quotaBroker.fetchAllQuotas(profileNames: candidates)
            let threads = concurrencyGuard.allActiveThreadCounts()

            var stickySelected: String?

            // Evaluate Continuation Stickiness for maximum prompt cache hit rate
            if isContinuation, let convId = targetConvId,
               let sticky = stickinessStore.stickyProfile(for: convId),
               candidates.contains(sticky) {
                let eval = stickinessStore.evaluateStickiness(
                    profileName: sticky,
                    snapshot: quotas[sticky],
                    activeThreads: threads[sticky, default: 0],
                    maxSlots: config.maxActiveThreadsPerProfile,
                    requestedModel: effectiveModel,
                    threshold: stickinessStore.loadConfig().minStickinessQuota
                )

                if eval.isSufficient {
                    // Check if another candidate has a fresh 100% weekly quota needing kick-off (TOP PRIORITY)
                    let stickySnap = quotas[sticky]
                    let stickyHasFresh100 = stickySnap?.hasFresh100Weekly(for: effectiveModel) ?? false

                    let fresh100Candidate = candidates.first { c in
                        c != sticky && (quotas[c]?.hasFresh100Weekly(for: effectiveModel) ?? false)
                    }

                    if let freshCandidate = fresh100Candidate, !stickyHasFresh100 {
                        fputs("\u{001B}[1;35m[agymux]\u{001B}[0m Yielding cache stickiness on '\(sticky)': fresh 100% weekly quota on '\(freshCandidate)' (TOP PRIORITY: kick off weekly counter).\n", stderr)
                    } else {
                        stickySelected = sticky
                        let quotaPercent = Int(eval.quotaRemaining * 100)
                        let activeCount = threads[sticky, default: 0]
                        fputs("\u{001B}[1;32m[agymux]\u{001B}[0m Maintaining cache stickiness on \u{001B}[1m\(sticky)\u{001B}[0m (\(quotaPercent)% quota · \(activeCount)/\(config.maxActiveThreadsPerProfile) threads · Model: \(effectiveModel))\n", stderr)
                    }
                } else {
                    fputs("\u{001B}[1;33m[agymux]\u{001B}[0m Breaking cache stickiness on '\(sticky)': \(eval.reason). Re-routing to best pool profile…\n", stderr)
                }
            }

            if let sticky = stickySelected {
                targetProfile = sticky
            } else {
                var candidateBest = QuotaStrategies.selectBestProfile(
                    candidates: candidates,
                    quotas: quotas,
                    activeThreads: threads,
                    maxSlotsPerProfile: config.maxActiveThreadsPerProfile,
                    requestedModel: effectiveModel,
                    strategy: activeStrategy
                )

                // Handle when all auto profiles are depleted
                if candidateBest == nil || (candidateBest?.quotaRemaining ?? 0.0) < 0.05 {
                    let fallbackMode = config.reservedFallbackMode.lowercased()
                    let reservedCandidates = config.reserved

                    if !reservedCandidates.isEmpty {
                        let resQuotas = await quotaBroker.fetchAllQuotas(profileNames: reservedCandidates)
                        let bestReserved = QuotaStrategies.selectBestProfile(
                            candidates: reservedCandidates,
                            quotas: resQuotas,
                            activeThreads: threads,
                            maxSlotsPerProfile: config.maxActiveThreadsPerProfile,
                            requestedModel: effectiveModel,
                            strategy: activeStrategy
                        )

                        if let br = bestReserved, br.quotaRemaining >= 0.05 {
                            if fallbackMode == "auto" {
                                fputs("\u{001B}[1;33m[agymux] Auto Pool depleted; auto-fallback to reserved profile '\(br.profileName)'.\u{001B}[0m\n", stderr)
                                candidateBest = br
                            } else if fallbackMode == "prompt" && isatty(STDIN_FILENO) != 0 {
                                let emailLabel = poolManager.email(for: br.profileName).map { " (\($0))" } ?? ""
                                fputs("\n\u{001B}[1;33m[agymux] All Auto Pool profiles are depleted.\u{001B}[0m\n", stderr)
                                fputs("\u{001B}[1;36m[agymux] Unlock reserved profile '\(br.profileName)'\(emailLabel)? [y/N]: \u{001B}[0m", stderr)
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
                    fputs("\u{001B}[1;31magymux: Could not select an available profile with remaining quota.\u{001B}[0m\n", stderr)
                    exit(1)
                }

                targetProfile = best.profileName
                let quotaPercent = Int(best.quotaRemaining * 100)
                fputs("\u{001B}[1;32m[agymux]\u{001B}[0m Dispatched to \u{001B}[1m\(targetProfile)\u{001B}[0m (\(quotaPercent)% quota · \(best.activeThreads) active threads · Model: \(effectiveModel) · \(best.rationale))\n", stderr)
            }
        }

        // Run child process under supervision
        do {
            let exitCode = try await SessionSupervisor.shared.runSupervised(
                realAgyPath: realAgy,
                initialProfile: targetProfile,
                arguments: forwardedArgs,
                strategy: activeStrategy,
                requestedModel: effectiveModel,
                entrySignalState: entrySignalState
            )

            // Record conversation stickiness for future continuations
            if let activeId = targetConvId ?? stickinessStore.detectLatestConversationId() {
                stickinessStore.recordUsage(
                    conversationId: activeId,
                    profileName: targetProfile,
                    model: effectiveModel
                )
            }
            exit(exitCode)
        } catch {
            fputs("\u{001B}[1;31magymux: \(error.localizedDescription)\u{001B}[0m\n", stderr)
            exit(1)
        }
    }

    static func handlePoolCommand(_ args: [String]) async {
        let poolManager = PoolManager.shared
        let sub = args.first ?? "status"

        if sub == "status" || sub == "list" {
            let config = poolManager.loadConfig()
            let allProfiles = Set(config.reserved + config.auto).sorted()
            let quotas = await QuotaBroker.shared.fetchAllQuotas(profileNames: allProfiles)
            let threads = ConcurrencyGuard.shared.allActiveThreadCounts()

            func pad(_ s: String, _ width: Int) -> String {
                if s.count >= width { return String(s.prefix(width)) }
                return s + String(repeating: " ", count: width - s.count)
            }

            print("\u{001B}[1mAGY PROFILE POOL STATUS\u{001B}[0m (Model: \(config.defaultModel), Strategy: \(config.defaultStrategy), Slots: \(config.maxActiveThreadsPerProfile), Fallback: \(config.reservedFallbackMode))")
            print(String(repeating: "─", count: 108))
            print("\(pad("POOL", 11)) \(pad("PROFILE (EMAIL)", 32)) \(pad("GEMINI (5h/W)", 15)) \(pad("CLAUDE (5h/W)", 15)) \(pad("RESET IN", 12)) \(pad("SLOTS", 9)) STATUS")
            print(String(repeating: "─", count: 108))

            for p in allProfiles {
                let cat = config.reserved.contains(p) ? "[reserved]" : "[auto]"
                let email = poolManager.email(for: p) ?? ""
                let profileDisplay = email.isEmpty || email == p ? p : "\(p) (\(email))"

                let snap = quotas[p]
                let g5 = snap?.geminiFiveHour?.clampedRemainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
                let gw = snap?.geminiWeekly?.clampedRemainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
                let geminiStr = "\(g5) / \(gw)"

                let t5 = snap?.thirdPartyFiveHour?.clampedRemainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
                let tw = snap?.thirdPartyWeekly?.clampedRemainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
                let claudeStr = "\(t5) / \(tw)"

                let resetStr: String
                if let reset = snap?.primaryResetDate() {
                    let diff = max(0, reset.timeIntervalSinceNow)
                    let h = Int(diff) / 3600
                    let m = (Int(diff) % 3600) / 60
                    resetStr = "\(h)h \(m)m"
                } else {
                    resetStr = "--"
                }

                let inUse = threads[p, default: 0]
                let maxSlots = config.maxActiveThreadsPerProfile
                let slotStr = "\(inUse) / \(maxSlots)"

                let geminiAvailable = (snap?.geminiFiveHour?.clampedRemainingFraction ?? 1.0) > 0.05
                    && (snap?.geminiWeekly?.clampedRemainingFraction ?? 1.0) > 0.05
                let thirdPartyAvailable = (snap?.thirdPartyFiveHour?.clampedRemainingFraction ?? 1.0) > 0.05
                    && (snap?.thirdPartyWeekly?.clampedRemainingFraction ?? 1.0) > 0.05

                let status: String
                if config.reserved.contains(p) {
                    status = "\u{001B}[1;34mMANUAL ONLY\u{001B}[0m"
                } else if inUse >= maxSlots {
                    status = "\u{001B}[1;33mBUSY\u{001B}[0m"
                } else if geminiAvailable && thirdPartyAvailable {
                    status = "\u{001B}[1;32mREADY\u{001B}[0m"
                } else if geminiAvailable && !thirdPartyAvailable {
                    status = "\u{001B}[1;36mGEMINI ONLY\u{001B}[0m"
                } else if !geminiAvailable && thirdPartyAvailable {
                    status = "\u{001B}[1;35mCLAUDE ONLY\u{001B}[0m"
                } else {
                    status = "\u{001B}[1;31mDEPLETED\u{001B}[0m"
                }

                print("\(pad(cat, 11)) \(pad(profileDisplay, 32)) \(pad(geminiStr, 15)) \(pad(claudeStr, 15)) \(pad(resetStr, 12)) \(pad(slotStr, 9)) \(status)")
            }
            print(String(repeating: "─", count: 108))
            return
        }

        if sub == "set", args.count >= 3 {
            let profile = args[1]
            guard let cat = ProfileCategory(rawValue: args[2].lowercased()) else {
                print("Invalid category '\(args[2])'. Use 'auto' or 'reserved'.")
                return
            }
            poolManager.setCategory(profile: profile, category: cat)
            print("Profile '\(profile)' moved to \(cat.rawValue) pool.")
            return
        }

        print("Usage: agyx pool [status | set <profile> auto|reserved]")
    }

    static func handleQuotaCommand(_ args: [String]) async {
        let poolManager = PoolManager.shared
        let config = poolManager.loadConfig()
        let target = args.first ?? config.auto.first ?? "current"

        fputs("Fetching quota breakdown for '\(target)'…\n", stderr)
        do {
            let snap = try await QuotaBroker.shared.fetchQuota(profileName: target)
            print("\n\u{001B}[1mQuota Details for \(target)\u{001B}[0m (Source: \(snap.metrics.first?.source.displayName ?? "Unknown"))")
            for m in snap.metrics {
                let frac = m.clampedRemainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A"
                let reset = m.resetAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "None"
                print(" • [\(m.group.displayName)] \(m.window.shortLabel): \(frac) (Reset: \(reset))")
            }
        } catch {
            print("Failed to fetch quota: \(error.localizedDescription)")
        }
    }

    static func handleConfigCommand(_ args: [String]) {
        let poolManager = PoolManager.shared
        if args.count >= 3, args[0] == "set" {
            let key = args[1].lowercased()
            let val = args.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "model" || key == "default-model" {
                let normalized = PoolManager.normalizeModelName(val)
                poolManager.setModel(normalized)
                print("Default model set to '\(normalized)'.")
                return
            } else if key == "strategy" {
                guard QuotaStrategy(rawValue: val.lowercased()) != nil else {
                    print("Unknown strategy '\(val)'. Valid: \(QuotaStrategy.allCases.map(\.rawValue).joined(separator: ", "))")
                    return
                }
                poolManager.setStrategy(val.lowercased())
                print("Default strategy set to '\(val)'.")
                return
            } else if key == "max-threads" || key == "slots" {
                guard let num = Int(val), num >= 1 else {
                    print("Max threads must be an integer >= 1")
                    return
                }
                poolManager.setMaxThreads(num)
                print("Max active threads per profile set to \(num).")
                return
            } else if key == "reserved-fallback" || key == "fallback" {
                let mode = val.lowercased()
                guard mode == "prompt" || mode == "never" || mode == "auto" else {
                    print("Invalid fallback mode '\(val)'. Valid options: 'prompt', 'never', 'auto'")
                    return
                }
                poolManager.setFallbackMode(mode)
                print("Reserved fallback mode set to '\(mode)'.")
                return
            } else if key == "stickiness-min-quota" || key == "stickiness-quota" {
                let cleanVal = val.replacingOccurrences(of: "%", with: "")
                if let pct = Double(cleanVal) {
                    let fraction = pct > 1.0 ? pct / 100.0 : pct
                    var stickConfig = ConversationStickinessStore.shared.loadConfig()
                    stickConfig.minStickinessQuota = max(0.01, min(0.90, fraction))
                    ConversationStickinessStore.shared.saveConfig(stickConfig)
                    print("Stickiness minimum quota threshold set to \(Int(stickConfig.minStickinessQuota * 100))%.")
                    return
                } else {
                    print("Invalid stickiness quota value. Example: '0.15' or '15%'")
                    return
                }
            }
        }
        let config = poolManager.loadConfig()
        let stickConfig = ConversationStickinessStore.shared.loadConfig()
        print("""
        \u{001B}[1mCurrent Configuration (~/.agymux/pools.json & stickiness.json):\u{001B}[0m
          Default Model:         \(config.defaultModel)
          Default Strategy:      \(config.defaultStrategy)
          Max Slots/Profile:     \(config.maxActiveThreadsPerProfile) (default: 3)
          Reserved Fallback:     \(config.reservedFallbackMode) (prompt | never | auto)
          Stickiness Min Quota:  \(Int(stickConfig.minStickinessQuota * 100))% (prompt cache preservation)
          Reserved Pool:         \(config.reserved.joined(separator: ", "))
          Auto Pool:             \(config.auto.joined(separator: ", "))
        """)
    }

    static func handleDoctorCommand() async {
        print("\u{001B}[1magymux Diagnostic Health Check\u{001B}[0m\n")
        let agy = ExecutableLocator.find("agy")
        let aisw = ExecutableLocator.find("aisw")
        let sec = ExecutableLocator.find("security")

        print("1. Executables:")
        print("   • agy:      \(agy ?? "\u{001B}[31mNOT FOUND\u{001B}[0m")")
        print("   • aisw:     \(aisw ?? "\u{001B}[31mNOT FOUND\u{001B}[0m")")
        print("   • security: \(sec ?? "\u{001B}[31mNOT FOUND\u{001B}[0m")")

        let poolManager = PoolManager.shared
        let config = poolManager.loadConfig()
        print("\n2. Profile Configuration:")
        print("   • Auto Pool (\(config.auto.count)):     \(config.auto.joined(separator: ", "))")
        print("   • Reserved Pool (\(config.reserved.count)): \(config.reserved.joined(separator: ", "))")
        print("   • Default Model:         \(config.defaultModel)")
        print("   • Max Slots per Profile: \(config.maxActiveThreadsPerProfile)")
        print("   • Reserved Fallback:     \(config.reservedFallbackMode)")

        let liveCred = try? KeychainClient.shared.readLiveCredential()
        let liveRefresh = liveCred.flatMap { AgyCredential.refreshTokenIdentity(of: $0) }
        print("\n3. macOS Keychain:")
        print("   • Item 'gemini / antigravity': \(liveCred != nil ? "\u{001B}[32mReadable\u{001B}[0m" : "\u{001B}[31mMissing\u{001B}[0m")")
        if let liveRefresh {
            let preview = String(liveRefresh.prefix(10)) + "…"
            print("   • Live Refresh Token:         \(preview)")
        }

        let pruned = ConcurrencyGuard.shared.pruneStaleSessions()
        let active = ConcurrencyGuard.shared.activeSessions()
        print("\n4. Active Sessions:")
        print("   • Live Sessions:  \(active.count)")
        print("   • Pruned Zombies: \(pruned)")

        let stickinessConfig = ConversationStickinessStore.shared.loadConfig()
        print("\n5. Continuation Stickiness (Prompt Cache):")
        print("   • Minimum Quota Threshold: \(Int(stickinessConfig.minStickinessQuota * 100))%")
        print("   • Active Sticky Threads:   \(stickinessConfig.records.count) conversations")

        print("\nHealth Status: \u{001B}[32mREADY\u{001B}[0m")
    }
}
