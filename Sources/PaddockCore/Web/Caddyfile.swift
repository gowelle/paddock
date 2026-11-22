import Foundation

/// Renders the Caddyfile: every request goes through the vendored Valet router over FastCGI,
/// and Valet's `X-Accel-Redirect` answers for static files are served by Caddy itself.
public enum Caddyfile {
    /// Prefix Valet puts after the leading "/" in `X-Accel-Redirect`
    /// (`VALET_STATIC_PREFIX` in Resources/router/server.php).
    static let valetStaticPrefix = "41c270e4-5535-4daa-b23e-c269744c2f45"

    /// The name of Paddock's local certificate authority. Its root's common name starts with it; Caddy's
    /// default ("Caddy Local Authority") is shared with other Caddy-based tools, whose roots browsers
    /// could pick instead by name.
    public static let authorityName = "Paddock Local Authority"

    /// `namesAuthority: false` leaves Caddy's default CA names (tests only: it makes an old home).
    /// `proxies`: site name -> its approved routes (path prefix -> port on 127.0.0.1). A site with routes gets
    /// its own block(s) where each route is handled before the PHP router; every other site renders as without.
    public static func render(sites: [Site], defaultPHP: PHPVersion, paths: Paths,
                              settings: Settings, namesAuthority: Bool = true,
                              proxies: [String: [String: Int]] = [:], dumpsTo: Int? = nil) -> String {
        // With a listener for dumps, every PHP request is told to send its `dump()` output there
        // (`DumpDestination`): two FastCGI variables, which PHP shows a site as `$_SERVER` entries.
        let dumps = DumpDestination.environment(port: dumpsTo).sorted { $0.key < $1.key }
            .map { "\n            env \($0.key) \(quote($0.value))" }.joined()
        let serverPHP = Bundled.resources.appendingPathComponent("router/server.php").path
        let httpBind = quote("unix/" + paths.httpSocket.path)
        let httpsBind = quote("unix/" + paths.httpsSocket.path)
        let pki = namesAuthority ? """

                pki {
                    ca local {
                        name \(quote(authorityName))
                        root_cn \(quote(authorityName + " - Root"))
                        intermediate_cn \(quote(authorityName + " - Intermediate"))
                    }
                }
            """ : ""
        var out = """
        {
            admin \(quote("unix/" + paths.caddyAdminSocket.path))
            http_port \(settings.httpPort)
            https_port \(settings.httpsPort)
            local_certs
            skip_install_trust\(pki)
            auto_https disable_redirects
            storage file_system \(quote(paths.caddyData.path))
        }

        (paddock_php) {
            reverse_proxy "unix/{args[0]}" {
                transport fastcgi {
                    env SCRIPT_FILENAME \(quote(serverPHP))
                    env PADDOCK_ROUTER_HOME \(quote(paths.routerHome.path))\(dumps)
                }
                @accel header X-Accel-Redirect *
                handle_response @accel {
                    root * /
                    rewrite * {rp.header.X-Accel-Redirect}
                    uri strip_prefix /\(valetStaticPrefix)
                    file_server
                }
            }
        }

        # Every other host on the HTTP port, subdomains included (api.myapp.test). Only .test resolves
        # here, and the router picks the site from the host. Named site blocks below take precedence.
        # Caddy listens only on Unix sockets; the port helper forwards the HTTP and HTTPS ports to them.
        http:// {
            bind \(httpBind)
            import paddock_php \(quote(paths.fpmSocket(defaultPHP).path))
        }

        """

        // {host} carries no port, so a non-default HTTPS port has to be spelled out in the redirect.
        let httpsAuthority = settings.httpsPort == 443 ? "{host}" : "{host}:\(settings.httpsPort)"

        for site in sites.sorted(by: { $0.name < $1.name }) {
            let routes = proxyRoutes(proxies[site.name] ?? [:])
            guard site.secured || site.pinned || !routes.isEmpty else { continue }
            let socket = quote(paths.fpmSocket(site.php).path)
            if !routes.isEmpty {
                out += site.secured ? """

                https://\(site.host), https://*.\(site.host) {
                    bind \(httpsBind)
                    tls internal
                \(routed(routes, socket: socket))
                }

                http://\(site.host), http://*.\(site.host) {
                    bind \(httpBind)
                    redir https://\(httpsAuthority){uri}
                }

                """ : """

                http://\(site.host), http://*.\(site.host) {
                    bind \(httpBind)
                \(routed(routes, socket: socket))
                }

                """
            } else if site.secured {
                out += """

                https://\(site.host), https://*.\(site.host) {
                    bind \(httpsBind)
                    tls internal
                    import paddock_php \(socket)
                }

                http://\(site.host), http://*.\(site.host) {
                    bind \(httpBind)
                    redir https://\(httpsAuthority){uri}
                }

                """
            } else {
                out += """

                http://\(site.host), http://*.\(site.host) {
                    bind \(httpBind)
                    import paddock_php \(socket)
                }

                """
            }
        }
        return out
    }

    /// A site's routes as rendered: only prefixes that pass the file's own rule (checked again here) and ports in
    /// 1024...65535, longest prefix first.
    static func proxyRoutes(_ routes: [String: Int]) -> [(prefix: String, port: Int)] {
        routes.filter { SiteTasksFile.isProxyPath($0.key) && SiteTasksFile.proxyPorts.contains($0.value) }
            .map { (prefix: $0.key, port: $0.value) }
            .sorted { $0.prefix.count != $1.prefix.count ? $0.prefix.count > $1.prefix.count : $0.prefix < $1.prefix }
    }

    /// Inside a site block (indented one level): each route as `handle "<p>/*"` and `handle "<p>"` to
    /// 127.0.0.1:<port> (the path kept as it is; websockets pass through), then the PHP router for everything
    /// else, then a short plain 502 for a route whose port nothing listens on.
    static func routed(_ routes: [(prefix: String, port: Int)], socket: String) -> String {
        var lines: [String] = []
        for route in routes {
            for matcher in [route.prefix + "/*", route.prefix] {
                lines += ["    handle \(quote(matcher)) {", "        reverse_proxy 127.0.0.1:\(route.port)", "    }"]
            }
        }
        lines += ["    handle {", "        import paddock_php \(socket)", "    }", "    handle_errors 502 {"]
        for (index, route) in routes.enumerated() {
            lines.append("        @proxy\(index) path \(quote(route.prefix)) \(quote(route.prefix + "/*"))")
            lines.append("        respond @proxy\(index) \(quote(Messages.nothingListening(port: route.port, prefix: route.prefix))) 502")
        }
        lines.append("    }")
        return lines.joined(separator: "\n")
    }

    /// Double-quoted Caddyfile token: backslash and quote escaped so it parses as one token.
    static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
