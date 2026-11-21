import Foundation

/// Generates the PHP-FPM pool config and the default php.ini.
public enum FPMConfig {
    public static func render(version v: PHPVersion, paths: Paths) -> String {
        """
        [global]
        pid = \(paths.run.appendingPathComponent("php-fpm-\(v).pid").path)
        error_log = \(paths.log.appendingPathComponent("php-fpm-\(v).log").path)
        daemonize = no

        [www]
        listen = \(paths.fpmSocket(v).path)
        pm = ondemand
        pm.max_children = 10
        pm.process_idle_timeout = 60s
        php_admin_value[error_log] = \(paths.log.appendingPathComponent("php-\(v).log").path)

        """
    }

    /// Writes `config/fpm/<v>.conf`, replacing any previous copy.
    @discardableResult
    public static func write(version v: PHPVersion, paths: Paths) throws -> URL {
        let url = paths.config.appendingPathComponent("fpm", isDirectory: true)
            .appendingPathComponent("\(v).conf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(render(version: v, paths: paths).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Development defaults; `date.timezone` is deliberately left unset.
    public static func defaultIni(version v: PHPVersion, paths: Paths) -> String {
        """
        memory_limit = 512M
        upload_max_filesize = 128M
        post_max_size = 128M
        max_execution_time = 120
        display_errors = On
        error_reporting = E_ALL
        extension_dir = \(paths.phpDir(v).appendingPathComponent("ext").path)

        """
    }
}
