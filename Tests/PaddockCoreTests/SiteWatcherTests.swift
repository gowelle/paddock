import XCTest
@testable import PaddockCore

/// What a code change is (the path filter), when it fires (debounce), and which commands restart on one by
/// default.
final class SiteWatcherTests: XCTestCase {
    func testWhichPathsCount() {
        let code: [String] = [
            "app/Models/User.php", "routes/web.php", "artisan.php", ".env", ".env.local", "config/.env.testing",
            "composer.lock", "app/Jobs/Deep/Nested/Job.php", "resources/views/home.blade.php",
        ]
        for path in code { XCTAssertEqual(SiteWatcher.classify(path), .code, path) }
        XCTAssertEqual(SiteWatcher.classify("paddock.json"), .tasksFile)
        let ignored: [String] = [
            "vendor/laravel/framework/src/Foundation/Application.php", "node_modules/x/index.php",
            "resources/js/node_modules/y.php", "storage/logs/laravel.log", "storage/framework/views/abc.php",
            "bootstrap/cache/config.php", ".git/HEAD", ".git/objects/ab/cdef.php", "public/build/manifest.php",
            "public/hot", ".idea/workspace.php", "app/.hidden/Thing.php", "README.md", "app/Foo.php~",
            ".Foo.php.swp", "package.json", "composer.json", "config/paddock.json", "public/index.html",
            "bootstrap/app.phpx",
        ]
        for path in ignored { XCTAssertEqual(SiteWatcher.classify(path), .ignored, path) }
        XCTAssertEqual(SiteWatcher.classify("bootstrap/app.php"), .code, "only bootstrap/cache is ignored")
        XCTAssertEqual(SiteWatcher.classify("public/index.php"), .code, "only public/build and public/hot")
    }

    /// One second of quiet after the last change, but never more than five seconds after the first.
    func testTheDebounce() {
        let debounce = SiteWatcher.Debounce(quiet: 1, maximumWait: 5)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(debounce.fireTime(firstChange: start, lastChange: start), start.addingTimeInterval(1))
        XCTAssertEqual(debounce.fireTime(firstChange: start, lastChange: start.addingTimeInterval(2.5)),
                       start.addingTimeInterval(3.5))
        XCTAssertEqual(debounce.fireTime(firstChange: start, lastChange: start.addingTimeInterval(4.6)),
                       start.addingTimeInterval(5), "a long run of changes fires at most five seconds after the first")
    }

    func testWhichCommandsRestartOnChangeByDefault() {
        let yes = [
            "php artisan queue:work", "php artisan queue:work redis --queue=default,scout --tries=3",
            "php artisan queue:listen", "php artisan horizon", "php ./artisan reverb:start --host=127.0.0.1 --port=8080",
            "php artisan octane:start", "php artisan schedule:work", "php artisan pulse:check", "php artisan pulse:work",
            "cd backend && php artisan queue:work",
        ]
        for run in yes { XCTAssertTrue(TaskDefinition.restartsOnChangeByDefault(run), run) }
        let no = [
            "php artisan migrate", "php artisan horizon:status", "php artisan queue:workers", "php artisan queue:work-ish",
            "bun run dev", "php partisan queue:work", "php artisans queue:work", "npm run queue:work",
            "php artisan", "queue:work artisan",
        ]
        for run in no { XCTAssertFalse(TaskDefinition.restartsOnChangeByDefault(run), run) }
        let unset = TaskDefinition(run: "php artisan queue:work", restartOnChange: nil, autostart: nil, stopSeconds: nil)
        XCTAssertTrue(unset.restartsOnChange)
        let off = TaskDefinition(run: "php artisan queue:work", restartOnChange: false, autostart: nil, stopSeconds: nil)
        XCTAssertFalse(off.restartsOnChange, "the file can turn it off")
        let on = TaskDefinition(run: "bun run dev", restartOnChange: true, autostart: nil, stopSeconds: nil)
        XCTAssertTrue(on.restartsOnChange, "and on")
    }

    func testTheSentences() {
        XCTAssertEqual(Messages.listeningEverywhere(port: 8080),
                       "Listening on all network interfaces (port 8080). Add --host=127.0.0.1 or similar to keep it on this Mac.")
        XCTAssertEqual(SiteWatcher.port(of: "*:8080"), 8080)
        XCTAssertEqual(SiteWatcher.port(of: "[::]:6001"), 6001)
        XCTAssertNil(SiteWatcher.port(of: "nonsense"))
    }
}
