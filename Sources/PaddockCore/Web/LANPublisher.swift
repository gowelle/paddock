import Foundation

/// Where LAN names are announced: an mDNS implementation in the app, a recorder in tests.
public protocol LANAdvertising: AnyObject, Sendable {
    /// Makes `hosts` resolve to `address`, replacing whatever was announced before. Empty withdraws them.
    func advertise(hosts: [String], address: String)
    /// Withdraws everything and stops.
    func stop()
}

/// Keeps the LAN names pointing at this Mac as its address changes. One instance per LAN listener run.
public final class LANPublisher: @unchecked Sendable {
    public typealias AddressSource = @Sendable () -> String?

    private let advertiser: any LANAdvertising
    private let address: AddressSource
    private let interval: TimeInterval
    private let lock = NSLock()
    private var hosts: [String] = []
    private var last: (hosts: [String], address: String)?
    private var stopped = false
    private var thread: Thread?

    /// `interval` is how often the address is checked (tests use a small value).
    public init(advertiser: any LANAdvertising,
                address: @escaping AddressSource = { LANAddress.primaryIPv4() },
                interval: TimeInterval = 5) {
        self.advertiser = advertiser
        self.address = address
        self.interval = interval
    }

    /// Starts announcing `hosts` now, and on every address change until `stop`.
    public func start(hosts: [String]) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        self.hosts = hosts
        if thread == nil {
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "app.paddock.lan-mdns"
            self.thread = thread
            thread.start()
        }
        lock.unlock()
        advertiseIfChanged()
    }

    public func update(hosts: [String]) {
        lock.lock()
        self.hosts = hosts
        lock.unlock()
        advertiseIfChanged()
    }

    public func stop() {
        lock.lock()
        stopped = true
        hosts = []
        last = nil
        lock.unlock()
        advertiser.stop()
    }

    private func run() {
        while true {
            lock.lock()
            let stopped = self.stopped
            lock.unlock()
            if stopped { return }
            advertiseIfChanged()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func advertiseIfChanged() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let hosts = self.hosts
        let last = self.last
        lock.unlock()
        if hosts.isEmpty {
            // Withdrawing needs no address: the last run may still have names out while the network is away.
            guard last?.hosts.isEmpty != true else { return }
            advertiser.advertise(hosts: [], address: "")
            lock.lock()
            if !stopped { self.last = ([], "") }
            lock.unlock()
            return
        }
        guard let address = address() else { return }
        guard last?.hosts != hosts || last?.address != address else { return }
        advertiser.advertise(hosts: hosts, address: address)
        lock.lock()
        if !stopped { self.last = (hosts, address) }
        lock.unlock()
    }
}
