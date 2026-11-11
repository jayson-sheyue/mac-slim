import Foundation

public actor RecoveryStore {
    private let url: URL
    private var entries: [RecoveryEntry]
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("recovery-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try JSONDecoder().decode([RecoveryEntry].self, from: Data(contentsOf: url))
        } else { entries = [] }
    }
    public func all() -> [RecoveryEntry] { entries.sorted { $0.createdAt > $1.createdAt } }
    public func put(_ entry: RecoveryEntry) throws {
        var next = entries.filter { $0.id != entry.id }; next.append(entry)
        let data = try JSONEncoder().encode(next)
        try data.write(to: url, options: .atomic)
        entries = next
    }
    public func remove(_ id: UUID) throws {
        let next = entries.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        entries = next
    }
}

public struct CleanerEngine: Sendable {
    public let environment: ScanEnvironment
    public let recovery: RecoveryStore
    private let activity: @Sendable () -> ActivitySnapshot
    private let testTrashDirectory: String?
    public init(environment: ScanEnvironment, recovery: RecoveryStore,
                activity: @escaping @Sendable () -> ActivitySnapshot = { .current() }, testTrashDirectory: String? = nil) {
        self.environment = environment; self.recovery = recovery; self.activity = activity; self.testTrashDirectory = testTrashDirectory
    }

    public func clean(items: [ScanItem], mode: CleanExecutionMode,
                      onProgress: @Sendable (Int, Int, String) async -> Void) async -> CleanReport {
        var report = CleanReport()
        for item in items {
            if Task.isCancelled { report.canceled = true; break }
            await onProgress(report.results.count, items.count, item.title)
            if Task.isCancelled { report.canceled = true; break }
            let result = await cleanItem(item, mode: mode)
            report.results.append(result)
            await onProgress(report.results.count, items.count, item.title)
        }
        report.canceled = report.canceled || Task.isCancelled
        return report
    }

    public func cleanItem(_ item: ScanItem, mode: CleanExecutionMode) async -> CleanedItemResult {
        let fm = FileManager.default
        do {
            try Task.checkCancellation()
            guard !item.inspectionOnly, item.category != .redundantFrameworks,
                  !item.path.components(separatedBy: "/").dropLast().contains(where: { $0.hasSuffix(".app") }) else {
                throw SafetyError.refused(L10n.tr(
                    en: "Application bundle frameworks are for inspection only and are never deleted",
                    ja: "アプリバンドル内のフレームワークは確認専用のため削除しません",
                    zh: "应用包内核仅供检查，不执行删除"
                ))
            }
            try FileSafety.validate(item.path, roots: environment.writableRoots)
            try validateRulePath(item)
            let current = try FileSafety.tree(item.path, rejectProtectedData: true)
            guard current == item.stamp else {
                throw SafetyError.refused(L10n.tr(
                    en: "Content changed after scanning; please scan again",
                    ja: "スキャン後に内容が変化しました。再スキャンしてください",
                    zh: "扫描后内容已变化，请重新扫描"
                ))
            }
            let running = activity()
            guard !running.isBusy(path: item.path, bundleIDs: item.ownerBundleIDs, appPaths: item.ownerAppPaths) else {
                throw SafetyError.refused(L10n.tr(
                    en: "Associated application or updater is running; skipped. Please quit it and scan again.",
                    ja: "関連アプリまたはアップデータが実行中のためスキップしました。終了後に再スキャンしてください。",
                    zh: "关联应用或更新器正在运行，已跳过。退出后请重新扫描。"
                ))
            }
            // References can change without changing the old browser directory itself.
            if item.path.hasPrefix(environment.library + "/Caches/ms-playwright/") {
                let unused = try ScannerEngine.unreferencedPlaywrightDirectories(at: environment.library + "/Caches/ms-playwright")
                guard unused.contains(item.path) else {
                    throw SafetyError.refused(L10n.tr(
                        en: "This browser version is now referenced by a project and was preserved",
                        ja: "このブラウザバージョンはプロジェクトから参照されているため保持しました",
                        zh: "该浏览器版本已被项目引用，已保留"
                    ))
                }
            }
            try Task.checkCancellation()
            // Repeat ancestry validation immediately before the filesystem operation.
            try FileSafety.validate(item.path, roots: environment.writableRoots)
            if mode == .moveToTrash {
                let planned = testTrashDirectory.map { $0 + "/" + UUID().uuidString + "-" + URL(fileURLWithPath: item.path).lastPathComponent }
                var entry = RecoveryEntry(id: UUID(), originalPath: item.path, trashPath: planned,
                                          stamp: current.root, tree: current, ownerBundleIDs: item.ownerBundleIDs, ownerAppPaths: item.ownerAppPaths, createdAt: Date(), state: .pending)
                // Persist recovery intent before touching the original. A failed journal blocks cleanup.
                try await recovery.put(entry)
                try Task.checkCancellation()
                do {
                    if let planned {
                        try fm.moveItem(atPath: item.path, toPath: planned)
                    } else {
                        var result: NSURL?
                        try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &result)
                        entry.trashPath = result?.path
                    }
                } catch {
                    try? await recovery.remove(entry.id)
                    throw error
                }
                entry.state = .trashed
                do { try await recovery.put(entry) }
                catch {
                    return CleanedItemResult(
                        title: item.title,
                        success: false,
                        processedBytes: current.allocatedBytes,
                        message: L10n.tr(
                            en: "Moved to Trash, but failed to update recovery journal. A pending entry was retained—check Cleanup History.",
                            ja: "ゴミ箱へ移動しましたが、復元記録の更新に失敗しました。未確定の記録を保持したため履歴を確認してください。",
                            zh: "已移至废纸篓，但恢复记录写入失败。保留了待核对记录，请到清理记录检查。"
                        )
                    )
                }
            } else {
                try fm.removeItem(atPath: item.path)
            }
            return CleanedItemResult(
                title: item.title,
                success: true,
                processedBytes: current.allocatedBytes,
                message: mode == .moveToTrash
                    ? L10n.tr(
                        en: "Moved to Trash; disk space is reclaimed after emptying Trash",
                        ja: "ゴミ箱へ移動しました（ゴミ箱を空にすると空き容量が回収されます）",
                        zh: "已移至废纸篓；清空废纸篓后才可能释放空间"
                    )
                    : L10n.tr(
                        en: "Deleted permanently; actual free space depends on APFS snapshots and other processes",
                        ja: "削除しました（実際の空き容量は APFS スナップショットや他プロセスの影響を受けます）",
                        zh: "已删除；实际可用空间受 APFS 快照和其他进程影响"
                    )
            )
        } catch is CancellationError {
            return CleanedItemResult(
                title: item.title,
                success: false,
                processedBytes: 0,
                message: L10n.tr(
                    en: "Canceled before starting this item",
                    ja: "キャンセルされたためこの項目は未実行です",
                    zh: "已取消，未开始此项"
                )
            )
        } catch {
            return CleanedItemResult(title: item.title, success: false, processedBytes: 0, message: error.localizedDescription)
        }
    }

    private func validateRulePath(_ item: ScanItem) throws {
        let components = item.path.components(separatedBy: "/").map { $0.lowercased() }
        let caches = environment.library + "/Caches"
        if FileSafety.isBelow(item.path, caches) {
            let relative = String(item.path.dropFirst(caches.count + 1)).components(separatedBy: "/")
            guard relative.count >= 2, !["macslim", "ms-playwright-go"].contains(relative[0].lowercased()),
                  !relative.contains(".links") else {
                throw SafetyError.refused(L10n.tr(
                    en: "Protected cache or runtime path",
                    ja: "保護されたキャッシュまたはランタイムパスです",
                    zh: "受保护的缓存或运行时路径"
                ))
            }
            return
        }
        if FileSafety.isBelow(item.path, environment.library + "/Logs"), ScannerEngine.isLogFile(URL(fileURLWithPath: item.path).lastPathComponent) { return }
        let markers: Set<String> = ["cache", "caches", "code cache", "gpucache", "cachestorage", "cacheddata", "cachedextensionvsixs", "updatepackages", "crx_cache", "logs", "log"]
        let parents = components.dropLast()
        if parents.contains(where: { markers.contains($0) }) { return }
        if item.path.lowercased().contains("/org.sparkle-project.sparkle/installation/") || item.path.lowercased().contains("/larkshell/update/") { return }
        throw SafetyError.refused(L10n.tr(
            en: "Target does not match a supported cache, update package, or log layout",
            ja: "対象が対応済みのキャッシュ・更新パッケージ・ログ構造と一致しません",
            zh: "目标不符合已支持的缓存、更新包或日志结构"
        ))
    }

    public func reconcileRecovery() async -> [RecoveryEntry] {
        let fm = FileManager.default
        for var entry in await recovery.all() where entry.state == .pending {
            if let s = try? FileSafety.stamp(entry.originalPath), s.inode == entry.stamp.inode, s.device == entry.stamp.device {
                try? await recovery.remove(entry.id); continue
            }
            if entry.trashPath == nil {
                let trash = environment.homeDirectory + "/.Trash"
                for name in (try? fm.contentsOfDirectory(atPath: trash)) ?? [] {
                    let path = trash + "/" + name
                    if let s = try? FileSafety.stamp(path), s.inode == entry.stamp.inode, s.device == entry.stamp.device {
                        entry.trashPath = path; break
                    }
                }
            }
            if let path = entry.trashPath, fm.fileExists(atPath: path) {
                entry.state = .trashed; try? await recovery.put(entry)
            }
        }
        return await recovery.all()
    }

    @discardableResult
    public func restore(_ entry: RecoveryEntry) async throws -> String? {
        let fm = FileManager.default
        guard entry.state == .trashed, let trash = entry.trashPath else {
            throw SafetyError.refused(L10n.tr(
                en: "No valid Trash path is available; please check in Finder",
                ja: "有効なゴミ箱パスがありません。Finder で確認してください",
                zh: "没有可用的废纸篓路径，请在访达中检查"
            ))
        }
        let trashRoots = [testTrashDirectory ?? (environment.homeDirectory + "/.Trash")]
        // System trash can reside in .Trashes/<uid> on another volume. This version only cleans home-volume data.
        try FileSafety.validate(trash, roots: trashRoots)
        let current = try FileSafety.stamp(trash)
        guard current == entry.stamp, try FileSafety.tree(trash, includeContent: entry.tree.contentFingerprint != nil) == entry.tree else {
            throw SafetyError.refused(L10n.tr(
                en: "Trashed item has changed; automatic restore was stopped",
                ja: "ゴミ箱内の項目が変更されているため、自動復元を停止しました",
                zh: "废纸篓项目已变化，已停止自动恢复"
            ))
        }
        guard !fm.fileExists(atPath: entry.originalPath) else {
            throw SafetyError.refused(L10n.tr(
                en: "A file already exists at the original path and was not overwritten. Please resolve the conflict in Finder.",
                ja: "元の場所にすでにファイルが存在するため上書きしませんでした。Finder で競合を解消してください。",
                zh: "原位置已有文件，未覆盖。请先在访达中处理冲突。"
            ))
        }
        let parent = URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent().path
        guard fm.fileExists(atPath: parent) else {
            throw SafetyError.refused(L10n.tr(
                en: "Original parent folder no longer exists; please restore manually from Trash",
                ja: "元の親フォルダが存在しないため、ゴミ箱から手動で復元してください",
                zh: "原父目录已不存在，请从废纸篓手动恢复"
            ))
        }
        try FileSafety.validate(entry.originalPath, roots: environment.writableRoots) // validates missing target's parent below
        guard !activity().isBusy(path: entry.originalPath, bundleIDs: entry.ownerBundleIDs, appPaths: entry.ownerAppPaths) else {
            throw SafetyError.refused(L10n.tr(
                en: "Associated application is running or process state is unknown; please quit it and try again",
                ja: "関連アプリが実行中かプロセス状態が不明です。終了してから再試行してください",
                zh: "关联应用正在运行或进程状态未知，请退出后重试"
            ))
        }
        try fm.moveItem(atPath: trash, toPath: entry.originalPath)
        var updated = entry; updated.state = .restored
        do { try await recovery.put(updated); return nil }
        catch {
            return L10n.tr(
                en: "File was restored to its original path, but saving the recovery journal failed. Please verify in Finder and do not restore again.",
                ja: "ファイルは元の場所に復元されましたが、復元記録の保存に失敗しました。Finder で確認し、重複復元しないでください。",
                zh: "文件已恢复至原位置，但恢复记录保存失败。请在访达中核对，勿重复恢复。"
            )
        }
    }
}
