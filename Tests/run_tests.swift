import Foundation
import CryptoKit

@main
struct MacSlimTestRunner {
    static func main() async {
        print("=== MacSlim Automated Verification Suite ===")
        var passed = 0
        var failed = 0

        func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                passed += 1
                print("  [PASS] \(message)")
            } else {
                failed += 1
                print("  [FAIL] \(message)")
            }
        }

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: "/tmp/macslim_test_\(UUID().uuidString)", isDirectory: true)
        let fakeHome = tempRoot.appendingPathComponent("Home", isDirectory: true)
        let fakeApps = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let fakeStorage = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)

        defer {
            try? fm.removeItem(at: tempRoot)
        }

        do {
            try fm.createDirectory(at: fakeHome, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeApps, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeStorage, withIntermediateDirectories: true)

            // Helper to write a file of a specific size
            func writeDummyFile(at url: URL, sizeMB: Int) throws {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(repeating: 0x41, count: sizeMB * 1024 * 1024)
                try data.write(to: url)
            }

            // 1. Setup Rule 1: ShipIt updater leftover (6 MB)
            let shipItFile = fakeHome.appendingPathComponent("Library/Caches/com.anthropic.claudefordesktop.ShipIt/update.a1b2c3d/Claude.app/UpdateBundle.zip")
            try writeDummyFile(at: shipItFile, sizeMB: 6)

            // 2. Setup Rule 2: Redundant Framework Versions inside MockBrowser.app
            let versionsDir = fakeApps.appendingPathComponent("MockBrowser.app/Contents/Frameworks/MockEngine.framework/Versions", isDirectory: true)
            let oldVerFile = versionsDir.appendingPathComponent("130.0.1/MockEngineBinary")
            let currentVerFile = versionsDir.appendingPathComponent("131.0.2/MockEngineBinary")
            try writeDummyFile(at: oldVerFile, sizeMB: 5)
            try writeDummyFile(at: currentVerFile, sizeMB: 5)
            let currentSymlink = versionsDir.appendingPathComponent("Current")
            try fm.createSymbolicLink(atPath: currentSymlink.path, withDestinationPath: "131.0.2")

            // 3. Setup Rule 3: Chrome Service Worker CacheStorage (7 MB)
            let swCacheFile = fakeHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/blob_01.dat")
            try writeDummyFile(at: swCacheFile, sizeMB: 7)

            // 4. Setup Rule 4: Logs directory with Chinese & spaces in path (6 MB)
            let logFile = fakeHome.appendingPathComponent("Library/Logs/中文 空格测试应用/debug.log")
            try writeDummyFile(at: logFile, sizeMB: 6)

            // 5. Setup Rule 5: Cursor state.vscdb with ItemTable + bloated cursorDiskKV (3 MB)
            let cursorDBDir = fakeHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
            try fm.createDirectory(at: cursorDBDir, withIntermediateDirectories: true)
            let cursorDBPath = cursorDBDir.appendingPathComponent("state.vscdb").path
            let initSQL = """
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'secret_jwt_token_123');
            INSERT INTO ItemTable VALUES ('workbench.panel.state', '{"visible":true}');
            INSERT INTO ItemTable VALUES ('user.preferences.theme', 'Default Dark+');
            INSERT INTO cursorDiskKV VALUES ('bubble_1', zeroblob(1500000));
            INSERT INTO cursorDiskKV VALUES ('bubble_2', zeroblob(1500000));
            """
            _ = runSQLite(dbPath: cursorDBPath, sql: initSQL)

            // 6. Setup Rule 6: Dormant App (> 180 days old) + Container with protected metadata plist
            let dormantAppDir = fakeApps.appendingPathComponent("DormantSuite.app", isDirectory: true)
            let dormantBinary = dormantAppDir.appendingPathComponent("Contents/MacOS/DormantSuite")
            try writeDummyFile(at: dormantBinary, sizeMB: 6)
            let infoPlistURL = dormantAppDir.appendingPathComponent("Contents/Info.plist")
            let plistDict: [String: Any] = [
                "CFBundleIdentifier": "com.example.dormantsuite",
                "CFBundleDisplayName": "DormantSuite"
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try plistData.write(to: infoPlistURL)

            // Backdate DormantSuite.app modification/access time to 240 days ago
            let oldDate = Date().addingTimeInterval(-240 * 86400)
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: dormantAppDir.path)
            var tv = [
                timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0),
                timeval(tv_sec: Int(oldDate.timeIntervalSince1970), tv_usec: 0)
            ]
            _ = dormantAppDir.path.withCString { cPath in
                utimes(cPath, &tv)
            }

            let containerDir = fakeHome.appendingPathComponent("Library/Containers/com.example.dormantsuite", isDirectory: true)
            let protectedPlist = containerDir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            let containerCache = containerDir.appendingPathComponent("Data/Library/Caches/payload.bin")
            try writeDummyFile(at: protectedPlist, sizeMB: 1)
            try writeDummyFile(at: containerCache, sizeMB: 4)

            // --- Run ScannerEngine ---
            let env = ScanEnvironment(homeDirectory: fakeHome.path, applicationsDirectory: fakeApps.path)
            let scanner = ScannerEngine(environment: env)
            let testConfig = ScannerConfig(
                minCacheSizeMB: 2,
                dormantAppDaysThreshold: 180,
                dormantAppMinSizeMB: 5,
                cursorDBCompactThresholdMB: 2
            )

            let scannedItems = await scanner.scan(config: testConfig) { _ in }
            print("Scanned items count: \(scannedItems.count)")

            assertCondition(scannedItems.contains { $0.category == .updaterLeftovers && $0.tier == .safe && $0.isSelected }, "Rule 1: Detects ShipIt updater leftover as safe & selected by default")
            assertCondition(scannedItems.contains { $0.category == .redundantFrameworks && $0.path.hasSuffix("130.0.1") && $0.tier == .safe }, "Rule 2: Detects unreferenced old framework version 130.0.1")
            assertCondition(!scannedItems.contains { $0.path.hasSuffix("131.0.2") }, "Rule 2: Never flags active Current framework version 131.0.2")
            assertCondition(scannedItems.contains { $0.category == .browserAndAppCache && $0.tier == .safe }, "Rule 3: Detects Chrome Service Worker CacheStorage")
            assertCondition(scannedItems.contains { $0.category == .logsAndDevCache && $0.tier == .safe }, "Rule 4: Detects ~/Library/Logs bloat")
            assertCondition(scannedItems.contains { $0.category == .databaseCompact && $0.tier == .deep && !$0.isSelected }, "Rule 5: Detects bloated Cursor state.vscdb as deep tier (unchecked by default)")
            assertCondition(scannedItems.contains { $0.category == .dormantApps && $0.tier == .deep && !$0.isSelected }, "Rule 6: Detects DormantSuite.app (>180 days) as deep tier (unchecked by default)")

            // --- Run CleanerEngine on All Scanned Items (Permanent Delete Mode for deterministic verification) ---
            let cleaner = CleanerEngine()
            let results = await cleaner.clean(items: scannedItems, mode: .permanentDelete) { _, _, _, _ in }
            assertCondition(results.allSatisfy(\.success), "CleanerEngine succeeds on all 6 rule items")

            // Verify Rule 2 preservation of Current framework version
            assertCondition(!fm.fileExists(atPath: versionsDir.appendingPathComponent("130.0.1").path), "Rule 2 Cleanup: Old framework version 130.0.1 removed")
            assertCondition(fm.fileExists(atPath: currentVerFile.path), "Rule 2 Cleanup: Active framework version 131.0.2 preserved intact")

            // Verify Rule 5 lossless SQLite rebuild of Cursor state.vscdb
            let itemRowsAfter = runSQLite(dbPath: cursorDBPath, sql: "SELECT COUNT(*) FROM ItemTable;").trimmingCharacters(in: .whitespacesAndNewlines)
            let kvRowsAfter = runSQLite(dbPath: cursorDBPath, sql: "SELECT COUNT(*) FROM cursorDiskKV;").trimmingCharacters(in: .whitespacesAndNewlines)
            let tokenAfter = runSQLite(dbPath: cursorDBPath, sql: "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';").trimmingCharacters(in: .whitespacesAndNewlines)
            assertCondition(itemRowsAfter == "3", "Rule 5 Cleanup: Preserves all 3 rows in ItemTable (actual: \(itemRowsAfter))")
            assertCondition(kvRowsAfter == "0", "Rule 5 Cleanup: Clears bloated cursorDiskKV rows (actual: \(kvRowsAfter))")
            assertCondition(tokenAfter == "secret_jwt_token_123", "Rule 5 Cleanup: Preserves exact auth token value in ItemTable")

            // Verify Rule 6 container metadata preservation
            assertCondition(!fm.fileExists(atPath: dormantAppDir.path), "Rule 6 Cleanup: Removes dormant app bundle")
            assertCondition(!fm.fileExists(atPath: containerCache.path), "Rule 6 Cleanup: Removes container Data payload")
            assertCondition(fm.fileExists(atPath: protectedPlist.path), "Rule 6 Cleanup: Preserves protected .com.apple.containermanagerd.metadata.plist")

            // --- Verify AppStore Mode Switching, Config Persistence & Cache ---
            await MainActor.run {
                let store = AppStore(environment: env, storageDirectoryURL: fakeStorage)
                assertCondition(store.updateState == .idle, "AppStore: Initial updateState is .idle (never claims 'upToDate' before checking)")
                store.setDemoMode(true)
                assertCondition(store.isDemoMode && store.items.count == 13, "AppStore: Demo mode loads 13 realistic case items totaling ~79.3 GB")
                store.setDemoMode(false)
                assertCondition(!store.isDemoMode && store.items.isEmpty, "AppStore: Switching back to real mode isolates demo dataset from real state")

                store.config.minCacheSizeMB = 25
                let reloadedStore = AppStore(environment: env, storageDirectoryURL: fakeStorage)
                assertCondition(reloadedStore.config.minCacheSizeMB == 25, "AppStore: Persists and reloads user ScannerConfig across restarts")
            }

            // --- Verify SemVer 2.0.0 Rules ---
            if let v1_9 = SemVer(string: "1.9.0"),
               let v1_10 = SemVer(string: "1.10.0"),
               let v1_0 = SemVer(string: "1.0.0"),
               let v1_0_beta = SemVer(string: "1.0.0-beta.1"),
               let v1_0_buildA = SemVer(string: "1.0.0+20261101"),
               let v1_0_buildB = SemVer(string: "1.0.0+20261103") {
                assertCondition(v1_10 > v1_9, "SemVer: 1.10.0 > 1.9.0 (numerical comparison)")
                assertCondition(v1_0 > v1_0_beta, "SemVer: 1.0.0 > 1.0.0-beta.1 (stable > prerelease)")
                assertCondition(v1_0_buildA == v1_0_buildB && !(v1_0_buildA < v1_0_buildB), "SemVer: +build metadata does not alter version precedence")
            } else {
                failed += 1
                print("  [FAIL] SemVer parsing failed")
            }

            // --- Verify Update Compatibility & Channel Filtering ---
            let betaManifest = ReleaseManifest(
                version: "1.2.0-beta.1",
                buildNumber: 120,
                channel: "beta",
                publishedAt: "2026-11-03T00:00:00Z",
                dmgUrl: "https://example.com/MacSlim.dmg",
                sha256: "abc",
                sizeBytes: 1024,
                releaseNotes: "Beta test"
            )
            let betaEval = UpdateEvaluator.evaluate(manifest: betaManifest, currentVersion: "1.0.0", preferredChannel: "stable")
            assertCondition(betaEval == .channelFilteredOut(manifestChannel: "beta"), "OTA Evaluator: Stable channel user ignores beta updates")

            let badArchManifest = ReleaseManifest(
                version: "1.2.0",
                buildNumber: 120,
                channel: "stable",
                publishedAt: "2026-11-03T00:00:00Z",
                supportedArchitectures: ["ppc64"],
                dmgUrl: "https://example.com/MacSlim.dmg",
                sha256: "abc",
                sizeBytes: 1024,
                releaseNotes: "Arch mismatch test"
            )
            if case .incompatibleSystem = UpdateEvaluator.evaluate(manifest: badArchManifest, currentVersion: "1.0.0", preferredChannel: "stable") {
                passed += 1
                print("  [PASS] OTA Evaluator: Rejects incompatible CPU architecture")
            } else {
                failed += 1
                print("  [FAIL] OTA Evaluator: Failed to reject incompatible architecture")
            }

            // --- Verify UpdateService SHA-256 Verification & Corrupted Package Rejection ---
            let dummyDMGURL = tempRoot.appendingPathComponent("mock_release.dmg")
            let dummyDMGData = Data("MacSlim-Mock-DMG-Binary-Payload".utf8)
            try dummyDMGData.write(to: dummyDMGURL)
            let validSHA256 = SHA256.hash(data: dummyDMGData).map { String(format: "%02x", $0) }.joined()

            let validManifest = ReleaseManifest(
                version: "1.1.0",
                buildNumber: 110,
                channel: "stable",
                publishedAt: "2026-11-03T00:00:00Z",
                dmgUrl: dummyDMGURL.absoluteString,
                sha256: validSHA256,
                sizeBytes: Int64(dummyDMGData.count),
                releaseNotes: "v1.1.0 bugfixes"
            )
            let updateService = UpdateService()
            let validDownloadState = await updateService.downloadAndVerifyDMG(
                manifest: validManifest,
                destinationDirectory: tempRoot
            ) { _ in }
            if case .readyToInstall(let installedPath, _) = validDownloadState {
                assertCondition(fm.fileExists(atPath: installedPath), "OTA Service: Valid SHA-256 package verified and moved to readyToInstall")
            } else {
                failed += 1
                print("  [FAIL] OTA Service: Valid SHA-256 package should succeed")
            }

            let tamperedManifest = ReleaseManifest(
                version: "1.1.1",
                buildNumber: 111,
                channel: "stable",
                publishedAt: "2026-11-03T00:00:00Z",
                dmgUrl: dummyDMGURL.absoluteString,
                sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                sizeBytes: Int64(dummyDMGData.count),
                releaseNotes: "Tampered hash"
            )
            let tamperedState = await updateService.downloadAndVerifyDMG(
                manifest: tamperedManifest,
                destinationDirectory: tempRoot
            ) { _ in }
            let leftoverPart = tempRoot.appendingPathComponent("MacSlim-1.1.1.dmg.part")
            if case .failed = tamperedState {
                assertCondition(!fm.fileExists(atPath: leftoverPart.path), "OTA Service: Rejects mismatched SHA-256 and deletes temporary .part file")
            } else {
                failed += 1
                print("  [FAIL] OTA Service: Mismatched SHA-256 must fail verification")
            }

        } catch {
            failed += 1
            print("  [FAIL] Unexpected test exception: \(error)")
        }

        print("=== Summary: \(passed) Passed, \(failed) Failed ===")
        if failed > 0 {
            exit(1)
        }
    }

    private static func runSQLite(dbPath: String, sql: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath, sql]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
