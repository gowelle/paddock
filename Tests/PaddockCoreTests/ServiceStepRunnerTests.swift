import Darwin
import XCTest
@testable import PaddockCore

/// The bounded runner for initialise (and later) steps: its own process group, a deadline, SIGTERM then
/// SIGKILL to the whole group, capped output, SIGPIPE-safe stdin, cancellation.
final class ServiceStepRunnerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdk-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sh(_ script: String, stdin: String? = nil, timeout: TimeInterval = 10,
                    isCancelled: @escaping () -> Bool = { false }) throws -> ServiceStepRunner.Outcome {
        try ServiceStepRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                                  directory: dir, stdin: stdin, timeout: timeout, killGrace: 0.5,
                                  isCancelled: isCancelled)
    }

    /// A caller can keep more than the default 64 KB of output (the last part is kept).
    func testACallerCanKeepMoreOutput() throws {
        let script = "head -c 200000 /dev/zero | tr '\\0' a; echo; echo end"
        let outcome = try ServiceStepRunner.run(executable: "/bin/sh", arguments: ["-c", script],
                                                environment: ["PATH": "/usr/bin:/bin"], directory: dir, stdin: nil,
                                                timeout: 10, killGrace: 0.5, keepingLast: 300_000, isCancelled: { false })
        XCTAssertEqual(outcome.output.count, 200_000 + 5)
        XCTAssertTrue(try sh(script).output.utf8.count <= ServiceStepRunner.outputLimit, "the default is unchanged")
    }

    func testExitStatusAndOutput() throws {
        let outcome = try sh("cd \"$PWD\"; echo out; echo err >&2; echo \"$PADDOCK_HOME|$PATH\"; exit 3")
        XCTAssertEqual(outcome.end, .exited(3))
        XCTAssertEqual(outcome.output, "out\nerr\n|/usr/bin:/bin\n", "only the given environment")
    }

    func testAStepIgnoringSIGTERMIsKilledAtTheDeadline() throws {
        let started = Date()
        let outcome = try sh("trap '' TERM; sleep 30", timeout: 1)
        XCTAssertEqual(outcome.end, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A grandchild that keeps stdout open used to block the read forever.
    func testAGrandchildHoldingStdoutDoesNotHangTheRunner() throws {
        let marker = dir.appendingPathComponent("grandchild").path
        let started = Date()
        let outcome = try sh("(sleep 30; touch '\(marker)') & echo started", timeout: 3)
        XCTAssertEqual(outcome.end, .exited(0))
        XCTAssertEqual(outcome.output, "started\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try processesInGroup(of: outcome.pid), [], "the grandchild was ended with its group")
    }

    /// A step that exits without reading its stdin: the write fails quietly instead of SIGPIPE killing us.
    func testAStepThatDoesNotReadStdinDoesNotKillTheCaller() throws {
        let big = String(repeating: "x", count: 4 * 1024 * 1024)
        let outcome = try sh("exit 0", stdin: big)
        XCTAssertEqual(outcome.end, .exited(0))
        let reads = try sh("wc -c | tr -d ' '", stdin: "hello")
        XCTAssertEqual(reads.output, "5\n")
    }

    func testCancellationEndsALongStepPromptly() throws {
        let started = Date()
        let outcome = try sh("trap '' TERM; sleep 30", timeout: 60, isCancelled: { Date().timeIntervalSince(started) > 0.5 })
        XCTAssertEqual(outcome.end, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOutputKeepsTheLast64KB() throws {
        let outcome = try sh("i=0; while [ $i -lt 3000 ]; do echo \"line $i ................................\"; i=$((i+1)); done")
        XCTAssertEqual(outcome.end, .exited(0))
        XCTAssertLessThanOrEqual(outcome.output.utf8.count, 64 * 1024)
        XCTAssertTrue(outcome.output.hasSuffix("line 2999 ................................\n"))
    }

    private func processesInGroup(of pid: Int32) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-g", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
