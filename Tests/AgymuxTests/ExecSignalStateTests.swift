import Darwin
import Foundation
import Testing
@testable import AgymuxCore

struct ExecSignalStateTests {
    @Test func replacementRestoresControlledEntryMaskAndExecState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in ["default", "usr1"] {
            let fields = parse(try runController(driver: fixture.driver, cwd: fixture.directory, mode: mode))
            #expect(fields["status"] == "0")
            #expect(fields["pid"] == fields["expectedpid"])
            #expect(fields["pgrp"] == fields["tpgid"])
            #expect(fields["ttin"] == "0")
            #expect(fields["hupignored"] == "1")
            let expectedCwd = fixture.directory.path.hasPrefix("/var/")
                ? "/private" + fixture.directory.path
                : fixture.directory.path
            #expect(fields["cwd"] == expectedCwd)
            #expect(fields["argc"] == "3")
            #expect(fields["arg1"] == "first")
            #expect(fields["arg2"] == "second")
            #expect(fields["marker"] == "preserved")
            #expect(fields["lockclosed"] == "1")
            #expect(fields["read"] == "1")
            #expect(fields["usr1"] == (mode == "usr1" ? "1" : "0"))
        }
    }

    @Test func missingExecutableThrowsWithoutChangingCallerState() throws {
        let state = try ExecSignalState.capture()
        #expect(throws: (any Error).self) {
            try state.replaceProcess(executable: "/definitely/not/an/executable", arguments: [], environment: [:])
        }
        #expect(try ExecSignalState.capture() == state)
    }

    private func runController(driver: URL, cwd: URL, mode: String) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", controllerSource, driver.path, cwd.path, mode]
        process.standardOutput = output; process.standardError = output
        try process.run()
        try waitForExit(process, timeout: 12)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw FixtureError.controllerFailed(text) }
        return text
    }

    private func parse(_ output: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: output.split(whereSeparator: { $0.isWhitespace }).compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }

    private func makeFixture() throws -> (directory: URL, driver: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExecSignalStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probeSource = directory.appendingPathComponent("probe.c"), probe = directory.appendingPathComponent("probe")
        let driverSource = directory.appendingPathComponent("driver.swift"), driver = directory.appendingPathComponent("driver")
        let lock = directory.appendingPathComponent("lock")
        try probeC.write(to: probeSource, atomically: true, encoding: .utf8)
        try driverSwift(probe: probe, lock: lock).write(to: driverSource, atomically: true, encoding: .utf8)
        try compile("/usr/bin/cc", [probeSource.path, "-o", probe.path])
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AgymuxCore/ExecSignalState.swift")
        try compile("/usr/bin/swiftc", ["-parse-as-library", core.path, driverSource.path, "-o", driver.path])
        return (directory, driver)
    }

    private func compile(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run()
        try waitForExit(process, timeout: 30)
        guard process.terminationStatus == 0 else { throw FixtureError.compilationFailed }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard process.isRunning else { return }
        // Only our own fixture/compiler may be stopped on timeout. Signal its
        // group only after proving that the child owns a separate group.
        let pid = process.processIdentifier
        if getpgid(pid) == pid {
            _ = Darwin.kill(-pid, SIGKILL)
        } else {
            _ = Darwin.kill(pid, SIGKILL)
        }
        process.waitUntilExit()
        throw FixtureError.timedOut
    }

    private func driverSwift(probe: URL, lock: URL) -> String {
        """
        import Darwin
        import Foundation
        @main struct Driver {
          static func main() async {
            var clean = sigset_t(); sigemptyset(&clean); _ = pthread_sigmask(SIG_SETMASK, &clean, nil)
            signal(SIGHUP, SIG_IGN)
            let lockFD = open("\(lock.path)", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            _ = flock(lockFD, LOCK_EX)
            if CommandLine.arguments[1] == "usr1" { var entry = sigset_t(); sigemptyset(&entry); sigaddset(&entry, SIGUSR1); _ = pthread_sigmask(SIG_BLOCK, &entry, nil) }
            do {
              let state = try ExecSignalState.capture()
              try await Task.detached { await Task.yield(); try state.replaceProcess(executable: "\(probe.path)", arguments: ["first", "second"], environment: ["PROBE_MARKER": "preserved", "LOCK_PATH": "\(lock.path)"]) }.value
            } catch { fputs("driver-error=\\(error)\\n", stderr); exit(1) }
          }
        }
        """
    }

    private var probeC: String {
        """
        #include <fcntl.h>
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <sys/file.h>
        #include <termios.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
          sigset_t mask; sigprocmask(SIG_SETMASK, NULL, &mask); struct sigaction hup; sigaction(SIGHUP, NULL, &hup);
          char cwd[4096]; getcwd(cwd, sizeof(cwd)); int fd = open(getenv("LOCK_PATH"), O_RDWR); int lockclosed = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0;
          fputs("probe-ready\\n", stderr); fflush(stderr);
          char byte; int readcount = (int)read(STDIN_FILENO, &byte, 1);
          printf("pid=%d pgrp=%d tpgid=%d ttin=%d usr1=%d hupignored=%d cwd=%s argc=%d arg1=%s arg2=%s marker=%s lockclosed=%d read=%d\\n", getpid(), getpgrp(), tcgetpgrp(STDIN_FILENO), sigismember(&mask, SIGTTIN), sigismember(&mask, SIGUSR1), hup.sa_handler == SIG_IGN, cwd, argc, argv[1], argv[2], getenv("PROBE_MARKER"), lockclosed, readcount);
          return readcount == 1 && lockclosed ? 0 : 1;
        }
        """
    }

    private var controllerSource: String {
        """
        import fcntl, os, pty, select, signal, sys, termios, time
        driver, cwd, mode = sys.argv[1:]; master, slave = pty.openpty(); pid = os.fork()
        if pid == 0:
            os.setsid(); fcntl.ioctl(slave, termios.TIOCSCTTY, 0); os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2); os.close(master); os.close(slave); os.chdir(cwd); os.execv(driver, [driver, mode])
        os.close(slave); data = b''; reaped = False; deadline = time.monotonic() + 6
        try:
            while b'probe-ready' not in data:
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise RuntimeError('probe timeout')
                ready, _, _ = select.select([master], [], [], remaining)
                if not ready: raise RuntimeError('probe timeout')
                chunk = os.read(master, 4096)
                if not chunk: raise RuntimeError('probe exited before ready')
                data += chunk
            os.write(master, b'Q\\n')
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.05)
                if ready:
                    try: chunk = os.read(master, 4096)
                    except OSError: chunk = b''
                    data += chunk
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    reaped = True
                    break
            if not reaped: raise RuntimeError('probe exit timeout')
            while select.select([master], [], [], 0.1)[0]:
                try: chunk = os.read(master, 4096)
                except OSError: break
                if not chunk: break
                data += chunk
            print(data.decode(errors='replace').replace('\\r', ''), end='')
            print('expectedpid=' + str(pid)); print('status=' + str(os.waitstatus_to_exitcode(status)))
        finally:
            if not reaped:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
                os.waitpid(pid, 0)
            os.close(master)
        """
    }

    private enum FixtureError: Error { case compilationFailed, timedOut, controllerFailed(String) }
}
