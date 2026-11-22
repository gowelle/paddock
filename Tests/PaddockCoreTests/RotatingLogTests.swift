import Darwin
import XCTest
@testable import PaddockCore

/// A process's log that Paddock writes itself: rotated by size as it is written, in constant memory, with the
/// process held back (blocked on its pipe) rather than its output piling up.
final class RotatingLogTests: XCTestCase {
    private var dir: URL!
    private var supervisor: Supervisor?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/pdk-log-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        supervisor?.stopAll()
        try? FileManager.default.removeItem(at: dir)
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    func testTwentyMegabytesLeaveTwoBoundedFilesEndingWithTheLastLines() throws {
        let file = dir.appendingPathComponent("task.log")
        let log = RotatingLog(url: file, limit: 5 * 1024 * 1024)
        let supervisor = Supervisor()
        self.supervisor = supervisor
        var spec = ProcessSpec(name: "loud", executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "head -c 20000000 /dev/zero | tr '\\0' x | fold -w 99; echo LAST-LINE-ONE; echo LAST-LINE-TWO; exec sleep 60",
        ], logFile: dir.appendingPathComponent("unused.log"))
        spec.output = log
        try supervisor.start(spec)
        XCTAssertTrue(waitFor(60) {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasSuffix("LAST-LINE-ONE\nLAST-LINE-TWO\n")
        }, "the last lines printed are the last lines in the log")
        XCTAssertLessThanOrEqual(size(file), 5 * 1024 * 1024)
        let previous = file.appendingPathExtension("1")
        XCTAssertGreaterThan(size(previous), 4 * 1024 * 1024)
        XCTAssertLessThanOrEqual(size(previous), 5 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".2"), "one previous file only")
        XCTAssertLessThanOrEqual(log.peakPendingBytes, RotatingLog.chunkSize, "never more than one chunk held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unused.log").path))
    }

    /// Paddock's own lines go through the same file, and count toward its size.
    func testLinesOfPaddocksOwnAreAppendedAndRotated() throws {
        let file = dir.appendingPathComponent("notes.log")
        let log = RotatingLog(url: file, limit: 100)
        log.append("first line of sixty characters, more or less, to fill up.\n")
        log.append("second line, which pushes the file over its hundred bytes.\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second line, which pushes the file over its hundred bytes.\n")
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8),
                       "first line of sixty characters, more or less, to fill up.\n")
    }

    /// A process whose output nobody reads fast enough is held back by its pipe: the writer never holds more
    /// than one chunk, however much is waiting.
    func testAProcessIsHeldBackRatherThanBuffered() throws {
        let file = dir.appendingPathComponent("slow.log")
        let log = RotatingLog(url: file, limit: 5 * 1024 * 1024)
        log.pauseForTesting(true)
        let supervisor = Supervisor()
        self.supervisor = supervisor
        var spec = ProcessSpec(name: "loud", executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "head -c 5000000 /dev/zero | tr '\\0' y; echo done > '\(dir.path)/finished'; exec sleep 60",
        ], logFile: dir.appendingPathComponent("unused.log"))
        spec.output = log
        try supervisor.start(spec)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("finished").path),
                       "the writer is paused, so the process is blocked on its pipe")
        XCTAssertLessThanOrEqual(log.peakPendingBytes, RotatingLog.chunkSize)
        log.pauseForTesting(false)
        XCTAssertTrue(waitFor(30) { FileManager.default.fileExists(atPath: self.dir.appendingPathComponent("finished").path) })
    }

    /// Following a log across a rotation: what was written to the old file before it was renamed is read to its
    /// end, then the new file from its start.
    func testFollowingReadsTheOldFileToItsEndBeforeTheNewOne() throws {
        let file = dir.appendingPathComponent("follow.log")
        try Data("before\n".utf8).write(to: file)
        let follower = LogFollower(url: file)
        XCTAssertEqual(follower.read(), Data(), "starts at the end")
        let old = try FileHandle(forWritingTo: file)
        old.seekToEndOfFile()
        old.write(Data("one\n".utf8))
        XCTAssertEqual(String(decoding: follower.read(), as: UTF8.self), "one\n")
        old.write(Data("last of the old file\n".utf8))
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("1"))
        try Data("first of the new file\n".utf8).write(to: file)
        XCTAssertEqual(String(decoding: follower.read(), as: UTF8.self), "last of the old file\nfirst of the new file\n")
        try old.close()
    }

    /// The read end of an output pipe is never inherited by another program Paddock starts.
    func testTheOutputPipeIsCloseOnExec() throws {
        let supervisor = Supervisor()
        self.supervisor = supervisor
        let sink = CloseOnExecProbe()
        var spec = ProcessSpec(name: "p", executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 60"],
                               logFile: dir.appendingPathComponent("unused.log"))
        spec.output = sink
        try supervisor.start(spec)
        XCTAssertEqual(sink.closeOnExec, true)
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}

/// Records whether the pipe it is handed is close-on-exec.
final class CloseOnExecProbe: ProcessOutput, @unchecked Sendable {
    private(set) var closeOnExec: Bool?
    func attach(_ fd: Int32) {
        closeOnExec = fcntl(fd, F_GETFD) & FD_CLOEXEC != 0
        close(fd)
    }
}
