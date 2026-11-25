import Darwin
import Foundation

extension Doctor {
    /// The numeric addresses `host` resolves to (getaddrinfo).
    public static func probeAddresses(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &text,
                           socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: text)
                if !addresses.contains(address) { addresses.append(address) }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }

    /// A folder that exists, is a folder, and can be read.
    public static func folderIsReadable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: path)
    }

    /// The site's address, on Paddock's configured ports when they are not 80/443.
    public static func siteAddress(_ site: Site, settings: Settings = .current) -> URL {
        var components = URLComponents()
        components.scheme = site.secured ? "https" : "http"
        components.host = site.host
        let port = site.secured ? settings.httpsPort : settings.httpPort
        if port != (site.secured ? 443 : 80) { components.port = port }
        return components.url ?? URL(string: site.url) ?? URL(fileURLWithPath: "/")
    }

    /// One GET with a 5-second timeout and default TLS trust: what a browser would get.
    public static func probeHTTP(_ url: URL) async throws -> DoctorProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = ContinuousClock()
        let start = clock.now
        let (_, response) = try await session.data(for: URLRequest(url: url))
        let elapsed = start.duration(to: clock.now)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let milliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return DoctorProbe(statusCode: http.statusCode, milliseconds: milliseconds)
    }

    /// The newest error in the part of the site's own log the Logs window reads (the last 256 KB).
    public static func logFindingFor(_ site: Site) -> DoctorLogFinding {
        let root = URL(fileURLWithPath: site.path, isDirectory: true)
        guard let source = LogCatalog.siteLogs(in: root).first else { return .none }
        let file = source.url.lastPathComponent
        guard let tail = MCPLogReader.tail(of: source.url, count: 4000, containing: nil, inside: root) else {
            return .unreadable(file: file)
        }
        var entries: [LogEntry] = []
        var parser = LogParser()
        parser.append(tail.lines, to: &entries)
        guard let error = entries.last(where: { $0.isProblem }) else { return .noErrors(file: file) }
        return .error(file: file, line: error.text)
    }
}
