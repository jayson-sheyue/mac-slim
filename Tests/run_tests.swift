import Foundation
import CryptoKit

@main
struct MacSlimTests {
    @MainActor
    static func main() async {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--instance-probe" {
            do {
                guard let lease = try InstanceLease.acquire(at: URL(fileURLWithPath: CommandLine.arguments[2])) else { exit(75) }
                try lease.record(["pid": String(ProcessInfo.processInfo.processIdentifier)])
                withExtendedLifetime(lease) { exit(0) }
            } catch { exit(76) }
        }
        var passed = 0
        var failed = 0
        func check(_ value: Bool, _ message: String) {
            if value { passed += 1; print("[PASS] " + message) }
            else { failed += 1; print("[FAIL] " + message) }
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: FileSafety.canonicalPath(fm.temporaryDirectory.appendingPathComponent("macslim-tests-" + UUID().uuidString).path))
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("用户 Home").path
        let applications = root.appendingPathComponent("Applications").path
        let trash = root.appendingPathComponent("Trash").path
        let oldDate = Date().addingTimeInterval(-60 * 86400)
        let env = ScanEnvironment(homeDirectory: home, applicationDirectories: [applications])
        let inactive: @Sendable () -> ActivitySnapshot = { ActivitySnapshot() }
        func dir(_ path: String) throws { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        func file(_ path: String, old: Bool = true, megabytes: Int = 1) throws {
            try dir(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            try Data(repeating: 65, count: megabytes * 1024 * 1024).write(to: URL(fileURLWithPath: path))
            if old { try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: path) }
        }
        func ageTree(_ path: String) throws {
            if let e = fm.enumerator(atPath: path) {
                for case let child as String in e {
                    let p = path + "/" + child
                    if (try fm.attributesOfItem(atPath: p)[.type]) as? FileAttributeType != .typeSymbolicLink {
                        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: p)
                    }
                }
            }
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        }
        func item(_ path: String, tier: CleanupTier = .safe, category: CleanupCategory = .browserAndAppCache) throws -> ScanItem {
            ScanItem(title: URL(fileURLWithPath: path).lastPathComponent, appName: "Fixture", category: category, tier: tier, path: path,
                     reason: "fixture", impactNote: "fixture", stamp: try FileSafety.tree(path))
        }
        do {
            try dir(home); try dir(applications); try dir(trash)
            let leaseURL = root.appendingPathComponent("runtime.lock")
            var lease = try InstanceLease.acquire(at: leaseURL)
            check(lease != nil, "First process owns the runtime lock")
            try lease?.record(["pid": "fixture", "path": "/Applications/MacSlim.app"])
            let probePath = FileSafety.canonicalPath(CommandLine.arguments[0])
            check(ProcessRunner.run(probePath, ["--instance-probe", leaseURL.path]).status == 75, "Independent second process cannot own the runtime lock")
            lease = nil
            check(ProcessRunner.run(probePath, ["--instance-probe", leaseURL.path]).status == 0, "Runtime lock releases after owner exits")
            let redirectedLock = root.appendingPathComponent("redirected.lock")
            try fm.createSymbolicLink(atPath: redirectedLock.path, withDestinationPath: leaseURL.path)
            do { _ = try InstanceLease.acquire(at: redirectedLock); check(false, "Symlink lock must be rejected") }
            catch { check(true, "Runtime lock rejects symlink redirection") }
            check(RuntimeIdentity.isCanonical("/Applications/MacSlim.app") && !RuntimeIdentity.isCanonical("/private/tmp/MacSlim.app"), "Only the canonical installed application is a normal runtime entry")
            for path in env.writableRoots { try dir(path) }
            let shipit = home + "/Library/Caches/io.example.NovelEditor.ShipIt/update.old"
            try file(shipit + "/NovelEditor.app/Contents/MacOS/NovelEditor")
            try fm.createSymbolicLink(atPath: shipit + "/link", withDestinationPath: "NovelEditor.app")
            var times = [timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0)]
            _ = (shipit + "/link").withCString { lutimes($0, &times) }
            try ageTree(shipit)
            let recentShipit = home + "/Library/Caches/io.example.NovelEditor.ShipIt/update.recent"
            try file(recentShipit + "/updater.bin", old: false)
            let sparkle = home + "/Library/Caches/io.example.Unlisted/org.sparkle-project.Sparkle/Installation/archive.zip"
            try file(sparkle)
            let meeting = home + "/Library/Containers/io.example.conference/Data/Library/Global/UpdatePackages/previous.pkg"
            try file(meeting)
            let containerSparkle = home + "/Library/Containers/io.example.sparkle/Data/Library/Caches/io.example.sparkle/org.sparkle-project.Sparkle/Installation/old.zip"
            try file(containerSparkle)
            let lark = home + "/Library/Application Support/LarkShell/update/old.pkg"
            try file(lark)
            let google = home + "/Library/Application Support/Google/GoogleUpdater/crx_cache/old.crx"
            try file(google)
            let cache = home + "/Library/Caches/io.example.UnknownCache/历史 缓存.bin"
            try file(cache)
            let appCache = home + "/Library/Application Support/NovelEditor/Cache/render.bin"
            try file(appCache)
            let log = home + "/Library/Logs/中文 空格 App/debug.log"
            try file(log)
            let recentLog = home + "/Library/Logs/中文 空格 App/today.log"
            try file(recentLog, old: false)
            let swCache = home + "/Library/Application Support/BrowserVendor/Browser/Profile 2/Service Worker/CacheStorage/site-cache"
            try file(swCache + "/resources.bin"); try ageTree(swCache)
            let cookies = home + "/Library/Caches/io.example.credentials/session/Cookies"
            try file(cookies); try ageTree(URL(fileURLWithPath: cookies).deletingLastPathComponent().path)
            let cookieWAL = home + "/Library/Caches/io.example.credentials/Cookies-wal"
            try file(cookieWAL)
            let privateDB = home + "/Library/Application Support/NovelEditor/User/globalStorage/state.vscdb"
            try file(privateDB)
            let lockedLogs = home + "/Library/Logs/Locked"
            try dir(lockedLogs)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedLogs)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedLogs) }
            let privateChat = home + "/Library/Application Support/NovelEditor/chats/messages.sqlite"
            try file(privateChat)
            let pwGo = home + "/Library/Caches/ms-playwright-go/driver-1/node"
            try file(pwGo)
            let pwRoot = home + "/Library/Caches/ms-playwright"
            try dir(pwRoot + "/.links")
            let package = root.appendingPathComponent("playwright package").path
            try dir(package)
            try Data("{\"browsers\":[{\"name\":\"chromium\",\"revision\":\"1200\",\"revisionOverrides\":{\"mac\":\"1201\"}}]}".utf8).write(to: URL(fileURLWithPath: package + "/browsers.json"))
            try Data(package.utf8).write(to: URL(fileURLWithPath: pwRoot + "/.links/project"))
            for rev in ["1199", "1200", "1201"] { try file(pwRoot + "/chromium-" + rev + "/chrome"); try ageTree(pwRoot + "/chromium-" + rev) }
            let app = applications + "/NovelEditor.app"
            let versions = app + "/Contents/Frameworks/Engine.framework/Versions"
            try file(versions + "/1.0/Engine"); try file(versions + "/2.0/Engine")
            try fm.createSymbolicLink(atPath: versions + "/Current", withDestinationPath: "2.0")
            let plist: [String: Any] = ["CFBundleIdentifier": "io.example.NovelEditor", "CFBundleDisplayName": "NovelEditor"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
            let updaterRoots = [
                home + "/Library/Caches/io.example.Private.ShipIt/update.old",
                home + "/Library/Caches/io.example.Private/org.sparkle-project.Sparkle/Installation/old",
                home + "/Library/Application Support/Unlisted/UpdatePackages/retained",
                home + "/Library/Containers/io.example.private/Data/Library/Global/UpdatePackages/retained",
                home + "/Library/Application Support/Private/LarkShell/update/retained",
                home + "/Library/Application Support/Private/GoogleUpdater/crx_cache/retained"
            ]
            let protectedFiles = ["Cookies", "nested/Cookies-wal", "account.db", "nested/state.vscdb", "Documents/important.txt", "nested/messages.sqlite"]
            for (path, name) in zip(updaterRoots, protectedFiles) { try file(path + "/" + name); try ageTree(path) }
            let unknownUpdate = home + "/Library/Application Support/Unknown/UpdatePackages/work-notes.txt"
            try file(unknownUpdate)
            let scanner = ScannerEngine(environment: env, activity: inactive)
            let report = await scanner.scan(config: ScannerConfig(minCacheSizeMB: 1, minimumAgeDays: 14)) { _ in }
            func found(_ path: String) -> ScanItem? { report.items.first { $0.path == path } }
            check(report.warnings.contains { $0.contains("Locked") }, "Permission-denied directory reported instead of claiming complete scan")
            check(found(shipit)?.isSelected == true, "Unlisted Electron app: old ShipIt archive discovered and selected")
            check(found(recentShipit) == nil, "Recently written updater is preserved")
            check(found(sparkle)?.category == .updaterLeftovers, "Unlisted Sparkle app discovered structurally")
            check(found(meeting)?.category == .updaterLeftovers, "Generic sandbox UpdatePackages discovered")
            check(found(containerSparkle)?.category == .updaterLeftovers, "Sparkle updater discovered inside generic sandbox cache")
            check(found(lark) != nil && found(google) != nil, "Lark and Google updater archives discovered")
            check(found(cache)?.tier == .review && found(cache)?.isSelected == false, "Unknown application cache requires review")
            check(found(appCache)?.tier == .review, "Unlisted Application Support cache discovered")
            check(found(log)?.isSelected == true && found(recentLog) == nil, "Old Chinese/space-path logs selected; recent log preserved")
            check(found(swCache)?.tier == .review, "Generic Chromium profile CacheStorage discovered without browser-name whitelist")
            check(!report.items.contains { $0.path == cookies || FileSafety.isBelow(cookies, $0.path) }, "Cookie-containing cache subtree is protected")
            check(found(cookieWAL) == nil, "Cookie WAL sidecar is protected even without the primary database")
            check(found(privateDB) == nil && found(privateChat) == nil, "Databases and chats are never candidates")
            check(!report.items.contains { $0.path.contains("ms-playwright-go") }, "Playwright-Go runtime protected")
            check(found(pwRoot + "/chromium-1199") != nil, "Unreferenced old Playwright version identified")
            check(found(pwRoot + "/chromium-1200") == nil && found(pwRoot + "/chromium-1201") == nil, "Referenced and platform override Playwright versions protected")
            check(found(versions + "/1.0")?.inspectionOnly == true && found(versions + "/2.0") == nil, "Old framework is inspection-only; Current is preserved")

            let recovery = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
            let cleaner = CleanerEngine(environment: env, recovery: recovery, activity: inactive, testTrashDirectory: trash)
            for (path, name) in zip(updaterRoots, protectedFiles) {
                check(!report.items.contains { $0.path == path || FileSafety.isBelow(path, $0.path) }, "Updater personal data excluded from scan: " + name)
                let forged = try item(path, category: .updaterLeftovers)
                for mode in CleanExecutionMode.allCases {
                    let result = await cleaner.cleanItem(forged, mode: mode)
                    check(!result.success && fm.fileExists(atPath: path + "/" + name), "Execution protects stale/manual updater candidate: " + name + " " + mode.rawValue)
                }
            }
            check(found(unknownUpdate)?.isSelected == false && found(meeting)?.isSelected == false && found(lark)?.isSelected == false && found(google)?.isSelected == false, "Generic updater markers require explicit review")
            let sameMetadata = home + "/Library/Caches/Fixture/same-metadata.bin"
            try file(sameMetadata)
            let fixedDate = Date(timeIntervalSince1970: 1700000000)
            try fm.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sameMetadata)
            let originalCandidate = try item(sameMetadata)
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: sameMetadata))
            try writer.write(contentsOf: Data([66])); try writer.close()
            try fm.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sameMetadata)
            let altered = try FileSafety.tree(sameMetadata)
            check(altered.fingerprint == originalCandidate.stamp.fingerprint && altered.contentFingerprint != originalCandidate.stamp.contentFingerprint, "Byte fingerprint detects same-size same-inode restored-mtime edit")
            check(!(await cleaner.cleanItem(originalCandidate, mode: .permanentDelete)).success && fm.fileExists(atPath: sameMetadata), "Same-metadata modified file survives cleanup")
            if let framework = found(versions + "/1.0") {
                try fm.removeItem(atPath: versions + "/Current")
                try fm.createSymbolicLink(atPath: versions + "/Current", withDestinationPath: "1.0")
                let r = await cleaner.cleanItem(framework, mode: .permanentDelete)
                check(!r.success && fm.fileExists(atPath: versions + "/Current/Engine"), "Changed Current cannot trigger framework deletion")
            } else { check(false, "Framework fixture found") }
            if let archive = found(shipit) {
                let r = await cleaner.cleanItem(archive, mode: .moveToTrash)
                let entries = await recovery.all()
                check(r.success && !fm.fileExists(atPath: shipit) && entries.count == 1 && entries[0].state == .trashed, "Trash action records actual destination before reporting success")
                let reopened = try RecoveryStore(directory: root.appendingPathComponent("Recovery"))
                check(await reopened.all().count == 1, "Recovery journal survives restart")
                try await cleaner.restore(entries[0])
                check(fm.fileExists(atPath: shipit + "/NovelEditor.app/Contents/MacOS/NovelEditor"), "Trash restore returns full archive and nested symlink to original path")
            }
            let legacyPath = home + "/Library/Caches/Fixture/legacy.bin"
            try file(legacyPath)
            _ = await cleaner.cleanItem(try item(legacyPath), mode: .moveToTrash)
            if let entry = await recovery.all().first(where: { $0.originalPath == legacyPath }) {
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
                var treeJSON = json["tree"] as! [String: Any]
                treeJSON.removeValue(forKey: "contentFingerprint"); json["tree"] = treeJSON
                let legacy = try JSONDecoder().decode(RecoveryEntry.self, from: JSONSerialization.data(withJSONObject: json))
                try await cleaner.restore(legacy)
                check(fm.fileExists(atPath: legacyPath), "Pre-upgrade recovery record without content hash remains restorable")
            } else { check(false, "Legacy recovery fixture created") }
            let conflict = home + "/Library/Caches/Fixture/conflict.bin"
            try file(conflict)
            let conflictResult = await cleaner.cleanItem(try item(conflict), mode: .moveToTrash)
            guard let conflictEntry = await recovery.all().first(where: { $0.originalPath == conflict }) else { throw SafetyError.refused("Trash fixture failed: " + conflictResult.message) }
            try Data("new user content".utf8).write(to: URL(fileURLWithPath: conflict))
            do { try await cleaner.restore(conflictEntry); check(false, "Restore must reject destination conflict") }
            catch { check(try String(contentsOfFile: conflict, encoding: .utf8) == "new user content", "Restore never overwrites new destination content") }
            let modifiedTrash = home + "/Library/Caches/Fixture/modified-trash.bin"
            try file(modifiedTrash)
            _ = await cleaner.cleanItem(try item(modifiedTrash), mode: .moveToTrash)
            if let entry = await recovery.all().first(where: { $0.originalPath == modifiedTrash }), let path = entry.trashPath {
                try Data("external change".utf8).write(to: URL(fileURLWithPath: path))
                do { try await cleaner.restore(entry); check(false, "Modified trash must be rejected") }
                catch { check(!fm.fileExists(atPath: modifiedTrash), "Externally modified trash is not silently restored") }
            } else { check(false, "Modified trash fixture created") }
            let changed = home + "/Library/Caches/Fixture/changed.bin"
            try file(changed)
            let before = try item(changed)
            try Data("new content".utf8).write(to: URL(fileURLWithPath: changed))
            let changedResult = await cleaner.cleanItem(before, mode: .permanentDelete)
            check(!changedResult.success && fm.fileExists(atPath: changed), "Changed candidate rejected at execution")
            let vanished = home + "/Library/Caches/Fixture/vanished.bin"
            try file(vanished); let vanishedItem = try item(vanished); try fm.removeItem(atPath: vanished)
            let vanishedResult = await cleaner.cleanItem(vanishedItem, mode: .permanentDelete)
            check(!vanishedResult.success && vanishedResult.processedBytes == 0, "Missing candidate never reports freed bytes")
            let redirected = home + "/Library/Caches/redirect"
            let documents = home + "/Documents"
            try file(documents + "/keep.txt")
            try fm.createSymbolicLink(atPath: redirected, withDestinationPath: documents)
            let redirectedItem = ScanItem(title: "redirect", appName: "Fixture", category: .browserAndAppCache, tier: .review,
                path: redirected + "/keep.txt", reason: "", impactNote: "", stamp: try FileSafety.tree(documents + "/keep.txt"))
            let redirectedResult = await cleaner.cleanItem(redirectedItem, mode: .permanentDelete)
            check(!redirectedResult.success && fm.fileExists(atPath: documents + "/keep.txt"), "Symlink redirection to documents rejected")
            let busyPath = home + "/Library/Caches/NovelEditor/busy.bin"
            try file(busyPath)
            let busy = ScanItem(title: "busy", appName: "NovelEditor", category: .browserAndAppCache, tier: .review,
                path: busyPath, reason: "", impactNote: "", stamp: try FileSafety.tree(busyPath), ownerBundleIDs: ["io.example.NovelEditor"])
            let busyCleaner = CleanerEngine(environment: env, recovery: recovery, activity: { ActivitySnapshot(apps: [RunningApplication(bundleID: "io.example.NovelEditor", path: app)]) }, testTrashDirectory: trash)
            let busyResult = await busyCleaner.cleanItem(busy, mode: .permanentDelete)
            check(!busyResult.success && fm.fileExists(atPath: busyPath), "Running owner app blocks cleanup")
            let uncertainCleaner = CleanerEngine(environment: env, recovery: recovery, activity: { ActivitySnapshot(reliable: false) }, testTrashDirectory: trash)
            check(!(await uncertainCleaner.cleanItem(busy, mode: .permanentDelete)).success, "Unknown process state fails closed")

            let cancelA = home + "/Library/Caches/Fixture/cancelA.bin"
            let cancelB = home + "/Library/Caches/Fixture/cancelB.bin"
            try file(cancelA); try file(cancelB)
            let cancelTargets = try [item(cancelA), item(cancelB)]
            let worker = Task.detached {
                await cleaner.clean(items: cancelTargets, mode: .permanentDelete) { completed, _, _ in
                    if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            let canceled = await worker.value
            check(canceled.canceled && canceled.results.count == 1 && fm.fileExists(atPath: cancelB), "Cancellation stops before the next real file operation")
            let preCanceled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return await cleaner.clean(items: [cancelTargets[1]], mode: .permanentDelete) { _, _, _ in }
            }
            check(await preCanceled.value.results.isEmpty, "Pre-canceled worker performs no cleanup")

            // A new package reference protects an old browser even after the scan.
            guard let pwItem = found(pwRoot + "/chromium-1199") else { throw SafetyError.refused("Missing Playwright fixture") }
            try Data("{\"browsers\":[{\"name\":\"chromium\",\"revision\":\"1199\"}]}".utf8).write(to: URL(fileURLWithPath: package + "/browsers.json"))
            let pwResult = await cleaner.cleanItem(pwItem, mode: .permanentDelete)
            check(!pwResult.success && fm.fileExists(atPath: pwRoot + "/chromium-1199/chrome"), "Playwright references rechecked immediately before deletion")
            try Data("/missing/package".utf8).write(to: URL(fileURLWithPath: pwRoot + "/.links/broken"))
            do { _ = try ScannerEngine.unreferencedPlaywrightDirectories(at: pwRoot); check(false, "Broken reference must retain all browsers") }
            catch { check(true, "Incomplete Playwright references retain all browser versions") }

            let blockedJournalURL = root.appendingPathComponent("blocked-journal")
            let blockedJournal = try RecoveryStore(directory: blockedJournalURL)
            try fm.removeItem(at: blockedJournalURL)
            try Data("not a directory".utf8).write(to: blockedJournalURL)
            let guardedCleaner = CleanerEngine(environment: env, recovery: blockedJournal, activity: inactive, testTrashDirectory: trash)
            let guardedResult = await guardedCleaner.cleanItem(try item(cancelB), mode: .moveToTrash)
            check(!guardedResult.success && fm.fileExists(atPath: cancelB), "Journal write failure leaves original untouched")

            let state = root.appendingPathComponent("State")
            try dir(state.path)
            try Data("{\"minCacheSizeMB\":17,\"dormantAppDaysThreshold\":180,\"updateManifestURL\":\"https://unused.example\"}".utf8).write(to: state.appendingPathComponent("config.json"))
            let store = AppStore(environment: env, storageDirectoryURL: state, activity: inactive, testTrashDirectory: trash)
            check(store.config.minCacheSizeMB == 17 && store.config.minimumAgeDays == 14 && store.config.language == .en, "Old configuration migrates without enabling removed features and defaults to English")
            check(AppLanguage.allCases.map(\.displayName) == ["English", "日本語", "中文"], "Three interface languages (English, 日本語, 中文) are available")
            check(L10n.tr(en: "Fallback text", ja: "", zh: nil, language: .ja) == "Fallback text" && L10n.tr(en: "Fallback text", ja: nil, zh: "", language: .zhHans) == "Fallback text", "Missing translations fall back to English")
            let allRules: [ScanRuleKey] = [.shipIt, .sparkle, .genericUpdater, .appSupportCache, .logFile, .sandboxUpdater, .sandboxCache, .userCache, .devToolCache, .playwrightUnreferenced, .legacyFramework(current: "2.0", version: "1.0")]
            check(allRules.allSatisfy { rule in
                let reasons = Set(AppLanguage.allCases.map { rule.reason(in: $0) })
                let impacts = Set(AppLanguage.allCases.map { rule.impact(in: $0) })
                return reasons.count == 3 && impacts.count == 3 && !reasons.contains("") && !impacts.contains("")
            }, "All scan rules provide distinct non-empty English, Japanese, and Chinese descriptions")
            if let sampleShipIt = found(shipit) ?? report.items.first {
                store.items = [sampleShipIt]
                store.language = .ja
                check(store.items.count == 1 && store.phase.contains("スキャン") && CleanupCategory.updaterLeftovers.title == "更新の残骸" && store.items[0].reason.contains("ShipIt"), "Switching to Japanese updates UI and item text without clearing scan results")
                store.language = .zhHans
                check(store.items.count == 1 && store.phase.contains("扫描") && CleanupCategory.updaterLeftovers.title == "更新残留" && store.items[0].reason.contains("更新"), "Switching to Chinese updates UI and item text without clearing scan results")
                store.language = .en
                check(store.items.count == 1 && store.phase.contains("Scan") && CleanupCategory.updaterLeftovers.title == "Update Leftovers", "Switching back to English updates UI and item text without clearing scan results")
                store.language = .zhHans
            } else { check(false, "Sample scan item available for language switch test") }
            store.items = [try item(cancelB)]
            store.config.minimumAgeDays = 21
            check(store.items.isEmpty, "Changing scan settings invalidates stale cleanup candidates")
            let reloaded = AppStore(environment: env, storageDirectoryURL: state, activity: inactive, testTrashDirectory: trash)
            check(reloaded.config.minimumAgeDays == 21 && reloaded.config.language == .zhHans, "Settings and chosen language persist across app sessions")
            reloaded.resetScanDefaults()
            check(reloaded.config.minCacheSizeMB == 5 && reloaded.config.minimumAgeDays == 14 && reloaded.config.language == .zhHans, "Restoring scan defaults preserves user-selected language")
            store.language = .en
            store.startScan(); store.stop()
            check(store.isScanning && store.isStopping, "Stop keeps UI busy until actual worker exits")
            let deadline = Date().addingTimeInterval(10)
            while store.isBusy && Date() < deadline { await Task.yield() }
            check(!store.isBusy && !store.isStopping && (store.phase.localizedCaseInsensitiveContains("stopped") || store.phase.contains("停止")), "Worker acknowledgement finalizes canceled scan")
            check(ScannerConfig(minCacheSizeMB: -1, minimumAgeDays: Int.max).minCacheSizeMB == 1 && ScannerConfig(minimumAgeDays: Int.max).minimumAgeDays == 3650 && ScannerConfig.default.language == .en, "Configuration clamps invalid thresholds and defaults to English")

            // Regression: realistic OS username + background system daemons + empty bundleID processes
            let realisticHome = root.appendingPathComponent("Users/apple").path
            let realisticApps = root.appendingPathComponent("RealisticApps").path
            let realisticEnv = ScanEnvironment(homeDirectory: realisticHome, applicationDirectories: [realisticApps])
            for path in realisticEnv.writableRoots { try dir(path) }
            try dir(realisticApps)
            let chromeApp = realisticApps + "/Google Chrome.app"
            try dir(chromeApp + "/Contents")
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.google.Chrome", "CFBundleDisplayName": "Google Chrome"],
                format: .xml, options: 0
            ).write(to: URL(fileURLWithPath: chromeApp + "/Contents/Info.plist"))
            let unbundledApp = realisticApps + "/NoBundleIDTool.app"
            try dir(unbundledApp + "/Contents")
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleDisplayName": "NoBundleIDTool"],
                format: .xml, options: 0
            ).write(to: URL(fileURLWithPath: unbundledApp + "/Contents/Info.plist"))

            let idleShipIt = realisticHome + "/Library/Caches/com.vendor.CodeEditor.ShipIt/update.100"
            try file(idleShipIt + "/payload.bin"); try ageTree(idleShipIt)
            let idleSparkle = realisticHome + "/Library/Caches/com.vendor.Writer/org.sparkle-project.sparkle/Installation/pkg1"
            try file(idleSparkle + "/archive.bin"); try ageTree(idleSparkle)
            let siblingVendorLog = realisticHome + "/Library/Caches/com.google.OtherDesktopTool/Logs/tool.log"
            try file(siblingVendorLog)
            let idleDevCache = realisticHome + "/Library/Caches/pip/wheels-cache"
            try file(idleDevCache + "/pkg.whl"); try ageTree(idleDevCache)
            let activeChromeCache = realisticHome + "/Library/Application Support/Google/Chrome/Default/Cache/Cache_Data"
            try file(activeChromeCache + "/entry.bin"); try ageTree(activeChromeCache)
            let activeHelperLog = realisticHome + "/Library/Caches/com.google.Chrome.helper/Logs/helper.log"
            try file(activeHelperLog)

            let realisticActivity: @Sendable () -> ActivitySnapshot = {
                ActivitySnapshot(
                    apps: [
                        RunningApplication(bundleID: "", path: ""),
                        RunningApplication(bundleID: "", path: "/usr/libexec/background_helper"),
                        RunningApplication(bundleID: "com.apple.AppleSpell", path: "/System/Library/Services/AppleSpell.service"),
                        RunningApplication(bundleID: "com.apple.CacheDelete", path: "/System/Library/PrivateFrameworks/CacheDelete.framework"),
                        RunningApplication(bundleID: "com.google.Chrome", path: chromeApp)
                    ],
                    executables: ["/sbin/launchd", chromeApp + "/Contents/MacOS/Google Chrome"],
                    reliable: true
                )
            }
            let realisticScanner = ScannerEngine(environment: realisticEnv, activity: realisticActivity)
            let realisticReport = await realisticScanner.scan(config: ScannerConfig(minCacheSizeMB: 1, minimumAgeDays: 14)) { _ in }
            func realisticFound(_ path: String) -> ScanItem? { realisticReport.items.first { $0.path == path } }
            check(realisticFound(idleShipIt)?.isSelected == true, "OS username 'apple' and empty-bundleID daemons do not falsely block idle ShipIt leftovers")
            check(realisticFound(idleSparkle)?.isSelected == true, "Lowercase Sparkle installation path discovered under realistic activity")
            check(realisticFound(siblingVendorLog)?.isSelected == true, "Running com.google.Chrome does not falsely block sibling com.google.* tool logs")
            check(realisticFound(idleDevCache)?.tier == .review, "Developer tool cache discovered without false-positive busy match on Caches/apple")
            check(realisticFound(activeChromeCache) == nil && realisticFound(activeHelperLog) == nil, "Actively running app cache and sub-bundle helper logs remain protected")

            let realisticRecovery = try RecoveryStore(directory: root.appendingPathComponent("RealisticRecovery"))
            let realisticCleaner = CleanerEngine(environment: realisticEnv, recovery: realisticRecovery, activity: realisticActivity, testTrashDirectory: trash)
            if let sparkleCandidate = realisticFound(idleSparkle), let devCandidate = realisticFound(idleDevCache) {
                let cleanSparkle = await realisticCleaner.cleanItem(sparkleCandidate, mode: .moveToTrash)
                let cleanDev = await realisticCleaner.cleanItem(devCandidate, mode: .permanentDelete)
                check(cleanSparkle.success && cleanDev.success && !fm.fileExists(atPath: idleSparkle) && !fm.fileExists(atPath: idleDevCache), "Scanned candidates can be selected and deleted under realistic background process state")
            } else {
                check(false, "Expected cleanable realistic candidates to exist")
            }

            // Selection state & inspectionOnly UI logic regressions
            let selectionStore = AppStore(environment: realisticEnv, storageDirectoryURL: root.appendingPathComponent("SelectionState"), activity: realisticActivity, testTrashDirectory: trash)
            let inspectDummy = ScanItem(
                title: "Google Chrome · 156.0",
                appName: "Google Chrome",
                category: .redundantFrameworks,
                tier: .review,
                path: chromeApp + "/Contents/Frameworks/Chrome.framework/Versions/156.0",
                reason: "r",
                impactNote: "i",
                stamp: realisticReport.items[0].stamp,
                inspectionOnly: true,
                ruleKey: .legacyFramework(current: "157.0", version: "156.0")
            )
            if let safeSample = realisticFound(idleShipIt), let reviewSample = realisticFound(siblingVendorLog).map({
                ScanItem(title: $0.title, appName: $0.appName, category: .browserAndAppCache, tier: .review, path: $0.path, reason: $0.reason, impactNote: $0.impactNote, stamp: $0.stamp, ruleKey: .userCache)
            }) {
                selectionStore.items = [safeSample, reviewSample, inspectDummy]
                check(selectionStore.hasCleanableFilteredItems, "Mixed list reports cleanable items available")
                selectionStore.setSelected(reviewSample.id, true)
                selectionStore.setSelected(reviewSample.id, true)
                selectionStore.setSelected(inspectDummy.id, true)
                check(selectionStore.items[1].isSelected && !selectionStore.items[2].isSelected, "setSelected is idempotent and never selects inspectionOnly items")
                selectionStore.clearSelection()
                selectionStore.selectedCategory = .browserAndAppCache
                selectionStore.selectAllCleanable()
                check(!selectionStore.items[0].isSelected && selectionStore.items[1].isSelected && !selectionStore.items[2].isSelected, "selectAllCleanable selects review items in current filter without selecting hidden or inspectionOnly items")
                selectionStore.selectedCategory = .redundantFrameworks
                check(!selectionStore.hasCleanableFilteredItems, "Inspection-only category reports zero cleanable filtered items")
            } else {
                check(false, "Selection regression fixtures available")
            }

            check(SemVer(string: "1.10.0")! > SemVer(string: "1.9.0")!, "Numeric release ordering")
            check(SemVer(string: "1.0.0")! > SemVer(string: "1.0.0-beta.1")!, "Stable release outranks prerelease")
            check(SemVer(string: "1.0.0+a") == SemVer(string: "1.0.0+b"), "Build metadata does not change precedence")
            check(["1.0", "01.0.0", "1.0.0-01", "1.0.0+", "1.0.0-a_1"].allSatisfy { SemVer(string: $0) == nil }, "Malformed release identifiers rejected")
            check(SemVer(string: "1.0.0-99999999999999999999999999999")! > SemVer(string: "1.0.0-9")!, "Long numeric prerelease identifiers compare numerically")
            let payload = root.appendingPathComponent("mock.dmg")
            let data = Data("mock install package".utf8); try data.write(to: payload)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            func manifest(hash: String = digest, size: Int64 = Int64(data.count), minOS: String = "13.0", arch: [String] = ["arm64", "x86_64"], channel: String = "stable", version: String = "1.2.0") -> ReleaseManifest {
                ReleaseManifest(version: version, buildNumber: 120, channel: channel, publishedAt: "2026-11-03", minSystemVersion: minOS,
                                supportedArchitectures: arch, dmgUrl: payload.absoluteString, sha256: hash, sizeBytes: size, releaseNotes: "fixture")
            }
            let service = UpdateService(allowLocalFiles: true)
            let valid = await service.downloadAndVerifyDMG(manifest: manifest(), destinationDirectory: root) { _ in }
            if case .readyToInstall(let path, _) = valid { check(fm.fileExists(atPath: path), "Verified update enabled in private attempt directory") }
            else { check(false, "Valid update accepted") }
            let corrupted = await service.downloadAndVerifyDMG(manifest: manifest(hash: String(repeating: "0", count: 64)), destinationDirectory: root) { _ in }
            if case .failed = corrupted { check(true, "Corrupted update rejected") } else { check(false, "Corrupted update rejected") }
            let wrongSize = await service.downloadAndVerifyDMG(manifest: manifest(size: 999), destinationDirectory: root) { _ in }
            if case .failed = wrongSize { check(true, "Wrong-size update rejected") } else { check(false, "Wrong-size update rejected") }
            let productionService = UpdateService()
            if case .failed = await productionService.downloadAndVerifyDMG(manifest: manifest(), destinationDirectory: root, onPhase: { _ in }) {
                check(true, "Production updater refuses local-file source")
            } else { check(false, "Production updater refuses local-file source") }
            for m in [manifest(minOS: "invalid"), manifest(minOS: "99.0"), manifest(arch: [])] {
                if case .incompatibleSystem = UpdateEvaluator.evaluate(manifest: m, currentOSVersion: "15.0.0", currentArch: "arm64") { check(true, "Incompatible or malformed platform rejected") }
                else { check(false, "Incompatible or malformed platform rejected") }
            }
            if case .channelFilteredOut = UpdateEvaluator.evaluate(manifest: manifest(channel: "beta", version: "1.2.0-beta.1")) { check(true, "Stable channel excludes beta") }
            else { check(false, "Stable channel excludes beta") }
            let process = ProcessRunner.run("/usr/bin/seq", ["1", "30000"])
            check(process.status == 0 && process.output.contains("30000"), "Large subprocess output drains without pipe deadlock")
            check(fm.fileExists(atPath: privateDB) && fm.fileExists(atPath: privateChat) && fm.fileExists(atPath: pwGo), "All protected data remains after integration tests")
        } catch { failed += 1; print("[FAIL] Unexpected error: \(error)") }
        print("Summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
