import Darwin
import Foundation
import dnssd

/// Announces the LAN names as mDNS A records pointing at this Mac. One connection owns every record;
/// a small thread registers, withdraws and answers queries so callers never block on the network.
public final class MDNSAdvertiser: LANAdvertising, @unchecked Sendable {
    private let lock = NSCondition()
    private var pending: (hosts: [String], address: String)?
    private var stopping = false
    private var finished = false

    private var connection: DNSServiceRef?
    private var records: [String: DNSRecordRef] = [:]

    public init() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.paddock.mdns"
        thread.start()
    }

    deinit { stop() }

    public func advertise(hosts: [String], address: String) {
        lock.lock()
        pending = (hosts, address)
        lock.broadcast()
        lock.unlock()
    }

    /// Withdraws the names and waits (briefly) for the connection to close. Safe to call twice.
    public func stop() {
        lock.lock()
        stopping = true
        pending = nil
        lock.broadcast()
        let deadline = Date().addingTimeInterval(1)
        while !finished, Date() < deadline { lock.wait(until: deadline) }
        lock.unlock()
    }

    private func run() {
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError,
              let connection else {
            finish()
            return
        }
        while true {
            lock.lock()
            let change = pending
            let stopping = self.stopping
            pending = nil
            lock.unlock()
            if stopping { break }
            if let change { apply(change, on: connection) }
            process(connection)
        }
        withdrawAll(on: connection)
        DNSServiceRefDeallocate(connection)
        self.connection = nil
        finish()
    }

    /// Replaces every record: an A record's address is fixed when it is registered.
    private func apply(_ change: (hosts: [String], address: String), on connection: DNSServiceRef) {
        withdrawAll(on: connection)
        guard !change.hosts.isEmpty else { return }
        let octets = change.address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return }
        for host in change.hosts {
            let name = host.hasSuffix(".") ? host : host + "."
            var record: DNSRecordRef?
            var bytes = octets
            let error = bytes.withUnsafeMutableBytes { buffer in
                DNSServiceRegisterRecord(
                    connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0,
                    name, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                    UInt16(buffer.count), buffer.baseAddress, 120, recordChanged, nil)
            }
            if error == kDNSServiceErr_NoError, let record {
                records[host] = record
            } else {
                note("mDNS couldn't advertise \(host) (error \(error))")
            }
        }
    }

    private func withdrawAll(on connection: DNSServiceRef) {
        for (host, record) in records where DNSServiceRemoveRecord(connection, record, 0)
            != kDNSServiceErr_NoError {
            note("mDNS couldn't withdraw \(host)")
        }
        records.removeAll()
    }

    /// Answers pending queries; waits up to a second so `stop` is never far behind.
    private func process(_ connection: DNSServiceRef) {
        var descriptor = pollfd(fd: DNSServiceRefSockFD(connection), events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 1000) > 0, DNSServiceProcessResult(connection) != kDNSServiceErr_NoError {
            note("mDNS stopped answering")
        }
    }

    private func finish() {
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("paddockd: \(message)\n".utf8))
    }
}

/// Conflicts (another device already answering for the name) arrive here; the names simply don't resolve.
private func recordChanged(_ service: DNSServiceRef?, _ record: DNSRecordRef?, _ flags: DNSServiceFlags,
                           _ error: DNSServiceErrorType, _ context: UnsafeMutableRawPointer?) {
    guard error != kDNSServiceErr_NoError else { return }
    FileHandle.standardError.write(Data("paddockd: mDNS record failed (error \(error))\n".utf8))
}
