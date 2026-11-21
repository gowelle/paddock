import CoreServices
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

    /// Events FSEvents flags as lost or coalesced (or the folder itself changing) count as a code change, whatever
    /// the path; the folder itself changing also says so, so the manager can look at the site again.
    func testFlaggedEventsCountAsChanges() {
        let root = "/p/shop"
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        XCTAssertEqual(SiteWatcher.changes(for: [("/p/shop/README.md", none)], root: root), SiteWatcher.Changes())
        XCTAssertEqual(SiteWatcher.changes(for: [("/p/shop/app/A.php", none)], root: root), SiteWatcher.Changes(code: true))
        XCTAssertEqual(SiteWatcher.changes(for: [("/p/shop/paddock.json", none)], root: root),
                       SiteWatcher.Changes(tasksFile: true))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped] {
            XCTAssertEqual(SiteWatcher.changes(for: [("/p/shop/vendor", FSEventStreamEventFlags(flag))], root: root),
                           SiteWatcher.Changes(code: true), "flag \(flag)")
        }
        XCTAssertEqual(SiteWatcher.changes(for: [("/p/shop", FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))],
                                           root: root),
                       SiteWatcher.Changes(code: true, rootChanged: true))
        XCTAssertEqual(SiteWatcher.excludedFolders, ["vendor", "node_modules", ".git", "storage"])
    }

    /// When a code change happened: the latest of its files' own times (a rename into place updates ctime); a
    /// file that is gone, or an event FSEvents flagged as lost, has no time of its own and counts as now (nil).
    func testWhenACodeChangeHappened() {
        let root = "/p/shop"
        let none = FSEventStreamEventFlags(kFSEventStreamEventFlagNone)
        let t1 = Date(timeIntervalSince1970: 1000), t2 = Date(timeIntervalSince1970: 2000)
        let times = ["/p/shop/app/A.php": t1, "/p/shop/app/B.php": t2, "/p/shop/README.md": Date(timeIntervalSince1970: 9999)]
        let both = SiteWatcher.changes(for: [("/p/shop/app/A.php", none), ("/p/shop/app/B.php", none),
                                             ("/p/shop/README.md", none)], root: root, changedAt: { times[$0] })
        XCTAssertEqual(both, SiteWatcher.Changes(code: true, codeChangedAt: t2), "only code files count")
        let gone = SiteWatcher.changes(for: [("/p/shop/app/A.php", none), ("/p/shop/app/Gone.php", none)], root: root,
                                       changedAt: { times[$0] })
        XCTAssertEqual(gone, SiteWatcher.Changes(code: true), "a deleted file: now")
        XCTAssertEqual(SiteWatcher.Changes(code: true, codeChangedAt: t1).merged(with: SiteWatcher.Changes(code: true, codeChangedAt: t2)),
                       SiteWatcher.Changes(code: true, codeChangedAt: t2))
        XCTAssertEqual(SiteWatcher.Changes(code: true, codeChangedAt: t1).merged(with: SiteWatcher.Changes(code: true)),
                       SiteWatcher.Changes(code: true))
        XCTAssertEqual(SiteWatcher.Changes().merged(with: SiteWatcher.Changes(code: true, codeChangedAt: t1)),
                       SiteWatcher.Changes(code: true, codeChangedAt: t1))
    }

    func testListeningAddresses() {
        XCTAssertEqual(ListeningAddress("*:8080"), ListeningAddress(host: "*", port: 8080))
        XCTAssertEqual(ListeningAddress("[::]:6001")?.port, 6001)
        XCTAssertEqual(ListeningAddress("[fe80::1]:6001")?.host, "[fe80::1]")
        XCTAssertNil(ListeningAddress("nonsense"))
        for local in ["127.0.0.1:80", "127.0.0.2:80", "127.255.0.9:1", "[::1]:80"] {
            XCTAssertTrue(ListeningAddress(local)!.isLoopback, local)
        }
        for open in ["*:80", "0.0.0.0:80", "[::]:80", "192.168.1.5:80", "128.0.0.1:80", "[fe80::1]:80"] {
            XCTAssertFalse(ListeningAddress(open)!.isLoopback, open)
        }
        XCTAssertTrue(ListeningAddress("0.0.0.0:80")!.isEverywhere)
        XCTAssertFalse(ListeningAddress("192.168.1.5:80")!.isEverywhere)
        XCTAssertFalse(ServiceManager.isLoopback("127.0.0.2:80"), "services keep their own, stricter rule")
    }

    func testTheSentences() {
        XCTAssertEqual(Messages.listening(ListeningAddress("*:8080")!),
                       "Listening on all network interfaces (port 8080). Add --host=127.0.0.1 or similar to keep it on this Mac.")
        XCTAssertEqual(Messages.listening(ListeningAddress("192.168.1.5:3000")!),
                       "Listening on 192.168.1.5 (port 3000), which other devices can reach.")
        XCTAssertEqual(Messages.listening(ListeningAddress("*:0")!),
                       "Listening on all network interfaces. Add --host=127.0.0.1 or similar to keep it on this Mac.",
                       "never port 0")
        XCTAssertNil(Messages.listening(ListeningAddress("127.0.0.1:80")!))
    }
}
