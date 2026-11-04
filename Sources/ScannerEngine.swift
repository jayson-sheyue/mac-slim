import Foundation

public struct ScannerEngine: Sendable {
    public let environment: ScanEnvironment
    private let activity: @Sendable () -> ActivitySnapshot
    public init(environment: ScanEnvironment = ScanEnvironment(), activity: @escaping @Sendable () -> ActivitySnapshot = { .current() }) {
        self.environment = environment; self.activity = activity
    }

    private struct AppInfo {
        let name: String
        let bundleID: String
        let path: String
    }

    public func scan(config: ScannerConfig, onProgress: @Sendable (String) async -> Void) async -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let activity = activity()
        guard activity.reliable else {
            report.warnings = ["无法读取进程状态，已停止扫描。请重试，以免清理正在使用的数据。"]
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
                if (error as NSError).code != NSFileReadNoSuchFileError { warn("无法读取 \(display(path))：\(error.localizedDescription)") }
                return []
            }
        }
        func directory(_ path: String) -> Bool {
            (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeDirectory
        }
        func owners(_ path: String) -> [AppInfo] {
            let components = path.components(separatedBy: "/").map { normalized($0.replacingOccurrences(of: ".ShipIt", with: "", options: .caseInsensitive)) }
            let runningApps = activity.apps.map { AppInfo(name: URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent, bundleID: $0.bundleID, path: $0.path) }
            return (apps + runningApps).filter { app in
                let keys = [normalized(app.name), normalized(app.bundleID)]
                return components.contains { component in
                    component.count >= 4 && keys.contains { !$0.isEmpty && ($0 == component || $0.hasPrefix(component) || component.hasPrefix($0)) }
                }
            }
        }
        func add(_ path: String, category: CleanupCategory, tier: CleanupTier, reason: String, impact: String,
                 inspectionOnly: Bool = false, title: String? = nil, owner: AppInfo? = nil) {
            guard !Task.isCancelled, !seen.contains(path), !report.items.contains(where: { FileSafety.isBelow(path, $0.path) || FileSafety.isBelow($0.path, path) }) else { return }
            do {
                if !inspectionOnly { try FileSafety.validate(path, roots: environment.writableRoots) }
                let matching = owner.map { [$0] } ?? owners(path)
                guard inspectionOnly || !activity.isBusy(path: path, bundleIDs: matching.map(\.bundleID), appPaths: matching.map(\.path)) else {
                    warn("已跳过正在使用的项目：\(display(path))"); return
                }
                let stamp = try FileSafety.tree(path, rejectProtectedData: !inspectionOnly, includeContent: !inspectionOnly)
                guard stamp.allocatedBytes >= minimumBytes else { return }
                if !inspectionOnly && stamp.newestModification > cutoff { return }
                seen.insert(path)
                report.items.append(ScanItem(title: title ?? URL(fileURLWithPath: path).lastPathComponent,
                    appName: matching.first?.name ?? environment.writableRoots.first(where: { FileSafety.isBelow(path, $0) }).flatMap { String(path.dropFirst($0.count + 1)).components(separatedBy: "/").first } ?? URL(fileURLWithPath: path).lastPathComponent,
                    category: category, tier: tier, path: path, reason: reason, impactNote: impact, stamp: stamp,
                    ownerBundleIDs: matching.map(\.bundleID), ownerAppPaths: matching.map(\.path), inspectionOnly: inspectionOnly))
            } catch is CancellationError { }
            catch { warn("已跳过 \(display(path))：\(error.localizedDescription)") }
        }
        func children(_ path: String, category: CleanupCategory, tier: CleanupTier, reason: String, impact: String) {
            for child in entries(path) where !child.hasPrefix(".") {
                add(path + "/" + child, category: category, tier: tier, reason: reason, impact: impact)
            }
        }

        await onProgress("读取已安装应用…")
        func findApps(_ root: String, depth: Int) {
            guard depth <= 2, !Task.isCancelled else { return }
            for entry in entries(root) where !entry.hasPrefix(".") {
                let path = root + "/" + entry
                guard directory(path) else { continue }
                if entry.hasSuffix(".app") {
                    guard !apps.contains(where: { $0.path == path }) else { continue }
                    let plistURL = URL(fileURLWithPath: path + "/Contents/Info.plist")
                    let plist = (try? Data(contentsOf: plistURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                    apps.append(AppInfo(name: (plist?["CFBundleDisplayName"] as? String) ?? String(entry.dropLast(4)),
                                        bundleID: plist?["CFBundleIdentifier"] as? String ?? "", path: path))
                } else { findApps(path, depth: depth + 1) }
            }
        }
        for root in environment.applicationDirectories where fm.fileExists(atPath: root) { findApps(root, depth: 0) }

        await onProgress("识别更新残留…")
        let caches = library + "/Caches"
        for entry in entries(caches) where !entry.hasPrefix(".") {
            let root = caches + "/" + entry
            guard directory(root) else { continue }
            if entry.lowercased().hasSuffix(".shipit") {
                for child in entries(root) where child.hasPrefix("update.") {
                    add(root + "/" + child, category: .updaterLeftovers, tier: .safe,
                        reason: "ShipIt 更新解压目录，内容已超过保留天数未修改", impact: "将移除历史更新文件；以后更新可能需要重新下载。")
                }
            }
        }
        // Structural discovery is bounded and never descends into arbitrary application data.
        func discover(_ path: String, depth: Int, inSupport: Bool) {
            guard depth <= 4, !Task.isCancelled else { return }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name == "org.sparkle-project.sparkle" {
                children(path + "/Installation", category: .updaterLeftovers, tier: .safe,
                         reason: "Sparkle Installation 历史更新文件", impact: "不修改已安装的应用；以后更新可能重新下载。")
                return
            }
            if name == "updatepackages" || name == "crx_cache" || (name == "update" && path.lowercased().contains("/larkshell/")) {
                children(path, category: .updaterLeftovers, tier: .review, reason: "更新器的历史安装包目录",
                         impact: "目录名不能证明内容可删除，请先检查；以后更新可能需要重新下载。")
                return
            }
            if name == "logs" || name == "log" { scanLogs(path, depth: 0); return }
            if inSupport && ["cache", "caches", "code cache", "gpucache", "cachestorage", "cacheddata", "cachedextensionvsixs"].contains(name) {
                children(path, category: .browserAndAppCache, tier: .review, reason: "应用支持目录中的缓存结构",
                         impact: "请确认用途。离线资源可能丢失，应用可能需要重新下载或重建缓存。")
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
                    add(next, category: .logsAndDevCache, tier: .safe, reason: "日志目录中的历史日志文件",
                        impact: "删除后无法用于回查历史故障；近期写入的日志会保留。")
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
                children(updater, category: .updaterLeftovers, tier: .review, reason: "沙盒应用更新包目录",
                         impact: "请先确认这些是历史安装包；包含已识别个人数据的项目会保留。")
            }
            if directory(data + "/Logs") { scanLogs(data + "/Logs", depth: 0) }
            if directory(data + "/Caches") {
                for cacheEntry in entries(data + "/Caches") where !cacheEntry.hasPrefix(".") {
                    let cacheRoot = data + "/Caches/" + cacheEntry
                    if directory(cacheRoot) {
                        discover(cacheRoot, depth: 0, inSupport: false)
                        children(cacheRoot, category: .browserAndAppCache, tier: .review,
                                 reason: "沙盒应用 Library/Caches 缓存候选", impact: "请确认用途。离线资源可能需要重新下载。")
                    }
                }
            }
        }

        await onProgress("检查应用缓存和历史日志…")
        let special: Set<String> = ["pip", "homebrew", "node-gyp", "ms-playwright", "ms-playwright-go", "macslim"]
        for entry in entries(caches) where !entry.hasPrefix(".") {
            let root = caches + "/" + entry
            let lower = entry.lowercased()
            guard !lower.hasSuffix(".shipit"), !special.contains(lower), !lower.hasPrefix("com.apple.") else { continue }
            if directory(root) {
                // Generic caches are opt-in. A Caches location alone is not proof of safe deletion.
                children(root, category: .browserAndAppCache, tier: .review, reason: "用户 Library/Caches 下的应用缓存候选",
                         impact: "请检查用途。清理可能影响离线使用，并触发资源重新下载。")
            }
        }
        for name in ["pip", "Homebrew", "node-gyp"] {
            let root = caches + "/" + name
            if directory(root) {
                children(root, category: .logsAndDevCache, tier: .review, reason: "开发工具下载与构建缓存",
                         impact: "后续安装或编译可能重新下载；离线使用前请保留所需内容。")
            }
        }
        scanLogs(library + "/Logs", depth: 0)

        await onProgress("核对 Playwright 浏览器引用…")
        let playwright = caches + "/ms-playwright"
        if directory(playwright) {
            do {
                let unused = try Self.unreferencedPlaywrightDirectories(at: playwright)
                for path in unused {
                    add(path, category: .logsAndDevCache, tier: .review,
                        reason: "Playwright .links 登记的所有有效包均未引用此版本", impact: "只列出可验证未被引用的旧浏览器。未登记或自定义路径的项目仍可能需要它，请先检查。")
                }
            } catch { warn("已保留 Playwright 浏览器：\(error.localizedDescription)") }
        }
        if directory(caches + "/ms-playwright-go") { warn("已保留 Playwright-Go 运行时：无法通用判定哪些版本仍在使用。") }

        await onProgress("识别旧版内核（仅检查）…")
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
                        reason: "Current 指向 \(current)，发现较早版本 \(version)",
                        impact: "仅供检查。为保护应用签名和运行完整性，不自动修改应用包；请通过应用官方更新或重新安装处理。",
                        inspectionOnly: true, title: "\(app.name) · \(version)", owner: app)
                }
            }
        }
        report.canceled = Task.isCancelled
        if omittedWarnings > 0 { report.warnings.append("另有 \(omittedWarnings) 条读取或跳过提示未展开。") }
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
        guard !refs.isEmpty else { throw SafetyError.refused("缺少有效的 .links 引用，无法判定历史版本") }
        var used = Set<String>()
        for link in refs {
            let package = try String(contentsOfFile: links + "/" + link, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard package.hasPrefix("/") else { throw SafetyError.refused("浏览器引用不完整") }
            let data = try Data(contentsOf: URL(fileURLWithPath: package + "/browsers.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let browsers = json["browsers"] as? [[String: Any]], !browsers.isEmpty else { throw SafetyError.refused("浏览器清单格式未知") }
            for browser in browsers {
                guard let name = browser["name"] as? String, let revision = browser["revision"] as? String else { throw SafetyError.refused("浏览器版本信息不完整") }
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
