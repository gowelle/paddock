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
}
