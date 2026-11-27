import Foundation
import PaddockCore

/// Records what the engine would announce over mDNS, without sending anything on the network.
public final class RecordingLANAdvertiser: LANAdvertising, @unchecked Sendable {
    public struct Call: Equatable {
        public let hosts: [String]
        public let address: String

        public init(hosts: [String], address: String) {
            self.hosts = hosts
            self.address = address
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var wasStopped = false

    public init() {}

    public var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var last: Call? { calls.last }
    public var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasStopped
    }

    public func advertise(hosts: [String], address: String) {
        lock.lock()
        recorded.append(Call(hosts: hosts, address: address))
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        wasStopped = true
        lock.unlock()
    }
}
