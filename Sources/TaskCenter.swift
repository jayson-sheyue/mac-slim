import Foundation
import AppKit
import SwiftUI

@MainActor
public final class AppStore: ObservableObject {
    @Published public var items: [ScanItem] = []
    @Published public var warnings: [String] = []
    @Published public var history: [OperationRecord] = []
    @Published public var recoveryEntries: [RecoveryEntry] = []
    @Published public var isScanning = false
    @Published public var isCleaning = false
    @Published public var isStopping = false
    @Published public var isRestoring = false
    @Published public var phase = "扫描更新残留、缓存和历史日志，检查后再清理。"
    @Published public var cleanMode: CleanExecutionMode = .moveToTrash
    @Published public var selectedCategory: CleanupCategory?
    @Published public var searchText = ""
    @Published public var showHistory = false
    @Published public var showSettings = false
    @Published public var showUpdate = false
    @Published public var updateState: UpdateState = .idle
    @Published public var diskUsage = DiskUsageInfo.current()
    @Published public var config = ScannerConfig.default {
        didSet {
            saveConfig()
            if oldValue != config && !isBusy { items = []; phase = "扫描设置已更改，请重新扫描。" }
        }
    }
    @Published public var lastResults: [CleanedItemResult] = []

    private let scanner: ScannerEngine
    private let cleaner: CleanerEngine?
    private let updateService: UpdateService
    private let storage: URL
    private var scanTask: Task<ScanReport, Never>?
    private var cleanTask: Task<CleanReport, Never>?
    private var updateTask: Task<Void, Never>?
    public var isBusy: Bool { isScanning || isCleaning || isRestoring }
    public var selectedItems: [ScanItem] { items.filter { $0.isSelected && !$0.inspectionOnly } }
    public var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }
    public var canClean: Bool { cleaner != nil && !isBusy && !selectedItems.isEmpty }
    public var filteredItems: [ScanItem] {
        items.filter { item in
            (selectedCategory == nil || selectedCategory == item.category) &&
            (searchText.isEmpty || [item.title, item.appName, item.path].contains { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }

    public init(environment: ScanEnvironment = ScanEnvironment(), storageDirectoryURL: URL? = nil,
                activity: @escaping @Sendable () -> ActivitySnapshot = { .current() }, testTrashDirectory: String? = nil) {
        storage = storageDirectoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSlim")
        scanner = ScannerEngine(environment: environment, activity: activity)
        updateService = UpdateService()
        do {
            let recovery = try RecoveryStore(directory: storage)
            cleaner = CleanerEngine(environment: environment, recovery: recovery, activity: activity, testTrashDirectory: testTrashDirectory)
        } catch {
            cleaner = nil
        }
        if cleaner == nil { warnings.append("无法读取或保存恢复记录，清理已停用。请检查应用数据目录的权限与 recovery-v1.json。") }
        let configURL = storage.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            do { config = try JSONDecoder().decode(ScannerConfig.self, from: Data(contentsOf: configURL)) }
            catch { warnings.append("设置读取失败，暂用默认值：\(error.localizedDescription)") }
        }
        let historyURL = storage.appendingPathComponent("operations-v1.json")
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([OperationRecord].self, from: Data(contentsOf: historyURL)) }
            catch { warnings.append("历史记录读取失败：\(error.localizedDescription)") }
        }
        Task { [weak self] in await self?.refreshRecovery() }
    }

    public func startScan() {
        guard !isBusy else { return }
        isScanning = true; isStopping = false; phase = "准备扫描…"; lastResults = []
        let config = self.config
        let scanner = self.scanner
        let receiver = self
        let worker = Task.detached(priority: .userInitiated) {
            await scanner.scan(config: config) { message in
                await receiver.setPhase(message)
            }
        }
        scanTask = worker
        Task { [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.items = report.items
            self.warnings = self.warnings.filter { $0.contains("恢复记录") } + report.warnings
            self.scanTask = nil; self.isScanning = false; self.isStopping = false
            let cleanable = report.items.filter { !$0.inspectionOnly }.count
            self.phase = report.canceled ? "扫描已停止，保留已发现的项目。" : "扫描完成：\(cleanable) 项清理候选，\(report.items.count - cleanable) 项仅供检查。"
            if !report.warnings.isEmpty { self.phase += " 有 \(report.warnings.count) 条跳过或读取提示。" }
            self.diskUsage = DiskUsageInfo.current()
            self.record("扫描", self.phase)
        }
    }

    public func stop() {
        guard isScanning || isCleaning else { return }
        isStopping = true
        phase = "正在停止，等待当前文件操作结束…"
        scanTask?.cancel(); cleanTask?.cancel()
        // Remain busy until the actual worker acknowledges completion.
    }

    public func startCleanSelected() {
        guard canClean, let cleaner else { return }
        let targets = selectedItems
        let mode = cleanMode
        isCleaning = true; isStopping = false; phase = "正在复核清理项目…"; lastResults = []
        let receiver = self
        let worker = Task.detached(priority: .userInitiated) {
            await cleaner.clean(items: targets, mode: mode) { completed, total, title in
                await receiver.setPhase("\(completed)/\(total) · \(title)")
            }
        }
        cleanTask = worker
        Task { [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.lastResults = report.results
            let finishedIDs = Set(zip(targets, report.results).compactMap { $0.1.success ? $0.0.id : nil })
            self.items.removeAll { finishedIDs.contains($0.id) }
            self.cleanTask = nil; self.isCleaning = false; self.isStopping = false
            let amount = report.results.reduce(Int64(0)) { $0 + $1.processedBytes }
            let failures = report.results.filter { !$0.success }.count
            let action = mode == .moveToTrash ? "已移至废纸篓" : "已删除"
            self.phase = "\(report.canceled ? "已停止" : "处理完成")：\(action) \(ByteFormatting.string(fromBytes: amount))，\(failures) 项未完成。"
            if mode == .moveToTrash { self.phase += " 清空废纸篓后才可能释放空间。" }
            self.record(mode.title, self.phase)
            self.diskUsage = DiskUsageInfo.current()
            await self.refreshRecovery()
        }
    }

    private func setPhase(_ message: String) { if !isStopping { phase = message } }
    public func toggle(_ id: UUID) {
        guard !isBusy, let i = items.firstIndex(where: { $0.id == id }), !items[i].inspectionOnly else { return }
        items[i].isSelected.toggle()
    }
    public func selectRecommended() {
        guard !isBusy else { return }
        for i in items.indices { items[i].isSelected = items[i].tier == .safe && !items[i].inspectionOnly }
    }
    public func clearSelection() {
        guard !isBusy else { return }
        for i in items.indices { items[i].isSelected = false }
    }
    public func refreshRecovery() async {
        if let cleaner { recoveryEntries = await cleaner.reconcileRecovery() }
    }
    public func restore(_ entry: RecoveryEntry) {
        guard !isBusy, let cleaner else { return }
        isRestoring = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let warning = try await cleaner.restore(entry)
                self.phase = warning ?? "已恢复至原位置，请重新扫描。"
                self.items = []
                self.record("恢复", warning ?? "已恢复一个废纸篓项目。")
            } catch { self.phase = "恢复失败：\(error.localizedDescription)"; self.record("恢复失败", error.localizedDescription) }
            await self.refreshRecovery()
            self.isRestoring = false
        }
    }
    public func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    public func copyDiagnostics() {
        let text = "MacSlim \(AppMetadata.version) (\(AppMetadata.buildNumber))\nmacOS \(UpdateEvaluator.detectedOSVersionString()) · \(UpdateEvaluator.detectedArchitecture())\n扫描项目 \(items.count) · 跳过/读取提示 \(warnings.count)\n运行状态：\(isBusy ? "处理中" : "空闲")\n最小体积 \(config.minCacheSizeMB) MB · 保留 \(config.minimumAgeDays) 天\n"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func record(_ title: String, _ detail: String) {
        history.insert(OperationRecord(date: Date(), title: title, detail: detail), at: 0)
        history = Array(history.prefix(30))
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: storage.appendingPathComponent("operations-v1.json"), options: .atomic)
        } catch { warnings.append("历史记录保存失败：\(error.localizedDescription)") }
    }
    private func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: storage.appendingPathComponent("config.json"), options: .atomic)
        } catch { warnings.append("设置保存失败：\(error.localizedDescription)") }
    }

    public func checkForUpdates() {
        showUpdate = true
        guard updateTask == nil else { return }
        updateState = .checking
        let service = updateService
        updateTask = Task { [weak self] in
            let result = await service.fetchAndEvaluateManifest(from: AppMetadata.defaultUpdateManifestURL)
            self?.updateState = result; self?.updateTask = nil
        }
    }
    public func downloadUpdate(_ manifest: ReleaseManifest) {
        guard updateTask == nil else { return }
        let service = updateService
        let receiver = self
        updateState = .downloading(progress: 0, targetVersion: manifest.version)
        updateTask = Task { [weak self] in
            let result = await service.downloadAndVerifyDMG(manifest: manifest) { state in
                await receiver.setUpdateState(state)
            }
            self?.updateState = result; self?.updateTask = nil
        }
    }
    private func setUpdateState(_ state: UpdateState) { updateState = state }
    public func openUpdate(_ path: String) {
        guard !isBusy else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
