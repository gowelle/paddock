import XCTest
@testable import PaddockCore

final class SupervisorTests: XCTestCase {
    private var dir: URL!
    private var supervisor: Supervisor!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdk-sup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        supervisor?.stopAll()
        supervisor = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func shell(_ name: String, _ script: String, env: [String: String] = [:]) -> ProcessSpec {
        ProcessSpec(name: name, executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                    environment: env, logFile: dir.appendingPathComponent("\(name).log"))
    }

    private func lines(_ file: String) -> Int {
        let text = (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testBackoffDoublesFromOneSecondCappedAtThirty() {
        XCTAssertEqual((1...7).map { Supervisor.backoff(afterFailures: $0) }, [1, 2, 4, 8, 16, 30, 30])
    }

    func testFailingProcessIsRestartedThenLeftCrashedAfterFifthFailure() throws {
        supervisor = Supervisor(backoffScale: 0.01)
        let runs = dir.appendingPathComponent("runs").path
        try supervisor.start(shell("fail", "echo run >> '\(runs)'; exit 1"))

        XCTAssertTrue(waitUntil(5) {
            if case .crashed = self.supervisor.status("fail"), self.lines("runs") == 5 { return true }
            return false
        }, "status \(supervisor.status("fail")), runs \(lines("runs"))")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(lines("runs"), 5, "must not restart after the fifth failure")
        guard case .crashed(let code) = supervisor.status("fail") else {
            return XCTFail("expected crashed, got \(supervisor.status("fail"))")
        }
        XCTAssertEqual(code, 1)
    }

    func testStopTerminatesAndPreventsRestart() throws {
        supervisor = Supervisor(backoffScale: 0.01)
        let runs = dir.appendingPathComponent("runs").path
        try supervisor.start(shell("sleeper", "echo run >> '\(runs)'; exec sleep 60"))
        XCTAssertTrue(waitUntil(5) { self.lines("runs") == 1 })
        guard case .running(let pid) = supervisor.status("sleeper") else {
            return XCTFail("expected running, got \(supervisor.status("sleeper"))")
        }

        supervisor.stop("sleeper")

        XCTAssertEqual(kill(pid, 0), -1, "process still alive after stop")
        guard case .stopped = supervisor.status("sleeper") else {
            return XCTFail("expected stopped, got \(supervisor.status("sleeper"))")
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(lines("runs"), 1, "restarted after a deliberate stop")
    }

    func testStopKillsProcessThatIgnoresSIGTERMAndItsChildren() throws {
        supervisor = Supervisor(backoffScale: 0.01, stopGracePeriod: 0.3)
        let childPid = dir.appendingPathComponent("child.pid").path
        // The shell ignores TERM; its background child inherits that and must still die.
        try supervisor.start(shell("stubborn",
                                   "trap '' TERM; sleep 60 & echo $! > '\(childPid)'; wait"))
        XCTAssertTrue(waitUntil(5) { self.lines("child.pid") == 1 })
        let child = try XCTUnwrap(Int32(try String(contentsOfFile: childPid, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        supervisor.stop("stubborn")

        XCTAssertTrue(waitUntil(2) { kill(child, 0) == -1 }, "child process survived stop")
        guard case .stopped = supervisor.status("stubborn") else {
            return XCTFail("expected stopped, got \(supervisor.status("stubborn"))")
        }
    }

    /// A spec's working directory is where the process (and every restart of it) runs; without one it is the
    /// supervisor's own.
    func testWorkingDirectory() throws {
        supervisor = Supervisor(backoffScale: 0.01)
        let folder = dir.appendingPathComponent("work dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var spec = shell("cwd", "pwd -P; exec sleep 60")
        spec.workingDirectory = folder
        try supervisor.start(spec)
        XCTAssertTrue(waitUntil(5) { self.lines("cwd.log") == 1 })
        let log = try String(contentsOf: dir.appendingPathComponent("cwd.log"), encoding: .utf8)
        XCTAssertEqual(log, (ServiceManager.realPath(folder.path) ?? "?") + "\n")
    }

    /// A log over 20 MB is set aside as `<name>.1` (replacing an older one) before the process opens it; a smaller
    /// one is kept and appended to.
    func testALargeLogIsSetAsideBeforeTheProcessStarts() throws {
        supervisor = Supervisor()
        let log = dir.appendingPathComponent("big.log")
        let old = URL(fileURLWithPath: log.path + ".1")
        try Data("older".utf8).write(to: old)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 21 * 1024 * 1024)
        try handle.close()
        try supervisor.start(shell("big", "echo fresh; exec sleep 60"))
        XCTAssertTrue(waitUntil(5) { self.lines("big.log") == 1 })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: old.path)[.size] as? UInt64, 21 * 1024 * 1024)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "fresh\n")

        let small = dir.appendingPathComponent("small.log")
        try Data("kept\n".utf8).write(to: small)
        try supervisor.start(shell("small", "echo more; exec sleep 60"))
        XCTAssertTrue(waitUntil(5) { self.lines("small.log") == 2 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: small.path + ".1"))
    }

    /// The daemon's own log, held open by the daemon itself (as its stdout and stderr): set aside at its start and
    /// the descriptors moved to a fresh file, so nothing goes on writing to the old one.
    func testALogTheDaemonHoldsIsSetAsideAndReopened() throws {
        let log = dir.appendingPathComponent("paddockd.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let held = open(log.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(ftruncate(held, 25 * 1024 * 1024), 0)
        XCTAssertTrue(LogFiles.rotateHeldLog(log, descriptors: [held]))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: log.path + ".1")[.size] as? UInt64, 25 * 1024 * 1024)
        _ = "new line\n".withCString { write(held, $0, strlen($0)) }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new line\n", "the descriptor writes to the fresh file")
        XCTAssertFalse(LogFiles.rotateHeldLog(log, descriptors: [held]), "small now: left alone")
    }

    func testEnvironmentAndLogFile() throws {
        supervisor = Supervisor()
        try supervisor.start(shell("env", "echo \"value=$PDK_TEST\"; echo err >&2; exec sleep 60",
                                   env: ["PDK_TEST": "hello world"]))
        XCTAssertTrue(waitUntil(5) { self.lines("env.log") == 2 })
        let log = try String(contentsOf: dir.appendingPathComponent("env.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("value=hello world"), log)
        XCTAssertTrue(log.contains("err"), log)
    }

    func testUnknownNameIsStoppedAndStopAllStopsEverything() throws {
        supervisor = Supervisor()
        guard case .stopped = supervisor.status("nothing") else { return XCTFail() }
        try supervisor.start(shell("a", "exec sleep 60"))
        try supervisor.start(shell("b", "exec sleep 60"))
        var pids: [Int32] = []
        for name in ["a", "b"] {
            guard case .running(let pid) = supervisor.status(name) else { return XCTFail(name) }
            pids.append(pid)
        }
        supervisor.stopAll()
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1) }
        for name in ["a", "b"] {
            guard case .stopped = supervisor.status(name) else { return XCTFail(name) }
        }
    }

    func testConcurrentStopsBothReturn() throws {
        supervisor = Supervisor()
        try supervisor.start(shell("twice", "exec sleep 60"))
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) { self.supervisor.stop("twice") }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success, "a concurrent stop hung")
    }

    /// A service that stops cleanly only on SIGINT gets SIGINT, not SIGTERM then SIGKILL.
    func testStopSendsTheSpecsSignal() throws {
        supervisor = Supervisor(stopGracePeriod: 5)
        let marker = dir.appendingPathComponent("int").path
        var spec = shell("int", "trap '' TERM; trap 'echo int > \"\(marker)\"; exit 0' INT; while :; do sleep 0.05; done")
        spec.stopSignal = SIGINT
        try supervisor.start(spec)
        Thread.sleep(forTimeInterval: 0.3) // Let the shell set its traps.
        let started = Date()
        supervisor.stop("int")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "stopped by SIGINT, not by the SIGKILL fallback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "the INT handler ran")
        XCTAssertEqual(supervisor.status("int"), .stopped)
    }

    /// A spec's own grace period replaces the supervisor's before SIGKILL.
    func testStopUsesTheSpecsGracePeriod() throws {
        supervisor = Supervisor(stopGracePeriod: 30)
        var spec = shell("stubborn", "trap '' TERM; while :; do sleep 0.05; done")
        spec.stopGrace = 0.5
        try supervisor.start(spec)
        Thread.sleep(forTimeInterval: 0.3)
        let started = Date()
        supervisor.stop("stubborn")
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 0.4)
        XCTAssertLessThan(took, 5, "SIGKILL after the spec's 0.5 seconds, not the supervisor's 30")
        XCTAssertEqual(supervisor.status("stubborn"), .stopped)
    }

    /// A stop may give less time than the spec's grace (the daemon shutting down), and says whether the
    /// process had to be killed.
    func testStopWithAShorterGraceSaysWhetherItHadToKill() throws {
        supervisor = Supervisor()
        var stubborn = shell("stubborn", "trap '' TERM; while :; do sleep 0.05; done")
        stubborn.stopGrace = 30
        try supervisor.start(stubborn)
        try supervisor.start(shell("polite", "exec sleep 60"))
        Thread.sleep(forTimeInterval: 0.3) // Let the shell set its trap.
        let started = Date()
        XCTAssertEqual(supervisor.stop("stubborn", grace: 0.5), .killed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the shorter grace, not the spec's 30 seconds")
        XCTAssertEqual(supervisor.stop("polite", grace: 5), .exited)
        XCTAssertEqual(supervisor.stop("polite"), .notRunning)
        XCTAssertEqual(supervisor.status("stubborn"), .stopped)
    }

    /// A spec can decline a restart after an exit (a command that keeps finishing by itself): it is left
    /// stopped. Every unexpected exit is reported, with whether a restart follows.
    func testAnExitTheSpecDeclinesIsNotRestartedAndEveryExitIsReported() throws {
        supervisor = Supervisor(backoffScale: 0.01)
        let runs = dir.appendingPathComponent("runs").path
        let exits = Locked<[String]>([])
        var spec = shell("once", "echo run >> '\(runs)'; exit 0")
        spec.exitDecision = { code in code != 0 ? .restart : .stop }
        spec.didExit = { code, restarting in exits.withValue { $0.append("\(code) \(restarting)") } }
        try supervisor.start(spec)
        XCTAssertTrue(waitUntil(5) { exits.value.count == 1 })
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(lines("runs"), 1, "not restarted")
        XCTAssertEqual(exits.value, ["0 false"])
        XCTAssertEqual(supervisor.status("once"), .stopped)
        XCTAssertFalse(supervisor.hasGivenUp("once"), "stopped by its spec's choice, not given up on")

        var failing = shell("fail", "exit 3")
        failing.didExit = { code, restarting in exits.withValue { $0.append("\(code) \(restarting)") } }
        exits.withValue { $0 = [] }
        try supervisor.start(failing)
        XCTAssertTrue(waitUntil(5) { exits.value.count == 5 })
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(exits.value, ["3 true", "3 true", "3 true", "3 true", "3 false"], "the fifth failure gives up")
        XCTAssertTrue(supervisor.hasGivenUp("fail"))
        try supervisor.start(failing)
        XCTAssertFalse(supervisor.hasGivenUp("fail"), "a new start forgets the give-up")
    }

    /// An exit the spec says not to count is restarted after the spec's delay and never reaches the failure
    /// limit, however often it happens.
    func testAnUncountedExitNeverGivesUp() throws {
        supervisor = Supervisor(backoffScale: 0.01)
        let runs = dir.appendingPathComponent("runs").path
        var spec = shell("clean", "echo run >> '\(runs)'; exit 0")
        spec.exitDecision = { _ in .restartUncounted(after: 1) }
        try supervisor.start(spec)
        XCTAssertTrue(waitUntil(10) { self.lines("runs") >= 8 }, "runs \(lines("runs"))")
        XCTAssertFalse(supervisor.hasGivenUp("clean"))
    }

    /// With an output sink the process's stdout and stderr go to a pipe the sink reads, not to the log file.
    func testOutputGoesToTheSink() throws {
        supervisor = Supervisor()
        let sink = CollectingOutput()
        var spec = shell("talk", "echo out; echo err >&2; exec sleep 60")
        spec.output = sink
        try supervisor.start(spec)
        XCTAssertTrue(waitUntil(5) { sink.text.contains("out\n") && sink.text.contains("err\n") }, sink.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("talk.log").path))
        supervisor.stop("talk")
        XCTAssertTrue(waitUntil(5) { sink.closed }, "the pipe closes when the process group is gone")
    }

    func testASignalReachesTheRunningGroup() throws {
        supervisor = Supervisor(stopGracePeriod: 60)
        try supervisor.start(shell("stubborn", "trap '' TERM; while :; do sleep 0.05; done"))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(supervisor.signal("stubborn", SIGKILL))
        XCTAssertTrue(waitUntil(5) { if case .running = self.supervisor.status("stubborn") { return false }; return true })
        XCTAssertFalse(supervisor.signal("nothing", SIGKILL))
    }
}

/// Collects what a process writes to its output pipe.
final class CollectingOutput: ProcessOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var isClosed = false

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }

    func attach(_ fd: Int32) {
        Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                self.lock.lock(); self.data.append(contentsOf: buffer[0..<n]); self.lock.unlock()
            }
            close(fd)
            self.lock.lock(); self.isClosed = true; self.lock.unlock()
        }.start()
    }
}
