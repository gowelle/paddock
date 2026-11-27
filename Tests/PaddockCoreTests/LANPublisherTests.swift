import PaddockTestSupport
import XCTest
@testable import PaddockCore

final class LANPublisherTests: XCTestCase {
    func testAdvertisesTheChosenNamesAtTheCurrentAddress() {
        let advertiser = RecordingLANAdvertiser()
        let publisher = LANPublisher(advertiser: advertiser, address: { "192.168.1.20" },
                                     interval: 0.01)
        publisher.start(hosts: ["blog.paddock.local"])
        XCTAssertTrue(waitFor { advertiser.last == .init(hosts: ["blog.paddock.local"],
                                                         address: "192.168.1.20") })

        publisher.update(hosts: ["blog.paddock.local", "shop.paddock.local"])
        XCTAssertTrue(waitFor { advertiser.last?.hosts == ["blog.paddock.local", "shop.paddock.local"] })
        publisher.stop()
        XCTAssertTrue(advertiser.stopped)
    }

    func testRepublishesWhenTheLanAddressChanges() {
        let advertiser = RecordingLANAdvertiser()
        let address = LockedBox("10.0.0.5")
        let publisher = LANPublisher(advertiser: advertiser, address: { address.value },
                                     interval: 0.01)
        publisher.start(hosts: ["blog.paddock.local"])
        XCTAssertTrue(waitFor { advertiser.last?.address == "10.0.0.5" })

        address.value = "10.0.0.9"
        XCTAssertTrue(waitFor { advertiser.last?.address == "10.0.0.9" })
        XCTAssertEqual(advertiser.calls.filter { $0.address == "10.0.0.9" }.count, 1,
                       "unchanged polls don't register again")
        publisher.stop()
    }

    func testWaitsForAnAddressAndKeepsItsNamesWhenSharingStops() {
        let advertiser = RecordingLANAdvertiser()
        let address = LockedBox<String?>(nil)
        let publisher = LANPublisher(advertiser: advertiser, address: { address.value },
                                     interval: 0.01)
        publisher.start(hosts: ["blog.paddock.local"])
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertTrue(advertiser.calls.isEmpty, "nothing to advertise without an address")

        address.value = "192.168.0.10"
        XCTAssertTrue(waitFor { advertiser.last?.hosts == ["blog.paddock.local"] })
        publisher.update(hosts: [])
        XCTAssertTrue(waitFor { advertiser.last?.hosts == [] }, "no sites shared: withdraw the names")
        publisher.stop()
    }

    func testWithdrawsTheNamesEvenWithoutAnAddress() {
        let advertiser = RecordingLANAdvertiser()
        let address = LockedBox<String?>("192.168.0.10")
        let publisher = LANPublisher(advertiser: advertiser, address: { address.value },
                                     interval: 0.01)
        publisher.start(hosts: ["blog.paddock.local"])
        XCTAssertTrue(waitFor { advertiser.last?.hosts == ["blog.paddock.local"] })

        address.value = nil
        publisher.update(hosts: [])
        XCTAssertTrue(waitFor { advertiser.last?.hosts == [] },
                      "turning sharing off withdraws names even while the network is away")
        publisher.stop()
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}
