import Foundation
import AppKit

@MainActor
public final class AppStore: ObservableObject {
    // MARK: - Published UI State

    @Published public var items: [ScanItem] = []
    @Published public var diskUsage: DiskUsageInfo = DiskUsageInfo.current()
    @Published public var isScanning: Bool = false
    @Published public var isCleaning: Bool = false
    @Published public var currentPhaseText: String = "准备就绪，点击「开始扫描」检测可安全释放的存储空间"
    @Published public var cleanProgressFraction: Double = 0.0
    @Published public var cleanMode: CleanExecutionMode = .moveToTrash
    @Published public var isDemoMode: Bool = false
    @Published public var selectedSidebarFilter: SidebarFilter = .all
    @Published public var searchText: String = ""
    @Published public var config: ScannerConfig = .default {
        didSet { saveConfig() }
    }

    // Global Task Center (Message Box) & Update Center
    @Published public var taskRecords: [TaskRecord] = []
    @Published public var isTaskDrawerOpen: Bool = false
    @Published public var isSettingsPopoverOpen: Bool = false
    @Published public var isUpdateSheetOpen: Bool = false
    @Published public var updateState: UpdateState = .idle
    @Published public var lastCleanSummaryBanner: String? = nil

    // MARK: - Sidebar Filter Enum

    public enum SidebarFilter: Hashable, Identifiable {
        case all
        case tier(CleanupTier)
        case category(CleanupCategory)

        public var id: String {
            switch self {
            case .all: return "all"
            case .tier(let t): return "tier_\(t.rawValue)"
            case .category(let c): return "cat_\(c.rawValue)"
            }
        }
    }

    // MARK: - Internal Services & Ownership Tokens

    private let scannerEngine: ScannerEngine
    private let cleanerEngine: CleanerEngine
    private let updateService = UpdateService()
    private var activeScanToken: UUID?
    private var activeScanTask: Task<Void, Never>?
    private var activeCleanToken: UUID?
    private var activeCleanTask: Task<Void, Never>?
    private var announcedUpdateVersions: Set<String> = []

    // Cross-view result cache
    private var cachedRealItems: [ScanItem]?
    private var cachedDemoItems: [ScanItem]?

    private let storageDirectoryURL: URL

    public init(
        environment: ScanEnvironment = ScanEnvironment(),
        storageDirectoryURL: URL? = nil
    ) {
        self.scannerEngine = ScannerEngine(environment: environment)
        self.cleanerEngine = CleanerEngine()

        if let customDir = storageDirectoryURL {
            self.storageDirectoryURL = customDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
            self.storageDirectoryURL = appSupport.appendingPathComponent("MacSlim", isDirectory: true)
        }

        loadConfig()
        loadTaskHistoryAndReconcileStaleTasks()
    }

    // MARK: - Computed Properties

    public var filteredItems: [ScanItem] {
        items.filter { item in
            let matchesSidebar: Bool
            switch selectedSidebarFilter {
            case .all:
                matchesSidebar = true
            case .tier(let tier):
                matchesSidebar = (item.tier == tier)
            case .category(let category):
                matchesSidebar = (item.category == category)
            }
            guard matchesSidebar else { return false }

            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(trimmed)
                || item.appName.localizedCaseInsensitiveContains(trimmed)
                || item.path.localizedCaseInsensitiveContains(trimmed)
                || item.reason.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public var selectedItems: [ScanItem] {
        items.filter(\.isSelected)
    }

    public var totalReclaimableBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    public var selectedReclaimableBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    public var unreadTaskCount: Int {
        taskRecords.filter(\.isUnread).count
    }

    // MARK: - Mode Switching & Cache Reuse

    public func setDemoMode(_ enabled: Bool) {
        guard isDemoMode != enabled else { return }
        // If a scan is running, cancel it cleanly before switching mode
        cancelScanIfNeeded()
        isDemoMode = enabled
        lastCleanSummaryBanner = nil

        if enabled {
            if let cached = cachedDemoItems {
                items = cached
                currentPhaseText = "[演示预览模式] 已载入 79.3 GB 典型膨胀案例数据（不会修改真实磁盘）"
            } else {
                let demo = ScannerEngine.demoBlockerDataset()
                cachedDemoItems = demo
                items = demo
                currentPhaseText = "[演示预览模式] 已载入 79.3 GB 典型膨胀案例数据（不会修改真实磁盘）"
            }
        } else {
            if let cached = cachedRealItems {
                items = cached
                currentPhaseText = "已恢复本机扫描结果（共发现 \(cached.count) 项，可释放 \(ByteFormatting.string(fromBytes: totalReclaimableBytes))）"
            } else {
                items = []
                currentPhaseText = "已切回本机真实扫描模式，点击「开始扫描」检测当前 Mac"
            }
        }
    }

    // MARK: - Scan Lifecycle with Ownership Token

    public func startScan(forceRefresh: Bool = true) {
        if !forceRefresh {
            if isDemoMode, let cached = cachedDemoItems {
                items = cached
                return
            }
            if !isDemoMode, let cached = cachedRealItems {
                items = cached
                return
            }
        }

        // Invalidate previous scan token
        activeScanTask?.cancel()
        let token = UUID()
        activeScanToken = token
        isScanning = true
        lastCleanSummaryBanner = nil
        diskUsage = DiskUsageInfo.current()

        let configSnapshot = self.config
        let demoSnapshot = self.isDemoMode
        let jobId = UUID().uuidString

        let record = TaskRecord(
            jobId: jobId,
            title: demoSnapshot ? "载入 79GB 演示案例扫描" : "本机存储深度扫描",
            operationType: "scan",
            status: .running,
            phaseText: "正在初始化扫描引擎...",
            isDemoMode: demoSnapshot,
            isUnread: false
        )
        upsertTaskRecord(record)

        let engine = self.scannerEngine
        activeScanTask = Task { [weak self] in
            guard let self else { return }

            if demoSnapshot {
                self.currentPhaseText = "[演示预览] 正在生成典型膨胀样本..."
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard self.activeScanToken == token, !Task.isCancelled else { return }

                let demoItems = ScannerEngine.demoBlockerDataset()
                self.cachedDemoItems = demoItems
                self.items = demoItems
                self.isScanning = false
                let totalBytes = demoItems.reduce(0) { $0 + $1.sizeBytes }
                self.currentPhaseText = "[演示预览模式] 发现 \(demoItems.count) 项，可释放 \(ByteFormatting.string(fromBytes: totalBytes))"
                self.finishTaskRecord(
                    jobId: jobId,
                    status: .succeeded,
                    phaseText: "演示数据载入完成（\(demoItems.count) 项，共 \(ByteFormatting.string(fromBytes: totalBytes))）",
                    totalItems: demoItems.count,
                    processedItems: demoItems.count,
                    bytesFreed: 0
                )
                return
            }

            let scanned = await Task.detached(priority: .userInitiated) {
                await engine.scan(config: configSnapshot) { phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeScanToken == token else { return }
                        self.currentPhaseText = phase
                        self.updateTaskPhase(jobId: jobId, phaseText: phase)
                    }
                }
            }.value

            guard self.activeScanToken == token, !Task.isCancelled else {
                self.finishTaskRecord(
                    jobId: jobId,
                    status: .canceled,
                    phaseText: "扫描已取消",
                    totalItems: 0,
                    processedItems: 0,
                    bytesFreed: 0
                )
                return
            }

            self.cachedRealItems = scanned
            self.items = scanned
            self.isScanning = false
            self.diskUsage = DiskUsageInfo.current()

            let totalBytes = scanned.reduce(0) { $0 + $1.sizeBytes }
            if scanned.isEmpty {
                self.currentPhaseText = "扫描完成：你的 Mac 非常干净，未发现超过阈值的冗余缓存或残留包！"
            } else {
                self.currentPhaseText = "扫描完成：发现 \(scanned.count) 项可清理数据，共可释放 \(ByteFormatting.string(fromBytes: totalBytes))"
            }

            self.finishTaskRecord(
                jobId: jobId,
                status: .succeeded,
                phaseText: "发现 \(scanned.count) 项，共计 \(ByteFormatting.string(fromBytes: totalBytes))",
                totalItems: scanned.count,
                processedItems: scanned.count,
                bytesFreed: 0
            )
        }
    }

    public func cancelScanIfNeeded() {
        guard isScanning else { return }
        activeScanToken = nil
        activeScanTask?.cancel()
        activeScanTask = nil
        isScanning = false
        currentPhaseText = "扫描已由用户取消"
        for idx in taskRecords.indices where taskRecords[idx].operationType == "scan" && taskRecords[idx].status == .running {
            taskRecords[idx].status = .canceled
            taskRecords[idx].phaseText = "用户手动取消扫描"
            taskRecords[idx].updatedAt = Date()
        }
        saveTaskHistory()
    }

    // MARK: - Clean Lifecycle with Ownership Token

    public func startCleanSelected() {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }

        activeCleanTask?.cancel()
        let token = UUID()
        activeCleanToken = token
        isCleaning = true
        cleanProgressFraction = 0.0
        lastCleanSummaryBanner = nil

        let modeSnapshot = self.cleanMode
        let demoSnapshot = self.isDemoMode
        let jobId = UUID().uuidString

        let record = TaskRecord(
            jobId: jobId,
            title: demoSnapshot ? "[演示预览] 模拟清理 \(targets.count) 项" : "清理 \(targets.count) 项冗余数据（\(modeSnapshot.shortTitle)）",
            operationType: "clean",
            status: .running,
            phaseText: "准备清理 \(targets.count) 项...",
            totalItemsCount: targets.count,
            processedItemsCount: 0,
            cleanMode: modeSnapshot,
            isDemoMode: demoSnapshot,
            isUnread: true
        )
        upsertTaskRecord(record)

        let engine = self.cleanerEngine
        activeCleanTask = Task { [weak self] in
            guard let self else { return }

            let results = await Task.detached(priority: .userInitiated) {
                await engine.clean(items: targets, mode: modeSnapshot) { completed, total, phase, latestResult in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeCleanToken == token else { return }
                        self.currentPhaseText = phase
                        self.cleanProgressFraction = total > 0 ? Double(completed) / Double(total) : 0
                        self.updateCleanTaskProgress(
                            jobId: jobId,
                            processed: completed,
                            total: total,
                            phaseText: phase,
                            appendResult: latestResult
                        )
                    }
                }
            }.value

            guard self.activeCleanToken == token, !Task.isCancelled else {
                self.isCleaning = false
                self.finishTaskRecord(
                    jobId: jobId,
                    status: .canceled,
                    phaseText: "清理已中断，已完成项已生效",
                    totalItems: targets.count,
                    processedItems: results.count,
                    bytesFreed: results.reduce(0) { $0 + $1.bytesFreed }
                )
                return
            }

            let succeededIDs = Set(zip(targets, results).compactMap { item, res in
                res.success ? item.id : nil
            })
            let totalFreed = results.reduce(0) { $0 + $1.bytesFreed }
            let failedCount = results.filter { !$0.success }.count

            // Remove cleaned items from current list and cache
            self.items.removeAll { succeededIDs.contains($0.id) }
            if demoSnapshot {
                self.cachedDemoItems = self.items
            } else {
                self.cachedRealItems = self.items
            }

            self.isCleaning = false
            self.cleanProgressFraction = 1.0
            self.diskUsage = DiskUsageInfo.current()

            let finalStatus: TaskStatus = failedCount == 0
                ? .succeeded
                : (succeededIDs.isEmpty ? .failed : .partiallySucceeded)

            let summaryMsg = demoSnapshot
                ? "[演示预览完成] 已模拟释放 \(ByteFormatting.string(fromBytes: totalFreed))（真实磁盘未改动）"
                : "清理完成！成功释放 \(ByteFormatting.string(fromBytes: totalFreed)) 空间\(failedCount > 0 ? "（\(failedCount) 项受限可查看消息盒子）" : "")"

            self.currentPhaseText = summaryMsg
            self.lastCleanSummaryBanner = summaryMsg

            self.finishTaskRecord(
                jobId: jobId,
                status: finalStatus,
                phaseText: summaryMsg,
                totalItems: targets.count,
                processedItems: results.count,
                bytesFreed: totalFreed,
                errorSummary: failedCount > 0 ? "\(failedCount) 个项目清理受限" : nil
            )
        }
    }

    public func cancelCleanIfNeeded() {
        guard isCleaning else { return }
        activeCleanToken = nil
        activeCleanTask?.cancel()
        activeCleanTask = nil
        isCleaning = false
        currentPhaseText = "已停止后续清理项目（已完成的项目已生效）"
    }

    // MARK: - Selection Helpers

    public func toggleSelection(for itemID: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].isSelected.toggle()
    }

    public func selectAllSafeItems() {
        for idx in items.indices {
            items[idx].isSelected = (items[idx].tier == .safe)
        }
    }

    public func setAllSelection(in tier: CleanupTier, selected: Bool) {
        for idx in items.indices where items[idx].tier == tier {
            items[idx].isSelected = selected
        }
    }

    public func revealInFinder(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parentURL = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parentURL.path) {
                NSWorkspace.shared.open(parentURL)
            }
        }
    }

    public func resetConfigToDefault() {
        config = .default
    }

    // MARK: - In-App Update Check & Safe Verification

    public func checkForUpdates(manual: Bool = true) {
        if case .checking = updateState { return }
        if case .downloading = updateState { return }
        if case .verifying = updateState { return }

        updateState = .checking
        if manual {
            isUpdateSheetOpen = true
        }

        let feedURL = config.updateManifestURL
        let channel = config.updateChannel
        let service = self.updateService

        Task { [weak self] in
            guard let self else { return }
            let result = await service.fetchAndEvaluateManifest(
                from: feedURL,
                currentVersion: AppMetadata.version,
                preferredChannel: channel
            )
            self.updateState = result

            if case .updateAvailable(let manifest) = result {
                if !self.announcedUpdateVersions.contains(manifest.version) {
                    self.announcedUpdateVersions.insert(manifest.version)
                    let record = TaskRecord(
                        title: "发现新版本 MacSlim v\(manifest.version) (\(manifest.channel))",
                        operationType: "update",
                        status: .succeeded,
                        phaseText: manifest.releaseNotes,
                        isUnread: true
                    )
                    self.upsertTaskRecord(record)
                }
            }
        }
    }

    public func downloadAndVerifyUpdate(_ manifest: ReleaseManifest, destinationDir: URL = URL(fileURLWithPath: "/tmp")) {
        let jobId = UUID().uuidString
        let record = TaskRecord(
            jobId: jobId,
            title: "下载并校验更新 MacSlim v\(manifest.version)",
            operationType: "update",
            status: .running,
            phaseText: "正在从安全源下载并校验 SHA-256...",
            isUnread: true
        )
        upsertTaskRecord(record)

        let service = self.updateService
        Task { [weak self] in
            guard let self else { return }
            let finalState = await service.downloadAndVerifyDMG(
                manifest: manifest,
                destinationDirectory: destinationDir
            ) { phaseState in
                Task { @MainActor [weak self] in
                    self?.updateState = phaseState
                }
            }
            self.updateState = finalState
            switch finalState {
            case .readyToInstall(let dmgPath, let m):
                self.finishTaskRecord(
                    jobId: jobId,
                    status: .succeeded,
                    phaseText: "v\(m.version) 校验通过（SHA-256 匹配），安装包位于 \(dmgPath)",
                    totalItems: 1,
                    processedItems: 1,
                    bytesFreed: 0
                )
            case .failed(let reason, _):
                self.finishTaskRecord(
                    jobId: jobId,
                    status: .failed,
                    phaseText: reason,
                    totalItems: 1,
                    processedItems: 0,
                    bytesFreed: 0,
                    errorSummary: reason
                )
            default:
                break
            }
        }
    }

    public func openVerifiedUpdateDMG(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func openReleasesWebPage() {
        if let url = URL(string: AppMetadata.releasesPageURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Task Center Management & Persistence

    public func markAllTasksRead() {
        for idx in taskRecords.indices {
            taskRecords[idx].isUnread = false
        }
        saveTaskHistory()
    }

    public func clearFinishedTaskHistory() {
        taskRecords.removeAll { $0.status != .running && $0.status != .queued }
        saveTaskHistory()
    }

    public func copyDiagnosticReportToClipboard() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        var sysinfo = utsname()
        uname(&sysinfo)
        let arch = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }

        let recentTasks = taskRecords.prefix(5).map { rec in
            "- [\(rec.status.label)] \(rec.title) | 释放: \(ByteFormatting.string(fromBytes: rec.totalBytesFreed)) | 摘要: \(rec.phaseText)"
        }.joined(separator: "\n")

        let report = """
        MacSlim 诊断摘要 (v\(AppMetadata.version) build \(AppMetadata.buildNumber))
        系统版本: macOS \(osVersion) (\(arch))
        磁盘状态: 可用 \(ByteFormatting.string(fromBytes: diskUsage.availableBytes)) / 总计 \(ByteFormatting.string(fromBytes: diskUsage.totalBytes))
        当前模式: \(isDemoMode ? "演示预览模式" : "真实本机模式")
        更新状态: \(updateState.badgeLabel) (通道: \(config.updateChannel))
        配置快照: 最小缓存 \(config.minCacheSizeMB)MB | 休眠天数 \(config.dormantAppDaysThreshold)天 | 休眠体积 \(config.dormantAppMinSizeMB)MB
        最近任务记录:
        \(recentTasks.isEmpty ? "(暂无记录)" : recentTasks)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        return report
    }

    private func upsertTaskRecord(_ record: TaskRecord) {
        if let idx = taskRecords.firstIndex(where: { $0.jobId == record.jobId }) {
            taskRecords[idx] = record
        } else {
            taskRecords.insert(record, at: 0)
        }
        saveTaskHistory()
    }

    private func updateTaskPhase(jobId: String, phaseText: String) {
        guard let idx = taskRecords.firstIndex(where: { $0.jobId == jobId }) else { return }
        guard taskRecords[idx].status == .running else { return }
        taskRecords[idx].phaseText = phaseText
        taskRecords[idx].updatedAt = Date()
    }

    private func updateCleanTaskProgress(
        jobId: String,
        processed: Int,
        total: Int,
        phaseText: String,
        appendResult: CleanedItemResult?
    ) {
        guard let idx = taskRecords.firstIndex(where: { $0.jobId == jobId }) else { return }
        guard taskRecords[idx].status == .running else { return }
        taskRecords[idx].processedItemsCount = processed
        taskRecords[idx].totalItemsCount = total
        taskRecords[idx].phaseText = phaseText
        taskRecords[idx].updatedAt = Date()
        if let res = appendResult {
            taskRecords[idx].itemResults.append(res)
            taskRecords[idx].totalBytesFreed += res.bytesFreed
        }
    }

    private func finishTaskRecord(
        jobId: String,
        status: TaskStatus,
        phaseText: String,
        totalItems: Int,
        processedItems: Int,
        bytesFreed: Int64,
        errorSummary: String? = nil
    ) {
        guard let idx = taskRecords.firstIndex(where: { $0.jobId == jobId }) else { return }
        taskRecords[idx].status = status
        taskRecords[idx].phaseText = phaseText
        taskRecords[idx].totalItemsCount = totalItems
        taskRecords[idx].processedItemsCount = processedItems
        taskRecords[idx].totalBytesFreed = bytesFreed
        taskRecords[idx].errorSummary = errorSummary
        taskRecords[idx].updatedAt = Date()
        saveTaskHistory()
    }

    private func loadConfig() {
        let url = storageDirectoryURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ScannerConfig.self, from: data) else {
            return
        }
        self.config = decoded
    }

    private func saveConfig() {
        try? FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        let url = storageDirectoryURL.appendingPathComponent("config.json")
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadTaskHistoryAndReconcileStaleTasks() {
        let url = storageDirectoryURL.appendingPathComponent("task_history.json")
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode([TaskRecord].self, from: data) else {
            return
        }
        // Reconcile any lingering .running tasks from a prior process session
        var modified = false
        for idx in decoded.indices where decoded[idx].status == .running || decoded[idx].status == .queued {
            decoded[idx].status = .canceled
            decoded[idx].phaseText = "上次应用会话退出，任务已中断"
            decoded[idx].updatedAt = Date()
            modified = true
        }
        self.taskRecords = decoded
        if modified {
            saveTaskHistory()
        }
    }

    private func saveTaskHistory() {
        try? FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        let url = storageDirectoryURL.appendingPathComponent("task_history.json")
        let trimmed = Array(taskRecords.prefix(30))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
