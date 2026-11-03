import Foundation
import CoreServices

public struct ScanEnvironment: Sendable {
    public let homeDirectory: String
    public let applicationsDirectory: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        applicationsDirectory: String = "/Applications"
    ) {
        self.homeDirectory = homeDirectory
        self.applicationsDirectory = applicationsDirectory
    }
}

public final class ScannerEngine: Sendable {
    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment = ScanEnvironment()) {
        self.environment = environment
    }

    // MARK: - Main Scan Entry Point

    public func scan(
        config: ScannerConfig,
        onProgress: @Sendable (String) -> Void
    ) async -> [ScanItem] {
        var results: [ScanItem] = []
        let minCacheBytes = Int64(max(1, config.minCacheSizeMB)) * 1024 * 1024

        if Task.isCancelled { return [] }
        onProgress("正在扫描应用包内旧版冗余内核与安装包残留...")
        results.append(contentsOf: scanRedundantFrameworksAndAppDirLeftovers(minBytes: minCacheBytes))

        if Task.isCancelled { return [] }
        onProgress("正在扫描自动更新框架（ShipIt / Sparkle / 腾讯会议 / 飞书）残留...")
        results.append(contentsOf: scanUpdaterLeftovers(minBytes: minCacheBytes))

        if Task.isCancelled { return [] }
        onProgress("正在扫描浏览器 Service Worker 与办公应用运行缓存...")
        results.append(contentsOf: scanBrowserAndAppCaches(minBytes: minCacheBytes))

        if Task.isCancelled { return [] }
        onProgress("正在扫描膨胀日志与开发工具下载缓存...")
        results.append(contentsOf: scanLogsAndDevCaches(minBytes: minCacheBytes))

        if Task.isCancelled { return [] }
        onProgress("正在检测可无损重组的膨胀数据库与快照...")
        results.append(contentsOf: scanDatabaseCompactionTargets(config: config))

        if Task.isCancelled { return [] }
        onProgress("正在检测长期未使用的大体积应用程序...")
        results.append(contentsOf: scanDormantApplications(config: config))

        // Sort largest first within each tier
        return results.sorted { a, b in
            if a.tier != b.tier {
                return a.tier == .safe
            }
            return a.sizeBytes > b.sizeBytes
        }
    }

    // MARK: - 1. Redundant Frameworks & /Applications Leftovers

    public func scanRedundantFrameworksAndAppDirLeftovers(minBytes: Int64) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let appsDir = environment.applicationsDirectory

        guard let entries = try? fm.contentsOfDirectory(atPath: appsDir) else {
            return items
        }

        for entry in entries {
            if Task.isCancelled { break }
            let fullPath = (appsDir as NSString).appendingPathComponent(entry)

            // 1a. Hidden .*-previous*.app backup bundles in /Applications
            if entry.hasPrefix(".") && entry.hasSuffix(".app") && entry.localizedCaseInsensitiveContains("previous") {
                let size = Self.directorySize(atPath: fullPath)
                if size >= minBytes {
                    items.append(ScanItem(
                        title: "隐藏的旧版应用备份 (\(entry))",
                        appName: entry.replacingOccurrences(of: ".", with: ""),
                        category: .redundantFrameworks,
                        tier: .safe,
                        path: fullPath,
                        sizeBytes: size,
                        actionType: .removeItem,
                        reason: "应用升级时在 /Applications 根目录遗留的隐藏旧版本备份包",
                        impactNote: "完全无感：当前正式版应用不受任何影响"
                    ))
                }
                continue
            }

            // 1b. Loose .dmg or .pkg installer files left inside /Applications
            let lower = entry.lowercased()
            if lower.hasSuffix(".dmg") || lower.hasSuffix(".pkg") {
                let size = Self.directorySize(atPath: fullPath)
                if size >= minBytes {
                    items.append(ScanItem(
                        title: "遗留在应用程序目录的安装包 (\(entry))",
                        appName: "安装包镜像",
                        category: .updaterLeftovers,
                        tier: .safe,
                        path: fullPath,
                        sizeBytes: size,
                        actionType: .removeItem,
                        reason: "安装软件时误拖入 /Applications 目录的 .dmg/.pkg 磁盘镜像文件",
                        impactNote: "完全无感：已安装的应用程序本体无需此安装镜像即可正常运行"
                    ))
                }
                continue
            }

            // 1c. Multi-version frameworks inside .app/Contents/Frameworks/*.framework/Versions
            if entry.hasSuffix(".app") {
                let frameworksDir = (fullPath as NSString).appendingPathComponent("Contents/Frameworks")
                guard let fwEntries = try? fm.contentsOfDirectory(atPath: frameworksDir) else { continue }

                for fw in fwEntries where fw.hasSuffix(".framework") {
                    let versionsDir = ((frameworksDir as NSString).appendingPathComponent(fw) as NSString)
                        .appendingPathComponent("Versions")
                    let currentLinkPath = (versionsDir as NSString).appendingPathComponent("Current")

                    guard let targetVersion = try? fm.destinationOfSymbolicLink(atPath: currentLinkPath) else {
                        continue
                    }
                    let activeVersionName = (targetVersion as NSString).lastPathComponent
                    guard !activeVersionName.isEmpty, activeVersionName != "A", activeVersionName != "B" else {
                        continue
                    }

                    guard let versionDirs = try? fm.contentsOfDirectory(atPath: versionsDir) else { continue }
                    for ver in versionDirs {
                        if ver == "Current" || ver == activeVersionName || ver.hasPrefix(".") { continue }
                        let verPath = (versionsDir as NSString).appendingPathComponent(ver)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: verPath, isDirectory: &isDir), isDir.boolValue else { continue }

                        let size = Self.directorySize(atPath: verPath)
                        if size >= minBytes {
                            let appDisplayName = (entry as NSString).deletingPathExtension
                            items.append(ScanItem(
                                title: "\(appDisplayName) 旧版内核框架 (v\(ver))",
                                appName: appDisplayName,
                                category: .redundantFrameworks,
                                tier: .safe,
                                path: verPath,
                                sizeBytes: size,
                                actionType: .removeItem,
                                reason: "当前激活内核为 v\(activeVersionName)，v\(ver) 为热更新后未自动删除的旧版本框架",
                                impactNote: "完全无感：不破坏应用签名，若该应用正在运行，清理后重启一次应用即可"
                            ))
                        }
                    }
                }
            }
        }

        return items
    }

    // MARK: - 2. Auto-Updater Leftovers

    public func scanUpdaterLeftovers(minBytes: Int64) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let home = environment.homeDirectory
        let cachesDir = (home as NSString).appendingPathComponent("Library/Caches")

        // 2a. Electron Squirrel/ShipIt update folders & Sparkle Installation folders
        if let cacheEntries = try? fm.contentsOfDirectory(atPath: cachesDir) {
            for entry in cacheEntries {
                if Task.isCancelled { break }
                // Skip active Antigravity updater cache while running inside Antigravity
                if entry.localizedCaseInsensitiveContains("antigravity") { continue }

                let fullPath = (cachesDir as NSString).appendingPathComponent(entry)

                // ShipIt updater directories
                if entry.hasSuffix(".ShipIt") {
                    guard let subEntries = try? fm.contentsOfDirectory(atPath: fullPath) else { continue }
                    let updateFolders = subEntries.filter { $0.hasPrefix("update.") }
                    for updateFolder in updateFolders {
                        let updatePath = (fullPath as NSString).appendingPathComponent(updateFolder)
                        let size = Self.directorySize(atPath: updatePath)
                        if size >= minBytes {
                            let appLabel = Self.friendlyAppName(forCacheKey: entry)
                            items.append(ScanItem(
                                title: "\(appLabel) 自动更新临时解压包 (\(updateFolder))",
                                appName: appLabel,
                                category: .updaterLeftovers,
                                tier: .safe,
                                path: updatePath,
                                sizeBytes: size,
                                actionType: .removeItem,
                                reason: "Electron ShipIt 更新器在后台解压的完整旧版 .app 临时副本",
                                impactNote: "完全无感：已安装的正式版应用不受影响"
                            ))
                        }
                    }
                }

                // Sparkle updater Installation directories
                let sparkleInstallPath = (fullPath as NSString)
                    .appendingPathComponent("org.sparkle-project.Sparkle/Installation")
                if fm.fileExists(atPath: sparkleInstallPath) {
                    let size = Self.directorySize(atPath: sparkleInstallPath)
                    if size >= minBytes {
                        let appLabel = Self.friendlyAppName(forCacheKey: entry)
                        items.append(ScanItem(
                            title: "\(appLabel) Sparkle 更新安装包残留",
                            appName: appLabel,
                            category: .updaterLeftovers,
                            tier: .safe,
                            path: sparkleInstallPath,
                            sizeBytes: size,
                            actionType: .removeItem,
                            reason: "Sparkle 更新框架升级完成后遗留的 .zip 压缩包与已解压 .app 副本",
                            impactNote: "完全无感：不影响当前应用及用户数据"
                        ))
                    }
                }
            }
        }

        // 2b. TencentMeeting UpdatePackages (curPkgBackup & unarchive)
        let wemeetUpdateDir = (home as NSString)
            .appendingPathComponent("Library/Containers/com.tencent.meeting/Data/Library/Global/UpdatePackages")
        if fm.fileExists(atPath: wemeetUpdateDir) {
            let size = Self.directorySize(atPath: wemeetUpdateDir)
            if size >= minBytes {
                items.append(ScanItem(
                    title: "腾讯会议历史版本更新备份包 (UpdatePackages)",
                    appName: "腾讯会议",
                    category: .updaterLeftovers,
                    tier: .safe,
                    path: wemeetUpdateDir,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: "腾讯会议每次版本升级后在沙盒容器内备份的历史安装包（常堆积十几个版本）",
                    impactNote: "完全无感：不影响腾讯会议登录状态、会议记录与正常参会"
                ))
            }
        }

        // 2c. Feishu / LarkShell update directory
        let larkUpdateDir = (home as NSString)
            .appendingPathComponent("Library/Application Support/LarkShell/update")
        if fm.fileExists(atPath: larkUpdateDir) {
            let size = Self.directorySize(atPath: larkUpdateDir)
            if size >= minBytes {
                items.append(ScanItem(
                    title: "飞书自动更新安装包缓存 (LarkShell/update)",
                    appName: "飞书",
                    category: .updaterLeftovers,
                    tier: .safe,
                    path: larkUpdateDir,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: "飞书后台下载并解压客户端更新留下的临时安装文件",
                    impactNote: "完全无感：不触碰飞书聊天记录与账号登录状态"
                ))
            }
        }

        // 2d. GoogleUpdater crx_cache
        let googleUpdaterCache = (home as NSString)
            .appendingPathComponent("Library/Application Support/Google/GoogleUpdater/crx_cache")
        if fm.fileExists(atPath: googleUpdaterCache) {
            let size = Self.directorySize(atPath: googleUpdaterCache)
            if size >= minBytes {
                items.append(ScanItem(
                    title: "Google 自动更新器组件包缓存 (crx_cache)",
                    appName: "Google Chrome",
                    category: .updaterLeftovers,
                    tier: .safe,
                    path: googleUpdaterCache,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: "GoogleUpdater 缓存的浏览器与组件历史更新包",
                    impactNote: "完全无感：不影响 Chrome 浏览器或已安装扩展程序"
                ))
            }
        }

        return items
    }

    // MARK: - 3. Browser Service Worker & App Caches

    public func scanBrowserAndAppCaches(minBytes: Int64) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let home = environment.homeDirectory

        // 3a. Chrome Service Worker CacheStorage across Default & Profile *
        let chromeAppSupport = (home as NSString)
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        if let chromeEntries = try? fm.contentsOfDirectory(atPath: chromeAppSupport) {
            var swPaths: [String] = []
            var totalSWBytes: Int64 = 0

            for entry in chromeEntries {
                guard entry == "Default" || entry.hasPrefix("Profile ") else { continue }
                let swCachePath = ((chromeAppSupport as NSString).appendingPathComponent(entry) as NSString)
                    .appendingPathComponent("Service Worker/CacheStorage")
                if fm.fileExists(atPath: swCachePath) {
                    let size = Self.directorySize(atPath: swCachePath)
                    if size > 0 {
                        swPaths.append(swCachePath)
                        totalSWBytes += size
                    }
                }
            }

            if totalSWBytes >= minBytes, let primaryPath = swPaths.first {
                items.append(ScanItem(
                    title: "Chrome 网页 Service Worker 离线资源缓存 (\(swPaths.count) 个配置目录)",
                    appName: "Google Chrome",
                    category: .browserAndAppCache,
                    tier: .safe,
                    path: primaryPath,
                    additionalPaths: Array(swPaths.dropFirst()),
                    sizeBytes: totalSWBytes,
                    actionType: .removeItem,
                    reason: "各网站通过 Service Worker 在本地缓存的静态前端脚本与媒体资源（与 Cookie/书签完全独立）",
                    impactNote: "完全无感：保留所有网站登录态、密码、书签与历史记录；仅部分网站首次重开时重新缓存静态脚本"
                ))
            }
        }

        // 3b. Known safe ~/Library/Caches targets
        let knownCaches: [(relPath: String, title: String, appName: String, desc: String)] = [
            ("Library/Caches/Google/Chrome", "Chrome 浏览器 HTTP 与编译缓存", "Google Chrome", "Chrome 本地网页图片、脚本与渲染缓存"),
            ("Library/Caches/LarkShell", "飞书运行与媒体缩略图缓存", "飞书", "飞书在 Caches 目录下生成的临时图片与资源缓存（不含聊天数据库）"),
            ("Library/Caches/com.tencent.meeting", "腾讯会议运行缓存", "腾讯会议", "腾讯会议临时音视频与界面缓存"),
            ("Library/Caches/com.lemon.lvpro", "剪映专业版运行缓存", "剪映专业版", "剪映在系统 Caches 目录下的临时缓存（不含剪辑草稿）"),
            ("Library/Caches/Bytedance", "字节跳动组件公共缓存", "剪映 / 飞书", "字节跳动系应用共享的临时网络与渲染缓存"),
            ("Library/Caches/Trae CN", "Trae CN 运行缓存", "Trae CN", "Trae 编辑器在 Caches 目录下的可再生缓存"),
            ("Library/Caches/com.alibaba.DingTalkMac", "钉钉运行与媒体缓存", "钉钉", "钉钉在 Caches 目录下的临时图片与页面缓存"),
            ("Library/Caches/com.google.GeminiMacOS", "Gemini 桌面端运行缓存", "Gemini", "Gemini 桌面客户端临时运行缓存"),
            ("Library/Caches/com.linguee.DeepLCopyTranslator", "DeepL 翻译运行缓存", "DeepL", "DeepL 临时网络与静态资源缓存"),
            ("Library/Caches/Codex", "Codex 临时运行缓存", "ChatGPT / Codex", "Codex 桌面组件临时缓存")
        ]

        for target in knownCaches {
            if Task.isCancelled { break }
            let fullPath = (home as NSString).appendingPathComponent(target.relPath)
            guard fm.fileExists(atPath: fullPath) else { continue }
            let size = Self.directorySize(atPath: fullPath)
            if size >= minBytes {
                items.append(ScanItem(
                    title: target.title,
                    appName: target.appName,
                    category: .browserAndAppCache,
                    tier: .safe,
                    path: fullPath,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: target.desc,
                    impactNote: "完全无感：位于系统标准 ~/Library/Caches 目录，应用需要时会自动按需重建"
                ))
            }
        }

        return items
    }

    // MARK: - 4. Logs & Developer Tool Caches

    public func scanLogsAndDevCaches(minBytes: Int64) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let home = environment.homeDirectory

        let logAndDevTargets: [(relPath: String, title: String, appName: String, desc: String)] = [
            ("Library/Application Support/mihomo-party/logs", "Clash Party (mihomo) 历史运行日志", "Clash Party", "代理客户端持续追加写入的网络连接日志文件"),
            ("Library/Application Support/LarkShell/sdk_storage/log", "飞书底层 SDK 诊断日志", "飞书", "飞书客户端后台记录的 SDK 历史运行日志"),
            ("Library/Containers/com.tencent.meeting/Data/Library/Global/Logs", "腾讯会议历史诊断日志", "腾讯会议", "腾讯会议沙盒容器内堆积的日志文件"),
            ("Library/Application Support/Cursor/logs", "Cursor 编辑器历史运行日志", "Cursor", "Cursor 每次启动生成的插件宿主与渲染进程日志"),
            ("Library/Application Support/Cursor/CachedExtensionVSIXs/.trash", "Cursor 已卸载插件安装包残留 (.trash)", "Cursor", "卸载或升级插件后遗留在 .trash 中的 .vsix 安装包"),
            ("Library/Application Support/Cursor/CachedData", "Cursor 旧版本 V8 字节码编译缓存", "Cursor", "Cursor 历史版本生成的 JS 字节码缓存"),
            ("Library/Application Support/Code/logs", "VS Code 历史运行日志", "VS Code", "VS Code 每次运行生成的历史日志文件"),
            ("Library/Application Support/Code/CachedExtensionVSIXs", "VS Code 插件已下载 VSIX 缓存包", "VS Code", "插件安装完成后仍保留在本地的 .vsix 压缩包"),
            ("Library/Application Support/Code/CachedData", "VS Code V8 字节码编译缓存", "VS Code", "VS Code 历史版本的 V8 字节码缓存"),
            ("Library/Caches/pip", "Python pip 历史下载 Wheel 缓存包", "Python / pip", "执行 pip install 时缓存的 .whl 与源码压缩包"),
            ("Library/Caches/Homebrew", "Homebrew 已安装软件包下载缓存", "Homebrew", "brew install 下载后保留在本地的安装包归档"),
            ("Library/Caches/ms-playwright", "Playwright 自动化测试浏览器内核缓存", "Playwright", "Playwright 下载的测试用 Chromium / Firefox / WebKit 浏览器包"),
            ("Library/Caches/ms-playwright-go", "Playwright-Go 测试浏览器内核缓存", "Playwright", "Playwright-Go 下载的测试浏览器内核包"),
            ("Library/Caches/node-gyp", "Node-gyp 原生模块编译头文件缓存", "Node.js", "编译 Node 原生扩展时下载的 Node 源码头文件缓存")
        ]

        for target in logAndDevTargets {
            if Task.isCancelled { break }
            let fullPath = (home as NSString).appendingPathComponent(target.relPath)
            guard fm.fileExists(atPath: fullPath) else { continue }
            let size = Self.directorySize(atPath: fullPath)
            if size >= minBytes {
                items.append(ScanItem(
                    title: target.title,
                    appName: target.appName,
                    category: .logsAndDevCache,
                    tier: .safe,
                    path: fullPath,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: target.desc,
                    impactNote: "完全无感：已安装的开发工具、Python 库与软件配置不受任何影响"
                ))
            }
        }

        // Also scan ~/Library/Logs subdirectories exceeding threshold
        let systemLogsDir = (home as NSString).appendingPathComponent("Library/Logs")
        if let logEntries = try? fm.contentsOfDirectory(atPath: systemLogsDir) {
            for entry in logEntries where !entry.hasPrefix(".") {
                if Task.isCancelled { break }
                if entry.localizedCaseInsensitiveContains("antigravity") { continue }
                let fullPath = (systemLogsDir as NSString).appendingPathComponent(entry)
                let size = Self.directorySize(atPath: fullPath)
                if size >= minBytes {
                    items.append(ScanItem(
                        title: "\(entry) 诊断与崩溃日志 (Library/Logs/\(entry))",
                        appName: entry,
                        category: .logsAndDevCache,
                        tier: .safe,
                        path: fullPath,
                        sizeBytes: size,
                        actionType: .removeChildren,
                        reason: "应用在 ~/Library/Logs 下累积的运行日志与崩溃诊断文件",
                        impactNote: "完全无感：仅清理历史诊断日志，不影响应用功能与个人数据"
                    ))
                }
            }
        }

        return items
    }

    // MARK: - 5. Database Lossless Compaction (Deep Tier)

    public func scanDatabaseCompactionTargets(config: ScannerConfig) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let home = environment.homeDirectory
        let thresholdBytes = Int64(max(1, config.cursorDBCompactThresholdMB)) * 1024 * 1024

        // 5a. Cursor state.vscdb lossless rebuild
        let cursorDBPath = (home as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        if fm.fileExists(atPath: cursorDBPath) {
            let dbSize = Self.directorySize(atPath: cursorDBPath)
            let walSize = Self.directorySize(atPath: cursorDBPath + "-wal")
            let totalSize = dbSize + walSize
            if totalSize >= thresholdBytes {
                items.append(ScanItem(
                    title: "Cursor 状态数据库无损重组 (state.vscdb)",
                    appName: "Cursor",
                    category: .databaseCompact,
                    tier: .deep,
                    path: cursorDBPath,
                    additionalPaths: [cursorDBPath + "-wal", cursorDBPath + "-shm"],
                    sizeBytes: totalSize,
                    actionType: .rebuildCursorStateDB,
                    reason: "Cursor 将所有历史 AI 对话气泡 (bubbleId) 与代码检查点 (checkpointId) 堆积在 cursorDiskKV 表中，常膨胀至数 GB 甚至十几个 GB",
                    impactNote: "需确认：100% 保留 ItemTable 中的账号登录态、个人配置与插件状态；仅清空历史旧 AI 聊天记录与旧 Checkpoint（执行前会自动安全退出 Cursor）",
                    isSelected: false
                ))
            }
        }

        // 5b. Cursor snapshots directory
        let cursorSnapshotsPath = (home as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/snapshots")
        if fm.fileExists(atPath: cursorSnapshotsPath) {
            let size = Self.directorySize(atPath: cursorSnapshotsPath)
            if size >= Int64(max(1, config.minCacheSizeMB)) * 1024 * 1024 {
                items.append(ScanItem(
                    title: "Cursor 历史代码快照索引缓存 (Cursor/snapshots)",
                    appName: "Cursor",
                    category: .databaseCompact,
                    tier: .deep,
                    path: cursorSnapshotsPath,
                    sizeBytes: size,
                    actionType: .removeChildren,
                    reason: "Cursor 本地保存的历史代码库快照与索引存储",
                    impactNote: "需确认：清理后不影响本地项目源码文件与 Git 记录，仅清除 Cursor 内部历史快照缓存",
                    isSelected: false
                ))
            }
        }

        return items
    }

    // MARK: - 6. Dormant Large Applications (Deep Tier)

    public func scanDormantApplications(config: ScannerConfig) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        let appsDir = environment.applicationsDirectory
        let home = environment.homeDirectory
        let minAppBytes = Int64(max(1, config.dormantAppMinSizeMB)) * 1024 * 1024
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -max(7, config.dormantAppDaysThreshold), to: Date()) ?? Date.distantPast

        guard let entries = try? fm.contentsOfDirectory(atPath: appsDir) else {
            return items
        }

        let protectedApps: Set<String> = [
            "Safari.app", "Keynote.app", "Pages.app", "Numbers.app", "Antigravity.app", "MacSlim.app"
        ]

        for entry in entries where entry.hasSuffix(".app") && !entry.hasPrefix(".") {
            if Task.isCancelled { break }
            if protectedApps.contains(entry) { continue }

            let appPath = (appsDir as NSString).appendingPathComponent(entry)
            let url = URL(fileURLWithPath: appPath)

            // Determine last used date via Spotlight kMDItemLastUsedDate or bundle modification date
            var lastUsedDate: Date? = nil
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
               let mdDate = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
                lastUsedDate = mdDate
            }
            if lastUsedDate == nil {
                if let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
                    lastUsedDate = resourceValues.contentModificationDate
                }
            }
            guard let lastDate = lastUsedDate, lastDate < cutoffDate else {
                continue
            }

            // Skip apps with 1980-01-01 epoch placeholder timestamps (e.g., Cursor.app build epoch)
            if lastDate.timeIntervalSince1970 < 365 * 24 * 3600 * 15 {
                continue
            }

            let appSize = Self.directorySize(atPath: appPath)
            guard appSize >= minAppBytes else { continue }

            // Check if there is an associated Container directory via CFBundleIdentifier
            var extraPaths: [String] = []
            var totalBytes = appSize
            let infoPlistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOfFile: infoPlistPath),
               let bundleId = plist["CFBundleIdentifier"] as? String {
                let containerDataPath = (home as NSString)
                    .appendingPathComponent("Library/Containers/\(bundleId)/Data")
                if fm.fileExists(atPath: containerDataPath) {
                    let containerSize = Self.directorySize(atPath: containerDataPath)
                    if containerSize > 0 {
                        extraPaths.append(containerDataPath)
                        totalBytes += containerSize
                    }
                }
            }

            let appDisplayName = (entry as NSString).deletingPathExtension
            let daysAgo = max(1, Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? config.dormantAppDaysThreshold)

            items.append(ScanItem(
                title: "\(appDisplayName)（已 \(daysAgo) 天未打开）",
                appName: appDisplayName,
                category: .dormantApps,
                tier: .deep,
                path: appPath,
                additionalPaths: extraPaths,
                sizeBytes: totalBytes,
                actionType: .removeAppAndContainers,
                reason: "该应用超过 \(daysAgo) 天未使用，应用本体及关联沙盒容器共占用 \(ByteFormatting.string(fromBytes: totalBytes))",
                impactNote: "需确认：将移除该应用程序本体\(extraPaths.isEmpty ? "" : "及其关联容器数据")（若选“移至废纸篓”可从废纸篓还原）",
                isSelected: false,
                lastAccessedDate: lastDate
            ))
        }

        return items
    }

    // MARK: - Demo Case Generator (79.3 GB Real-World Case Preview)

    public static func demoBlockerDataset() -> [ScanItem] {
        let gb: Int64 = 1024 * 1024 * 1024
        let mb: Int64 = 1024 * 1024
        return [
            ScanItem(
                title: "Chrome 网页 Service Worker 离线资源缓存 (2 个配置目录)",
                appName: "Google Chrome",
                category: .browserAndAppCache,
                tier: .safe,
                path: "~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                additionalPaths: ["~/Library/Application Support/Google/Chrome/Profile 2/Service Worker/CacheStorage"],
                sizeBytes: 15 * gb + 716 * mb,
                actionType: .removeItem,
                reason: "各网站通过 Service Worker 在本地缓存的静态前端脚本与媒体资源（与 Cookie/书签完全独立）",
                impactNote: "完全无感：保留所有网站登录态、密码、书签与历史记录",
                isDemoItem: true
            ),
            ScanItem(
                title: "腾讯会议历史版本更新备份包 (UpdatePackages - 17 个历史版本)",
                appName: "腾讯会议",
                category: .updaterLeftovers,
                tier: .safe,
                path: "~/Library/Containers/com.tencent.meeting/Data/Library/Global/UpdatePackages",
                sizeBytes: 14 * gb + 120 * mb,
                actionType: .removeChildren,
                reason: "腾讯会议每次版本升级后在沙盒容器 curPkgBackup 与 unarchive 内备份的历史安装包",
                impactNote: "完全无感：不影响腾讯会议登录状态、会议记录与正常参会",
                isDemoItem: true
            ),
            ScanItem(
                title: "Clash Party (mihomo) 历史运行日志",
                appName: "Clash Party",
                category: .logsAndDevCache,
                tier: .safe,
                path: "~/Library/Application Support/mihomo-party/logs",
                sizeBytes: 6 * gb + 40 * mb,
                actionType: .removeChildren,
                reason: "代理客户端持续追加写入的网络连接日志文件",
                impactNote: "完全无感：不影响代理节点配置与规则",
                isDemoItem: true
            ),
            ScanItem(
                title: "Chrome 浏览器 HTTP 与编译缓存",
                appName: "Google Chrome",
                category: .browserAndAppCache,
                tier: .safe,
                path: "~/Library/Caches/Google/Chrome",
                sizeBytes: 5 * gb + 210 * mb,
                actionType: .removeChildren,
                reason: "Chrome 本地网页图片、脚本与渲染缓存",
                impactNote: "完全无感：位于系统标准 Caches 目录，不触碰书签与密码",
                isDemoItem: true
            ),
            ScanItem(
                title: "飞书运行与媒体缩略图缓存",
                appName: "飞书",
                category: .browserAndAppCache,
                tier: .safe,
                path: "~/Library/Caches/LarkShell",
                sizeBytes: 4 * gb + 110 * mb,
                actionType: .removeChildren,
                reason: "飞书在 Caches 目录下生成的临时图片与资源缓存（不含聊天数据库）",
                impactNote: "完全无感：聊天记录与登录状态完好保留",
                isDemoItem: true
            ),
            ScanItem(
                title: "飞书自动更新安装包缓存 (LarkShell/update)",
                appName: "飞书",
                category: .updaterLeftovers,
                tier: .safe,
                path: "~/Library/Application Support/LarkShell/update",
                sizeBytes: 2 * gb + 420 * mb,
                actionType: .removeChildren,
                reason: "飞书后台下载并解压客户端更新留下的临时安装文件",
                impactNote: "完全无感：不触碰飞书聊天记录与账号登录状态",
                isDemoItem: true
            ),
            ScanItem(
                title: "ChatGPT / Codex Sparkle 更新安装包残留",
                appName: "ChatGPT",
                category: .updaterLeftovers,
                tier: .safe,
                path: "~/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation",
                sizeBytes: 2 * gb + 410 * mb,
                actionType: .removeItem,
                reason: "Sparkle 更新框架升级完成后遗留的 748MB .zip 压缩包与 1.6GB 已解压 ChatGPT.app",
                impactNote: "完全无感：不影响当前已安装的 ChatGPT 应用",
                isDemoItem: true
            ),
            ScanItem(
                title: "Cursor 自动更新临时解压包 (2 个历史残留副本)",
                appName: "Cursor",
                category: .updaterLeftovers,
                tier: .safe,
                path: "~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
                sizeBytes: 2 * gb + 90 * mb,
                actionType: .removeChildren,
                reason: "Electron ShipIt 更新器在后台解压的两个完整旧版 Cursor.app 临时副本",
                impactNote: "完全无感：已安装的正式版 Cursor 不受影响",
                isDemoItem: true
            ),
            ScanItem(
                title: "VS Code 自动更新临时解压包 (update.l3sl9Ii)",
                appName: "VS Code",
                category: .updaterLeftovers,
                tier: .safe,
                path: "~/Library/Caches/com.microsoft.VSCode.ShipIt/update.l3sl9Ii",
                sizeBytes: 1 * gb + 512 * mb,
                actionType: .removeItem,
                reason: "ShipIt 更新器升级后遗留的完整旧版 Visual Studio Code.app",
                impactNote: "完全无感：不影响当前 VS Code 及任何插件",
                isDemoItem: true
            ),
            ScanItem(
                title: "Python pip 历史下载 Wheel 缓存包",
                appName: "Python / pip",
                category: .logsAndDevCache,
                tier: .safe,
                path: "~/Library/Caches/pip",
                sizeBytes: 1 * gb + 510 * mb,
                actionType: .removeChildren,
                reason: "执行 pip install 时缓存的 .whl 与源码压缩包",
                impactNote: "完全无感：已安装的 Python 库不受任何影响",
                isDemoItem: true
            ),
            ScanItem(
                title: "Google Chrome 旧版内核框架 (v153.0.8010.48 & v156.0.8078.73)",
                appName: "Google Chrome",
                category: .redundantFrameworks,
                tier: .safe,
                path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/156.0.8078.73",
                additionalPaths: ["/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153.0.8010.48"],
                sizeBytes: 1 * gb + 435 * mb,
                actionType: .removeItem,
                reason: "当前激活内核为 v156.0.8078.79，包内同时残留了两个旧版本完整内核框架",
                impactNote: "完全无感：使 Chrome.app 本体直接从 2.27 GB 降至 731 MB",
                isDemoItem: true
            ),
            ScanItem(
                title: "Cursor 状态数据库无损重组 (state.vscdb)",
                appName: "Cursor",
                category: .databaseCompact,
                tier: .deep,
                path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                sizeBytes: 13 * gb + 810 * mb,
                actionType: .rebuildCursorStateDB,
                reason: "cursorDiskKV 表堆积了数十万条历史 AI 对话气泡与 Checkpoint 快照，而核心配置 ItemTable 仅 1.7 MB",
                impactNote: "需确认：100% 保留账号登录态、个人配置与插件状态；仅清空历史旧 AI 聊天记录（从 13.8 GB 缩减至 1.8 MB）",
                isSelected: false,
                isDemoItem: true
            ),
            ScanItem(
                title: "wpsoffice（已 1190 天未打开）",
                appName: "WPS Office",
                category: .dormantApps,
                tier: .deep,
                path: "/Applications/wpsoffice.app",
                additionalPaths: ["~/Library/Containers/com.kingsoft.wpsoffice.mac/Data"],
                sizeBytes: 3 * gb + 810 * mb,
                actionType: .removeAppAndContainers,
                reason: "自 2023/07/28 以来从未打开，应用本体 (1.5 GB) 及关联容器 (2.3 GB) 共占用 3.8 GB",
                impactNote: "需确认：将移除 WPS Office 应用本体及其容器缓存（若选“移至废纸篓”可随时还原）",
                isSelected: false,
                isDemoItem: true
            )
        ]
    }

    // MARK: - Helpers

    public static func friendlyAppName(forCacheKey key: String) -> String {
        let lower = key.lowercased()
        if lower.contains("230313mzl4w4u92") || lower.contains("cursor") { return "Cursor" }
        if lower.contains("vscode") { return "VS Code" }
        if lower.contains("codex") || lower.contains("openai") { return "ChatGPT / Codex" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("trae") { return "Trae CN" }
        if lower.contains("lemon.lvpro") { return "剪映专业版" }
        if lower.contains("xinwechat") { return "微信" }
        if lower.contains("meeting") { return "腾讯会议" }
        if lower.contains("lark") { return "飞书" }
        return key.replacingOccurrences(of: ".ShipIt", with: "")
    }

    /// Calculates allocated disk size (or logical file size fallback) of a file or directory tree.
    public static func directorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        let rootURL = URL(fileURLWithPath: path)
        if !isDir.boolValue {
            return singleFileSize(at: rootURL)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        return directorySizeIncludingPackages(at: rootURL, keys: keys)
    }

    private static func directorySizeIncludingPackages(at rootURL: URL, keys: [URLResourceKey]) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += singleFileSize(at: fileURL)
        }
        return total
    }

    private static func singleFileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]) else {
            return 0
        }
        if values.isSymbolicLink == true || values.isRegularFile != true {
            return 0
        }
        let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        let logical = Int64(values.fileSize ?? 0)
        return max(allocated, logical)
    }
}
