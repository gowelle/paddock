import Foundation

public struct Settings: Sendable {
    public var httpPort: Int = 80
    public var httpsPort: Int = 443
    public var dnsPort: Int = 53535
    public var tld = "test"

    public init() {}

    /// Defaults, overridden by PADDOCK_HTTP_PORT, PADDOCK_HTTPS_PORT and PADDOCK_DNS_PORT.
    public static var current: Settings {
        let env = ProcessInfo.processInfo.environment
        var s = Settings()
        if let v = env["PADDOCK_HTTP_PORT"].flatMap({ Int($0) }) { s.httpPort = v }
        if let v = env["PADDOCK_HTTPS_PORT"].flatMap({ Int($0) }) { s.httpsPort = v }
        if let v = env["PADDOCK_DNS_PORT"].flatMap({ Int($0) }) { s.dnsPort = v }
        return s
    }
}
