import Darwin
import Foundation

/// The calling thread's signal mask at the terminal entry point.
///
/// Swift concurrency workers can block job-control signals. `execv` preserves
/// that worker-local mask, while `posix_spawn` can atomically replace it as it
/// replaces the process image.
public struct ExecSignalState: Sendable, Equatable {
    private let mask: sigset_t

    private init(mask: sigset_t) {
        self.mask = mask
    }

    /// Capture this before awaiting work that may resume on a runtime worker.
    public static func capture() throws -> Self {
        var mask = sigset_t()
        let result = pthread_sigmask(SIG_SETMASK, nil, &mask)
        guard result == 0 else { throw POSIXErrorCode.error(result) }
        return Self(mask: mask)
    }

    /// Atomically replace this process, restoring the captured signal mask.
    ///
    /// `arguments` excludes argv[0]; `executable` becomes argv[0]. Signal
    /// dispositions, process group, terminal descriptors, and current working
    /// directory intentionally retain their normal exec semantics.
    public func replaceProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var attributes: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else { throw POSIXErrorCode.error(initialized) }
        defer { posix_spawnattr_destroy(&attributes) }

        var restoredMask = mask
        let setMask = posix_spawnattr_setsigmask(&attributes, &restoredMask)
        guard setMask == 0 else { throw POSIXErrorCode.error(setMask) }

        let flags = Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK)
        let setFlags = posix_spawnattr_setflags(&attributes, flags)
        guard setFlags == 0 else { throw POSIXErrorCode.error(setFlags) }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for pointer in argv {
                if let pointer { Darwin.free(pointer) }
            }
        }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in envp {
                if let pointer { Darwin.free(pointer) }
            }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    nil,
                    &attributes,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: envBuffer.baseAddress)
                )
            }
        }
        // With POSIX_SPAWN_SETEXEC success never returns. Any return is a
        // failure and leaves this process running with its original state.
        throw POSIXErrorCode.error(result)
    }
}

private extension POSIXErrorCode {
    static func error(_ rawValue: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: rawValue) ?? .EIO)
    }
}
