import Foundation

/// Renders the Caddyfile: every request goes through the vendored Valet router over FastCGI,
/// and Valet's `X-Accel-Redirect` answers for static files are served by Caddy itself.
public enum Caddyfile {
    /// Prefix Valet puts after the leading "/" in `X-Accel-Redirect`
    /// (`VALET_STATIC_PREFIX` in Resources/router/server.php).
    static let valetStaticPrefix = "41c270e4-5535-4daa-b23e-c269744c2f45"

    public static func render(sites: [Site], defaultPHP: PHPVersion, paths: Paths,
                              settings: Settings) -> String {
        let serverPHP = Bundled.resources.appendingPathComponent("router/server.php").path
        var out = """
        {
            admin \(quote("unix/" + paths.caddyAdminSocket.path))
            http_port \(settings.httpPort)
            https_port \(settings.httpsPort)
            default_bind 127.0.0.1 [::1]
            local_certs
            skip_install_trust
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

        http://*.\(settings.tld) {
            import paddock_php \(quote(paths.fpmSocket(defaultPHP).path))
        }

        """

        // {host} carries no port, so a non-default HTTPS port has to be spelled out in the redirect.
        let httpsAuthority = settings.httpsPort == 443 ? "{host}" : "{host}:\(settings.httpsPort)"

        for site in sites.sorted(by: { $0.name < $1.name }) where site.secured || site.pinned {
            let socket = quote(paths.fpmSocket(site.php).path)
            if site.secured {
                out += """

                https://\(site.host) {
                    tls internal
                    import paddock_php \(socket)
                }

                http://\(site.host) {
                    redir https://\(httpsAuthority){uri}
                }

                """
            } else {
                out += """

                http://\(site.host) {
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
