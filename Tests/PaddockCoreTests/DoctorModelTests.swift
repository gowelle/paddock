import XCTest
@testable import PaddockCore

@MainActor
final class DoctorModelTests: XCTestCase {
    private func status() -> EngineStatus {
        Self.sampleStatus(with: Site(name: "shop", path: "/tmp/shop", kind: .parked, secured: true,
                                     php: PHPVersion(major: 8, minor: 5), pinned: false))
    }

    private nonisolated static func sampleStatus(with site: Site) -> EngineStatus {
        EngineStatus(running: true, blockedBy: [], sites: [site], installedPHP: [site.php],
                     defaultPHP: site.php, processes: [:], resolverInstalled: true,
                     trustEnabled: true, dnsRunning: true, portHelperInstalled: true)
    }

    private nonisolated static let shop = Site(name: "shop", path: "/tmp/shop", kind: .parked,
                                               secured: true, php: PHPVersion(major: 8, minor: 5),
                                               pinned: false)

    /// A fetch that signals when it has started and answers only when released.
    private final class SlowFetch: @unchecked Sendable {
        let entered: AsyncStream<Void>
        private let enteredContinuation: AsyncStream<Void>.Continuation
        let answers: AsyncStream<EngineStatus>
        private let answerContinuation: AsyncStream<EngineStatus>.Continuation
        private let counter = Counter()

        init() {
            (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
            (answers, answerContinuation) = AsyncStream<EngineStatus>.makeStream()
        }

        var count: Int { counter.value }

        func release(_ status: EngineStatus) {
            answerContinuation.yield(status)
            answerContinuation.finish()
        }

        nonisolated func fetch() async throws -> EngineStatus {
            counter.increment()
            enteredContinuation.yield()
            for await status in answers { return status }
            throw ClientError.daemonNotRunning
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            stored += 1
        }
    }

    func testACancelledCheckPublishesNothing() async {
        let slow = SlowFetch()
        let status = Self.sampleStatus(with: Self.shop)
        let model = DoctorModel(fetchStatus: { try await slow.fetch() },
                                diagnose: { status, _ in
                                    DoctorReport(global: [], sites: [
                                        .init(site: "shop", host: "shop.test",
                                              php: status.sites[0].php,
                                              url: "https://shop.test", checks: []),
                                    ])
                                })
        var iterator = slow.entered.makeAsyncIterator()
        let task = Task { await model.check() }
        await iterator.next()
        task.cancel()
        slow.release(status)
        await task.value

        XCTAssertNil(model.report)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.sites.isEmpty)
        XCTAssertFalse(model.isChecking)
    }

    func testASecondCheckWhileOneIsRunningIsIgnored() async {
        let slow = SlowFetch()
        let status = Self.sampleStatus(with: Self.shop)
        let expected = DoctorReport(global: [], sites: [
            .init(site: "shop", host: "shop.test", php: Self.shop.php,
                  url: "https://shop.test", checks: []),
        ])
        let model = DoctorModel(fetchStatus: { try await slow.fetch() },
                                diagnose: { _, _ in expected })
        var iterator = slow.entered.makeAsyncIterator()
        let task = Task { await model.check() }
        await iterator.next()
        await model.check()

        XCTAssertTrue(model.isChecking)
        XCTAssertNil(model.report)

        slow.release(status)
        await task.value

        XCTAssertEqual(model.report, expected)
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(slow.count, 1)
    }

    func testCheckPublishesAFreshReportAndTheSites() async {
        let status = status()
        let expected = DoctorReport(global: [], sites: [
            .init(site: "shop", host: "shop.test", php: PHPVersion(major: 8, minor: 5),
                  url: "https://shop.test", checks: []),
        ])
        let model = DoctorModel(fetchStatus: { status }, diagnose: { _, _ in expected })
        model.target = "shop"

        await model.check()

        XCTAssertEqual(model.report, expected)
        XCTAssertEqual(model.sites.map(\.name), ["shop"])
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.error)
    }

    func testAStatusFailureBecomesTheDaemonRowNotAnErrorScreen() async {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let model = DoctorModel(fetchStatus: { throw ClientError.daemonNotRunning },
                                diagnose: { _, _ in
                                    calls.count += 1
                                    return DoctorReport(global: [], sites: [])
                                })

        await model.check()

        XCTAssertEqual(model.report?.global.map(\.id), ["daemon"])
        XCTAssertEqual(model.report?.global.first?.outcome, .failed)
        XCTAssertEqual(model.report?.global.first?.detail, Messages.daemonNotRunning)
        XCTAssertEqual(model.report?.global.first?.fix, "paddock start")
        XCTAssertEqual(model.error, Messages.daemonNotRunning)
        XCTAssertEqual(calls.count, 0)
    }

    func testATargetThatNoLongerExistsIsCleared() async {
        let model = DoctorModel(fetchStatus: { Self.sampleStatus(with: Self.shop) }, diagnose: { _, _ in
            DoctorReport(global: [], sites: [])
        })
        model.target = "gone"

        await model.check()

        XCTAssertNil(model.target)
    }
}
