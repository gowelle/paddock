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
