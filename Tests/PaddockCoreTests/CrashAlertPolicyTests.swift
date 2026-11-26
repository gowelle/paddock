import XCTest
@testable import PaddockCore

final class CrashAlertPolicyTests: XCTestCase {
    /// Each item is announced at most once per ten minutes; another item has its own clock.
    func testAnItemIsAnnouncedAtMostOncePerTenMinutes() {
        var policy = CrashAlertPolicy()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(policy.shouldAnnounce("task:shop:queue", at: start))
        policy.record("task:shop:queue", at: start)
        XCTAssertFalse(policy.shouldAnnounce("task:shop:queue", at: start.addingTimeInterval(599)))
        XCTAssertTrue(policy.shouldAnnounce("task:shop:queue", at: start.addingTimeInterval(600)))
        XCTAssertTrue(policy.shouldAnnounce("service:mail", at: start), "another item's first crash is news")
    }
}
