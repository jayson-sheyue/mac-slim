import Foundation

public struct ScannerEngine: Sendable {
    public let environment: ScanEnvironment
    private let activity: @Sendable () -> ActivitySnapshot
    public init(environment: ScanEnvironment = ScanEnvironment(), activity: @escaping @Sendable () -> ActivitySnapshot = { .current() }) {
        self.environment = environment; self.activity = activity
    }

    private struct AppInfo {
        let name: String
        let bundleName: String
        let bundleID: String
        let path: String
    }

    private static let structuralDirectoryNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "gpupersistentcache",
        "cachestorage", "cacheddata", "cachedextensionvsixs",
        "logs", "log", "diagnosticreports",
        "org.sparkle-project.sparkle", "installation",
        "updatepackages", "update", "crx_cache",
        "data", "library", "global", "user", "users", "default",
        "partitions", "service worker", "profiles", "application support", "containers"
    ]

    public func scan(config: ScannerConfig, onProgress: @Sendable (String) async -> Void) async -> ScanReport {
        let lang = config.language
        L10n.current = lang
        var report = ScanReport()
        let fm = FileManager.default
        let activity = activity()
        guard activity.reliable else {
            report.warnings = [L10n.tr(
                en: "Could not read running process state; scan stopped. Please try again to avoid cleaning data in active use.",
                ja: "プロセスの状態を読み取れなかったため、スキャンを停止しました。使用中のデータを整理しないよう再試行してください。",
                zh: "无法读取进程状态，已停止扫描。请重试，以免清理正在使用的数据。",
                language: lang
            )]
            return report
        }
        let minimumBytes = Int64(min(102400, max(1, config.minCacheSizeMB))) * 1024 * 1024
        let cutoff = Date().addingTimeInterval(-Double(min(3650, max(1, config.minimumAgeDays))) * 86400)
        let library = environment.library
        var apps: [AppInfo] = []
        var seen = Set<String>()
        var omittedWarnings = 0

        func warn(_ message: String) {
            if report.warnings.count < 100 { report.warnings.append(message) } else { omittedWarnings += 1 }
        }
        func entries(_ path: String) -> [String] {
            if Task.isCancelled { return [] }
            do { return try fm.contentsOfDirectory(atPath: path).sorted() }
            catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    warn(L10n.tr(
                        en: "Could not read \(display(path)): \(error.localizedDescription)",
                        ja: "\(display(path)) を読み取れませんでした: \(error.localizedDescription)",
                        zh: "无法读取 \(display(path))：\(error.localizedDescription)",
                        language: lang
                    ))
                }
                return []
            }
        }
        func directory(_ path: String) -> Bool {
            (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeDirectory
        }
        func ownerTokens(_ path: String) -> (bundleIDs: [String], names: Set<String>) {
            let cachesRoot = library + "/Caches"
            let supportRoot = library + "/Application Support"
            let containersRoot = library + "/Containers"
            let logsRoot = library + "/Logs"

            var rawSegments: [String] = []
            if FileSafety.isBelow(path, containersRoot) {
                let parts = String(path.dropFirst(containersRoot.count + 1)).components(separatedBy: "/").filter { !$0.isEmpty }
                if let first = parts.first { rawSegments = [first] }
            } else if FileSafety.isBelow(path, cachesRoot) {
                let parts = String(path.dropFirst(cachesRoot.count + 1)).components(separatedBy: "/").filter { !$0.isEmpty }
                if let first = parts.first {
                    if parts.count >= 3 && !first.contains(".") && !Self.structuralDirectoryNames.contains(parts[1].lowercased()) {
                        rawSegments = [first, parts[1]]
                    } else {
                        rawSegments = [first]
                    }
                }
            } else if FileSafety.isBelow(path, supportRoot) {
                let parts = String(path.dropFirst(supportRoot.count + 1)).components(separatedBy: "/").filter { !$0.isEmpty }
                for seg in parts.dropLast() {
                    let lower = seg.lowercased()
                    if Self.structuralDirectoryNames.contains(lower) || lower.hasPrefix("profile ") { break }
                    rawSegments.append(seg)
                    if rawSegments.count == 2 { break }
                }
            } else if FileSafety.isBelow(path, logsRoot) {
                let parts = String(path.dropFirst(logsRoot.count + 1)).components(separatedBy: "/").filter { !$0.isEmpty }
                if parts.count == 1 {
                    var stem = parts[0]
                    for ext in [".log", ".ips", ".crash"] where stem.lowercased().hasSuffix(ext) {
                        stem = String(stem.dropLast(ext.count))
                        break
                    }
                    rawSegments = [stem]
                } else {
                    for seg in parts.dropLast() {
                        let lower = seg.lowercased()
                        if Self.structuralDirectoryNames.contains(lower) { break }
                        rawSegments.append(seg)
                        if rawSegments.count == 2 { break }
                    }
                }
            }

            let cleaned = rawSegments.map { seg -> String in
                seg.lowercased().hasSuffix(".shipit") ? String(seg.dropLast(7)) : seg
            }.filter { !$0.isEmpty && !Self.structuralDirectoryNames.contains($0.lowercased()) }

            var bundleIDTokens: [String] = []
            var nameTokens: Set<String> = []
            for seg in cleaned {
                if seg.contains(".") {
                    bundleIDTokens.append(seg.lowercased())
                } else {
                    let norm = normalized(seg)
                    if norm.count >= 4 { nameTokens.insert(norm) }
                }
            }
            if cleaned.count >= 2 && !cleaned[0].contains(".") && !cleaned[1].contains(".") {
                let combined = normalized(cleaned[0] + cleaned[1])
                if combined.count >= 4 { nameTokens.insert(combined) }
            }
            return (bundleIDTokens, nameTokens)
        }
        func owners(_ path: String) -> [AppInfo] {
            let tokens = ownerTokens(path)
            guard !tokens.bundleIDs.isEmpty || !tokens.names.isEmpty else { return [] }
            let runningApps = activity.apps.compactMap { running -> AppInfo? in
                guard !running.bundleID.isEmpty || !running.path.isEmpty else { return nil }
                let bundleName = running.path.isEmpty ? "" : URL(fileURLWithPath: running.path).deletingPathExtension().lastPathComponent
                return AppInfo(name: bundleName, bundleName: bundleName, bundleID: running.bundleID, path: running.path)
            }
            return (apps + runningApps).filter { app in
                let idLower = app.bundleID.lowercased()
                let nameKeys = Set([normalized(app.name), normalized(app.bundleName)].filter { $0.count >= 4 })
                let idProductNorm: String? = {
                    guard !idLower.isEmpty, let last = idLower.split(separator: ".").last else { return nil }
                    let n = normalized(String(last))
                    return n.count >= 4 ? n : nil
                }()
                let matchesBundleID = tokens.bundleIDs.contains { token in
                    if !idLower.isEmpty && (idLower == token || token.hasPrefix(idLower + ".") || idLower.hasPrefix(token + ".")) {
                        return true
                    }
                    let dotParts = token.split(separator: ".")
                    if dotParts.count >= 3 {
                        let product = normalized(dotParts.dropFirst(2).joined())
                        if product.count >= 4 && nameKeys.contains(product) { return true }
                    }
                    return false
                }
                let matchesName = tokens.names.contains { token in
                    nameKeys.contains(token) || (idProductNorm == token)
                }
                return matchesBundleID || matchesName
            }
        }
        func add(_ path: String, category: CleanupCategory, tier: CleanupTier, rule: ScanRuleKey,
                 inspectionOnly: Bool = false, title: String? = nil, owner: AppInfo? = nil) {
            guard !Task.isCancelled, !seen.contains(path), !report.items.contains(where: { FileSafety.isBelow(path, $0.path) || FileSafety.isBelow($0.path, path) }) else { return }
            do {
                if !inspectionOnly { try FileSafety.validate(path, roots: environment.writableRoots) }
                let matching = owner.map { [$0] } ?? owners(path)
                let ownerBundleIDs = Array(Set(matching.map(\.bundleID).filter { !$0.isEmpty })).sorted()
                let ownerAppPaths = Array(Set(matching.map(\.path).filter { !$0.isEmpty })).sorted()
                guard inspectionOnly || !activity.isBusy(path: path, bundleIDs: ownerBundleIDs, appPaths: ownerAppPaths) else {
                    warn(L10n.tr(
                        en: "Skipped item currently in use: \(display(path))",
                        ja: "使用中の項目をスキップしました: \(display(path))",
                        zh: "已跳过正在使用的项目：\(display(path))",
                        language: lang
                    ))
                    return
                }
                let stamp = try FileSafety.tree(path, rejectProtectedData: !inspectionOnly, includeContent: !inspectionOnly)
                guard stamp.allocatedBytes >= minimumBytes else { return }
                if !inspectionOnly && stamp.newestModification > cutoff { return }
                seen.insert(path)
                let resolvedAppName = matching.first(where: { !$0.name.isEmpty })?.name
                    ?? environment.writableRoots.first(where: { FileSafety.isBelow(path, $0) }).flatMap { String(path.dropFirst($0.count + 1)).components(separatedBy: "/").first }
                    ?? URL(fileURLWithPath: path).lastPathComponent
                report.items.append(ScanItem(title: title ?? URL(fileURLWithPath: path).lastPathComponent,
                    appName: resolvedAppName,
                    category: category, tier: tier, path: path,
                    reason: rule.reason(in: lang), impactNote: rule.impact(in: lang), stamp: stamp,
                    ownerBundleIDs: ownerBundleIDs, ownerAppPaths: ownerAppPaths,
                    inspectionOnly: inspectionOnly, ruleKey: rule))
            } catch is CancellationError { }
            catch {
                warn(L10n.tr(
                    en: "Skipped \(display(path)): \(error.localizedDescription)",
                    ja: "\(display(path)) をスキップしました: \(error.localizedDescription)",
                    zh: "已跳过 \(display(path))：\(error.localizedDescription)",
                    language: lang
                ))
            }
        }
        func children(_ path: String, category: CleanupCategory, tier: CleanupTier, rule: ScanRuleKey) {
            for child in entries(path) where !child.hasPrefix(".") {
                add(path + "/" + child, category: category, tier: tier, rule: rule)
            }
        }

        await onProgress(L10n.tr(
            en: "Reading installed applications…",
            ja: "インストール済みアプリを読み取り中…",
            zh: "读取已安装应用…",
            language: lang
        ))
        func findApps(_ root: String, depth: Int) {
            guard depth <= 2, !Task.isCancelled else { return }
            for entry in entries(root) where !entry.hasPrefix(".") {
                let path = root + "/" + entry
                guard directory(path) else { continue }
                if entry.hasSuffix(".app") {
                    guard !apps.contains(where: { $0.path == path }) else { continue }
                    let plistURL = URL(fileURLWithPath: path + "/Contents/Info.plist")
                    let plist = (try? Data(contentsOf: plistURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                    let bundleName = String(entry.dropLast(4))
                    let displayName = (plist?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    apps.append(AppInfo(name: (displayName?.isEmpty == false ? displayName! : bundleName),
                                        bundleName: bundleName,
                                        bundleID: plist?["CFBundleIdentifier"] as? String ?? "", path: path))
                } else { findApps(path, depth: depth + 1) }
            }
        }
        for root in environment.applicationDirectories where fm.fileExists(atPath: root) { findApps(root, depth: 0) }

        await onProgress(L10n.tr(
            en: "Identifying update leftovers…",
            ja: "アップデートの残骸を識別中…",
            zh: "识别更新残留…",
            language: lang
        ))
        let caches = library + "/Caches"
        for entry in entries(caches) where !entry.hasPrefix(".") {
            let root = caches + "/" + entry
            guard directory(root) else { continue }
            if entry.lowercased().hasSuffix(".shipit") {
                for child in entries(root) where child.hasPrefix("update.") {
                    add(root + "/" + child, category: .updaterLeftovers, tier: .safe, rule: .shipIt)
                }
            }
        }
        // Structural discovery is bounded and never descends into arbitrary application data.
        func discover(_ path: String, depth: Int, inSupport: Bool) {
            guard depth <= 4, !Task.isCancelled else { return }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name == "org.sparkle-project.sparkle" {
                children(path + "/Installation", category: .updaterLeftovers, tier: .safe, rule: .sparkle)
                return
            }
            if name == "updatepackages" || name == "crx_cache" || (name == "update" && path.lowercased().contains("/larkshell/")) {
                children(path, category: .updaterLeftovers, tier: .review, rule: .genericUpdater)
                return
            }
            if name == "logs" || name == "log" { scanLogs(path, depth: 0); return }
            if inSupport && ["cache", "caches", "code cache", "gpucache", "cachestorage", "cacheddata", "cachedextensionvsixs"].contains(name) {
                children(path, category: .browserAndAppCache, tier: .review, rule: .appSupportCache)
                return
            }
            // Do not traverse databases, sessions, browser profiles' private data or content stores.
            let blocked: Set<String> = ["node_modules", "extensions", "globalstorage", "workspacestorage", "indexeddb", "local storage", "session storage", "sessions", "cookies", "databases", "storage", "documents", "drafts", "backups", "snapshots", "history", "chats", "messages", "xwechat_files", "weixin", "wechat", "jianyingpro"]
            guard !blocked.contains(name), !name.hasSuffix(".app") else { return }
            for child in entries(path) where !child.hasPrefix(".") {
                let next = path + "/" + child
                if directory(next) { discover(next, depth: depth + 1, inSupport: inSupport) }
            }
        }
        func scanLogs(_ path: String, depth: Int) {
            guard depth <= 5, !Task.isCancelled else { return }
            for child in entries(path) where !child.hasPrefix(".") {
                let next = path + "/" + child
                if directory(next) { scanLogs(next, depth: depth + 1) }
                else if Self.isLogFile(child) {
                    add(next, category: .logsAndDevCache, tier: .safe, rule: .logFile)
                }
            }
        }
        for entry in entries(caches) where !entry.hasPrefix(".") {
            let root = caches + "/" + entry
            guard directory(root), !entry.lowercased().hasSuffix(".shipit"), !["ms-playwright", "ms-playwright-go", "pip", "homebrew", "node-gyp", "macslim"].contains(entry.lowercased()) else { continue }
            discover(root, depth: 0, inSupport: false)
        }
        let support = library + "/Application Support"
        for entry in entries(support) where !entry.hasPrefix(".") && entry != "MacSlim" {
            let root = support + "/" + entry
            if directory(root) { discover(root, depth: 0, inSupport: true) }
        }
        // Container enumeration is limited to documented Library cache/log and updater locations.
        for entry in entries(library + "/Containers") where !entry.hasPrefix(".") {
            let data = library + "/Containers/" + entry + "/Data/Library"
            let updater = data + "/Global/UpdatePackages"
            if directory(updater) {
                children(updater, category: .updaterLeftovers, tier: .review, rule: .sandboxUpdater)
            }
            if directory(data + "/Logs") { scanLogs(data + "/Logs", depth: 0) }
            if directory(data + "/Caches") {
                for cacheEntry in entries(data + "/Caches") where !cacheEntry.hasPrefix(".") {
                    let cacheRoot = data + "/Caches/" + cacheEntry
                    if directory(cacheRoot) {
                        discover(cacheRoot, depth: 0, inSupport: false)
                        children(cacheRoot, category: .browserAndAppCache, tier: .review, rule: .sandboxCache)
                    }
                }
            }
        }

        await onProgress(L10n.tr(
            en: "Checking application caches and historical logs…",
            ja: "アプリキャッシュと過去のログを確認中…",
            zh: "检查应用缓存和历史日志…",
            language: lang
        ))
        let special: Set<String> = ["pip", "homebrew", "node-gyp", "ms-playwright", "ms-playwright-go", "macslim"]
        for entry in entries(caches) where !entry.hasPrefix(".") {
            let root = caches + "/" + entry
            let lower = entry.lowercased()
            guard !lower.hasSuffix(".shipit"), !special.contains(lower), !lower.hasPrefix("com.apple.") else { continue }
            if directory(root) {
                // Generic caches are opt-in. A Caches location alone is not proof of safe deletion.
                children(root, category: .browserAndAppCache, tier: .review, rule: .userCache)
            }
        }
        for name in ["pip", "Homebrew", "node-gyp"] {
            let root = caches + "/" + name
            if directory(root) {
                children(root, category: .logsAndDevCache, tier: .review, rule: .devToolCache)
            }
        }
        scanLogs(library + "/Logs", depth: 0)

        await onProgress(L10n.tr(
            en: "Verifying Playwright browser references…",
            ja: "Playwright ブラウザ参照を照合中…",
            zh: "核对 Playwright 浏览器引用…",
            language: lang
        ))
        let playwright = caches + "/ms-playwright"
        if directory(playwright) {
            do {
                let unused = try Self.unreferencedPlaywrightDirectories(at: playwright)
                for path in unused {
                    add(path, category: .logsAndDevCache, tier: .review, rule: .playwrightUnreferenced)
                }
            } catch {
                warn(L10n.tr(
                    en: "Preserved Playwright browsers: \(error.localizedDescription)",
                    ja: "Playwright ブラウザを保持しました: \(error.localizedDescription)",
                    zh: "已保留 Playwright 浏览器：\(error.localizedDescription)",
                    language: lang
                ))
            }
        }
        if directory(caches + "/ms-playwright-go") {
            warn(L10n.tr(
                en: "Preserved Playwright-Go runtime: cannot generically determine which versions remain in active use.",
                ja: "Playwright-Go ランタイムを保持しました: どのバージョンが使用中かを汎用的に判定できません。",
                zh: "已保留 Playwright-Go 运行时：无法通用判定哪些版本仍在使用。",
                language: lang
            ))
        }

        await onProgress(L10n.tr(
            en: "Checking legacy framework versions (inspection only)…",
            ja: "旧バージョンのフレームワークを確認中（確認専用）…",
            zh: "识别旧版内核（仅检查）…",
            language: lang
        ))
        for app in apps {
            let frameworks = app.path + "/Contents/Frameworks"
            guard directory(frameworks) else { continue }
            for framework in entries(frameworks) where framework.hasSuffix(".framework") {
                let versions = frameworks + "/" + framework + "/Versions"
                guard let current = try? fm.destinationOfSymbolicLink(atPath: versions + "/Current"),
                      !current.contains("/"), Self.numericVersion(current), directory(versions + "/" + current) else { continue }
                for version in entries(versions) where version != current && !version.hasPrefix(".") && Self.numericVersion(version) {
                    let path = versions + "/" + version
                    guard directory(path), version.compare(current, options: .numeric) == .orderedAscending else { continue }
                    add(path, category: .redundantFrameworks, tier: .review,
                        rule: .legacyFramework(current: current, version: version),
                        inspectionOnly: true, title: "\(app.name) · \(version)", owner: app)
                }
            }
        }
        report.canceled = Task.isCancelled
        if omittedWarnings > 0 {
            report.warnings.append(L10n.tr(
                en: "\(omittedWarnings) additional read or skip notice(s) omitted.",
                ja: "他に \(omittedWarnings) 件の読み取り・スキップ通知が省略されました。",
                zh: "另有 \(omittedWarnings) 条读取或跳过提示未展开。",
                language: lang
            ))
        }
        let order: [CleanupCategory] = [.updaterLeftovers, .browserAndAppCache, .logsAndDevCache, .redundantFrameworks]
        report.items.sort { $0.category == $1.category ? $0.sizeBytes > $1.sizeBytes : order.firstIndex(of: $0.category)! < order.firstIndex(of: $1.category)! }
        return report
    }

    private func display(_ path: String) -> String { path.replacingOccurrences(of: environment.homeDirectory, with: "~") }
    private func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    public static func numericVersion(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
    public static func isLogFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".log") || n.contains(".log.") || n.hasSuffix(".ips") || n.hasSuffix(".crash")
    }
    public static func unreferencedPlaywrightDirectories(at root: String) throws -> [String] {
        let fm = FileManager.default
        let links = root + "/.links"
        let refs = try fm.contentsOfDirectory(atPath: links)
        guard !refs.isEmpty else {
            throw SafetyError.refused(L10n.tr(
                en: "Missing valid .links references; cannot determine historical browser versions",
                ja: "有効な .links 参照がないため、過去のブラウザバージョンを判定できません",
                zh: "缺少有效的 .links 引用，无法判定历史版本"
            ))
        }
        var used = Set<String>()
        for link in refs {
            let package = try String(contentsOfFile: links + "/" + link, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard package.hasPrefix("/") else {
                throw SafetyError.refused(L10n.tr(
                    en: "Incomplete browser package reference",
                    ja: "ブラウザのパッケージ参照が不完全です",
                    zh: "浏览器引用不完整"
                ))
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: package + "/browsers.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let browsers = json["browsers"] as? [[String: Any]], !browsers.isEmpty else {
                throw SafetyError.refused(L10n.tr(
                    en: "Unknown browser manifest format",
                    ja: "ブラウザマニフェストの形式が不明です",
                    zh: "浏览器清单格式未知"
                ))
            }
            for browser in browsers {
                guard let name = browser["name"] as? String, let revision = browser["revision"] as? String else {
                    throw SafetyError.refused(L10n.tr(
                        en: "Incomplete browser version metadata",
                        ja: "ブラウザのバージョン情報が不完全です",
                        zh: "浏览器版本信息不完整"
                    ))
                }
                var revisions = [revision]
                if let overrides = browser["revisionOverrides"] as? [String: String] { revisions += overrides.values }
                for rev in revisions { used.insert(name.replacingOccurrences(of: "-", with: "_") + "-" + rev) }
            }
        }
        return try fm.contentsOfDirectory(atPath: root).filter { name in
            guard !name.hasPrefix("."), !used.contains(name), let dash = name.lastIndex(of: "-") else { return false }
            let prefix = String(name[..<dash]); let revision = name[name.index(after: dash)...]
            return ["chromium", "chromium_headless_shell", "firefox", "webkit", "ffmpeg"].contains(prefix) && !revision.isEmpty && revision.allSatisfy(\.isNumber)
        }.map { root + "/" + $0 }
    }
}
