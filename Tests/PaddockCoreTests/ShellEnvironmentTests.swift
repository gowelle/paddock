import XCTest
@testable import PaddockCore

/// The user's shell environment that tasks run with: captured past any noise a shell's startup files print,
/// never hanging, falling back to a basic one, and with Paddock's `bin` first on PATH.
final class ShellEnvironmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/pdk-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let marker = "PADDOCK-ENV-test"

    // MARK: - Parsing

    func testParsingSkipsNoiseAndKeepsNewlinesAndEqualsSignsInValues() throws {
        let output = "Welcome!\nPADDOCK-ENV-test is not this line\n" + "\n" + marker + "\n"
            + "PATH=/usr/bin:/bin\0MULTI=line one\nline two\0EQ=a=b=c\0EMPTY=\0NOEQUALS\0=novalue\0"
        let parsed = try XCTUnwrap(ShellEnvironment.parse(output, marker: marker))
        XCTAssertEqual(parsed, ["PATH": "/usr/bin:/bin", "MULTI": "line one\nline two", "EQ": "a=b=c", "EMPTY": ""])
    }

    func testAnythingAfterTheLastEntryIsDropped() throws {
        let parsed = try XCTUnwrap(ShellEnvironment.parse("\n" + marker + "\nA=1\0B=2\0Bye from zlogout\n", marker: marker))
        XCTAssertEqual(parsed, ["A": "1", "B": "2"])
    }

    func testNoMarkerOrNoEntriesIsNoEnvironment() {
        XCTAssertNil(ShellEnvironment.parse("A=1\0B=2\0", marker: marker), "without the marker it could be rc noise")
        XCTAssertNil(ShellEnvironment.parse("\n" + marker + "\n", marker: marker))
        XCTAssertNil(ShellEnvironment.parse("", marker: marker))
    }

    // MARK: - Capturing (with a stand-in shell)

    func testCaptureRunsALoginInteractiveShellWithNoPaddockVariablesAndKeepsWhatItPrints() {
        let seen = Locked<[String]>([])
        let captured = ShellEnvironment.capture(shell: "/bin/zsh", environment: ["HOME": "/Users/me", "PADDOCK_HOME": "/x",
                                                                                 "SHELL": "/bin/zsh"],
                                                timeout: 5) { shell, arguments, environment, directory, timeout in
            seen.withValue { $0 = [shell] + arguments + [directory.path, "\(timeout)", environment["PADDOCK_HOME"] ?? "none"] }
            let marker = arguments.last!.components(separatedBy: "'")[3]
            return "noise\n\n\(marker)\nPATH=/opt/tools/bin:/usr/bin\0SHLVL=2\0PWD=/Users/me\0OLDPWD=/\0_=/usr/bin/env\0"
                + "PADDOCK_HOME=/leak\0SECRET=s3cret\0"
        }
        XCTAssertFalse(captured.usedFallback)
        XCTAssertEqual(captured.variables, ["PATH": "/opt/tools/bin:/usr/bin", "SECRET": "s3cret"],
                       "shell bookkeeping and Paddock's own variables are dropped")
        XCTAssertEqual(Array(seen.value.prefix(4)), ["/bin/zsh", "-l", "-i", "-c"])
        XCTAssertEqual(Array(seen.value.suffix(3)), ["/Users/me", "5.0", "none"],
                       "run from the home folder, with the time limit, and without Paddock's variables")
        XCTAssertFalse(captured.description.contains("s3cret"), "values are never logged: \(captured.description)")
        XCTAssertTrue(captured.description.contains("2 variables"), captured.description)
    }

    func testAShellThatFailsGivesTheFallback() {
        let environment = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/me/",
                           "SECRET": "x"]
        for output in [nil, "garbage without a marker"] as [String?] {
            let captured = ShellEnvironment.capture(shell: "/bin/zsh", environment: environment, timeout: 5) { _, _, _, _, _ in output }
            XCTAssertTrue(captured.usedFallback)
            XCTAssertEqual(captured.variables, [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/Users/me/.bun/bin",
                "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/me/",
                "LANG": "en_US.UTF-8",
            ])
            XCTAssertTrue(captured.description.contains("fallback"), captured.description)
        }
    }

    func testTheUsersShell() {
        XCTAssertEqual(ShellEnvironment.userShell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
        XCTAssertEqual(ShellEnvironment.userShell(environment: ["SHELL": "bash"]), ShellEnvironment.userShell(environment: [:]),
                       "only an absolute path to a program")
        XCTAssertEqual(ShellEnvironment.userShell(environment: ["SHELL": "/nonexistent/shell"]),
                       ShellEnvironment.userShell(environment: [:]))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ShellEnvironment.userShell(environment: [:])))
    }

    // MARK: - What tasks get

    func testTasksGetPaddocksBinFirstAndTheHomeOnlyForADevelopmentHome() {
        let captured = ShellEnvironment(variables: ["PATH": "/opt/tools/bin:/usr/bin", "LANG": "en_GB.UTF-8"],
                                        usedFallback: false, shell: "/bin/zsh")
        let development = Paths(home: URL(fileURLWithPath: "/tmp/pdk-x/home"))
        let env = captured.forTasks(paths: development)
        XCTAssertEqual(env["PATH"], "/tmp/pdk-x/home/bin:/opt/tools/bin:/usr/bin")
        XCTAssertEqual(env["PADDOCK_HOME"], "/tmp/pdk-x/home", "so php and composer find this home's PHP")
        XCTAssertEqual(env["LANG"], "en_GB.UTF-8")
        let real = captured.forTasks(paths: .system)
        XCTAssertNil(real["PADDOCK_HOME"])
        XCTAssertEqual(real["PATH"], Paths.system.bin.path + ":/opt/tools/bin:/usr/bin")
        let noPath = ShellEnvironment(variables: [:], usedFallback: false, shell: "/bin/zsh").forTasks(paths: development)
        XCTAssertEqual(noPath["PATH"], "/tmp/pdk-x/home/bin")
    }

    // MARK: - The real shell

    /// The one run of a real shell: zsh with a scratch home and ZDOTDIR (never the owner's own startup
    /// files) whose rc prints noise and exports a marker; then one whose rc hangs, which is cut off.
    func testTheRealShellPastNoiseAndAHangingStartupFile() throws {
        let quiet = root.appendingPathComponent("noisy", isDirectory: true)
        try FileManager.default.createDirectory(at: quiet, withIntermediateDirectories: true)
        try """
        echo "Welcome to a noisy shell"
        echo "PDK_NOT_A_VARIABLE=from-noise"
        echo "more noise" >&2
        export PDK_MARKER='a=b
        second line'
        """.write(to: quiet.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var base = ProcessInfo.processInfo.environment
        base["HOME"] = quiet.path
        base["ZDOTDIR"] = quiet.path
        base["CFFIXED_USER_HOME"] = quiet.path
        let captured = ShellEnvironment.capture(shell: "/bin/zsh", environment: base, timeout: 5)
        XCTAssertFalse(captured.usedFallback, captured.description)
        XCTAssertEqual(captured.variables["PDK_MARKER"], "a=b\nsecond line")
        XCTAssertNil(captured.variables["PDK_NOT_A_VARIABLE"])
        XCTAssertEqual(captured.variables["HOME"], quiet.path)
        XCTAssertNotNil(captured.variables["PATH"])
        XCTAssertTrue(captured.variables.keys.allSatisfy { !$0.hasPrefix("PADDOCK_") })

        let hanging = root.appendingPathComponent("hanging", isDirectory: true)
        try FileManager.default.createDirectory(at: hanging, withIntermediateDirectories: true)
        try "sleep 60\n".write(to: hanging.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        base["HOME"] = hanging.path
        base["ZDOTDIR"] = hanging.path
        base["CFFIXED_USER_HOME"] = hanging.path
        let started = Date()
        let cut = ShellEnvironment.capture(shell: "/bin/zsh", environment: base, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "never waits for a hanging startup file")
        XCTAssertTrue(cut.usedFallback)
        XCTAssertEqual(cut.variables["HOME"], hanging.path)
    }
}
