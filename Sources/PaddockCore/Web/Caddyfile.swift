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
    public static func render(sites: [Site], defaultPHP: PHPVersion, paths: Paths,
                              settings: Settings, namesAuthority: Bool = true) -> String {
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
                    env PADDOCK_ROUTER_HOME \(quote(paths.routerHome.path))
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

        for site in sites.sorted(by: { $0.name < $1.name }) where site.secured || site.pinned {
            let socket = quote(paths.fpmSocket(site.php).path)
            if site.secured {
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

    /// Double-quoted Caddyfile token: backslash and quote escaped so it parses as one token.
    static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
