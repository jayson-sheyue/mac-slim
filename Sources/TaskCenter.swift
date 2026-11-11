import Foundation
import AppKit
import SwiftUI

@MainActor
public final class AppStore: ObservableObject {
    private enum PhaseState {
        case initial
        case settingsChanged
        case preparingScan
        case custom(String)
        case scanFinished(cleanable: Int, inspectOnly: Int, warnings: Int, canceled: Bool)
        case stopping
        case verifyingClean
        case cleaningProgress(completed: Int, total: Int, title: String)
        case cleanFinished(mode: CleanExecutionMode, bytes: Int64, failures: Int, canceled: Bool)
        case restored(warning: String?)
        case restoreFailed(String)

        func localized(in lang: AppLanguage) -> String {
            switch self {
            case .initial:
                return L10n.tr(
                    en: "Scan update leftovers, caches, and historical logs—review before cleaning.",
                    ja: "アップデートの残骸、キャッシュ、過去のログをスキャンし、確認してから整理します。",
                    zh: "扫描更新残留、缓存和历史日志，检查后再清理。",
                    language: lang
                )
            case .settingsChanged:
                return L10n.tr(
                    en: "Scan settings changed. Please scan again.",
                    ja: "スキャン設定が変更されました。再スキャンしてください。",
                    zh: "扫描设置已更改，请重新扫描。",
                    language: lang
                )
            case .preparingScan:
                return L10n.tr(
                    en: "Preparing scan…",
                    ja: "スキャンを準備中…",
                    zh: "准备扫描…",
                    language: lang
                )
            case .custom(let message):
                return message
            case .scanFinished(let cleanable, let inspectOnly, let warnings, let canceled):
                var text = canceled
                    ? L10n.tr(
                        en: "Scan stopped. Discovered items were kept.",
                        ja: "スキャンを停止しました。検出済みの項目を保持しています。",
                        zh: "扫描已停止，保留已发现的项目。",
                        language: lang
                    )
                    : L10n.tr(
                        en: "Scan complete: \(cleanable) cleanup candidate(s), \(inspectOnly) for inspection only.",
                        ja: "スキャン完了: 整理候補 \(cleanable) 件、確認専用 \(inspectOnly) 件。",
                        zh: "扫描完成：\(cleanable) 项清理候选，\(inspectOnly) 项仅供检查。",
                        language: lang
                    )
                if warnings > 0 {
                    text += L10n.tr(
                        en: " \(warnings) skip or read notice(s).",
                        ja: " スキップまたは読み取り通知が \(warnings) 件あります。",
                        zh: " 有 \(warnings) 条跳过或读取提示。",
                        language: lang
                    )
                }
                return text
            case .stopping:
                return L10n.tr(
                    en: "Stopping… waiting for the current file operation to finish.",
                    ja: "停止中… 現在のファイル操作が完了するのを待っています。",
                    zh: "正在停止，等待当前文件操作结束…",
                    language: lang
                )
            case .verifyingClean:
                return L10n.tr(
                    en: "Re-verifying selected items before cleanup…",
                    ja: "整理対象の項目を再確認中…",
                    zh: "正在复核清理项目…",
                    language: lang
                )
            case .cleaningProgress(let completed, let total, let title):
                return "\(completed)/\(total) · \(title)"
            case .cleanFinished(let mode, let bytes, let failures, let canceled):
                let status = canceled
                    ? L10n.tr(en: "Stopped", ja: "停止しました", zh: "已停止", language: lang)
                    : L10n.tr(en: "Completed", ja: "処理完了", zh: "处理完成", language: lang)
                let action = mode == .moveToTrash
                    ? L10n.tr(en: "Moved to Trash", ja: "ゴミ箱へ移動", zh: "已移至废纸篓", language: lang)
                    : L10n.tr(en: "Deleted", ja: "削除済み", zh: "已删除", language: lang)
                let formatted = ByteFormatting.string(fromBytes: bytes)
                var text = L10n.tr(
                    en: "\(status): \(action) \(formatted), \(failures) item(s) incomplete.",
                    ja: "\(status)：\(action) \(formatted)、未完了 \(failures) 件。",
                    zh: "\(status)：\(action) \(formatted)，\(failures) 项未完成。",
                    language: lang
                )
                if mode == .moveToTrash {
                    text += L10n.tr(
                        en: " Disk space is freed after emptying Trash.",
                        ja: " ゴミ箱を空にすると空き容量が回収されます。",
                        zh: " 清空废纸篓后才可能释放空间。",
                        language: lang
                    )
                }
                return text
            case .restored(let warning):
                return warning ?? L10n.tr(
                    en: "Restored to original path. Please scan again.",
                    ja: "元の場所に復元しました。再スキャンしてください。",
                    zh: "已恢复至原位置，请重新扫描。",
                    language: lang
                )
            case .restoreFailed(let reason):
                return L10n.tr(
                    en: "Restore failed: \(reason)",
                    ja: "復元に失敗しました: \(reason)",
                    zh: "恢复失败：\(reason)",
                    language: lang
                )
            }
        }
    }

    @Published public var items: [ScanItem] = []
    @Published public var warnings: [String] = []
    @Published public var history: [OperationRecord] = []
    @Published public var recoveryEntries: [RecoveryEntry] = []
    @Published public var isScanning = false
    @Published public var isCleaning = false
    @Published public var isStopping = false
    @Published public var isRestoring = false
    @Published public var phase = ""
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
            L10n.current = config.language
            saveConfig()
            let criteriaChanged = oldValue.minCacheSizeMB != config.minCacheSizeMB || oldValue.minimumAgeDays != config.minimumAgeDays
            if criteriaChanged && !isBusy {
                items = []
                phaseState = .settingsChanged
                phase = phaseState.localized(in: config.language)
            } else if oldValue.language != config.language {
                applyLanguageChange()
            }
        }
    }
    @Published public var lastResults: [CleanedItemResult] = []

    public var language: AppLanguage {
        get { config.language }
        set { config.language = newValue }
    }

    private var phaseState: PhaseState = .initial
    private let hasCleanerError: Bool
    private var scanWarnings: [String] = []
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
    public var hasCleanableFilteredItems: Bool { filteredItems.contains { !$0.inspectionOnly } }

    public init(environment: ScanEnvironment = ScanEnvironment(), storageDirectoryURL: URL? = nil,
                activity: @escaping @Sendable () -> ActivitySnapshot = { .current() }, testTrashDirectory: String? = nil) {
        storage = storageDirectoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSlim")
        scanner = ScannerEngine(environment: environment, activity: activity)
        updateService = UpdateService()

        let configURL = storage.appendingPathComponent("config.json")
        var loadedConfig = ScannerConfig.default
        var configError: String?
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                loadedConfig = try JSONDecoder().decode(ScannerConfig.self, from: Data(contentsOf: configURL))
            } catch {
                configError = error.localizedDescription
            }
        }
        L10n.current = loadedConfig.language

        do {
            let recovery = try RecoveryStore(directory: storage)
            cleaner = CleanerEngine(environment: environment, recovery: recovery, activity: activity, testTrashDirectory: testTrashDirectory)
            hasCleanerError = false
        } catch {
            cleaner = nil
            hasCleanerError = true
        }
        config = loadedConfig
        phase = phaseState.localized(in: loadedConfig.language)
        if hasCleanerError {
            warnings.append(Self.cleanerUnavailableWarning(in: config.language))
        }
        if let configError {
            warnings.append(L10n.tr(
                en: "Failed to read settings; using defaults: \(configError)",
                ja: "設定の読み取りに失敗したため初期値を使用します: \(configError)",
                zh: "设置读取失败，暂用默认值：\(configError)",
                language: config.language
            ))
        }
        let historyURL = storage.appendingPathComponent("operations-v1.json")
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([OperationRecord].self, from: Data(contentsOf: historyURL)) }
            catch {
                warnings.append(L10n.tr(
                    en: "Failed to read operation history: \(error.localizedDescription)",
                    ja: "操作履歴の読み取りに失敗しました: \(error.localizedDescription)",
                    zh: "历史记录读取失败：\(error.localizedDescription)",
                    language: config.language
                ))
            }
        }
        Task { [weak self] in await self?.refreshRecovery() }
    }

    private static func cleanerUnavailableWarning(in lang: AppLanguage) -> String {
        L10n.tr(
            en: "Could not read or save recovery records; cleanup is disabled. Please check permissions for the Application Support folder and recovery-v1.json.",
            ja: "復元記録を読み書きできないため、クリーンアップを無効化しました。アプリデータフォルダの権限と recovery-v1.json を確認してください。",
            zh: "无法读取或保存恢复记录，清理已停用。请检查应用数据目录的权限与 recovery-v1.json。",
            language: lang
        )
    }

    private func applyLanguageChange() {
        let lang = config.language
        L10n.current = lang
        phase = phaseState.localized(in: lang)
        for index in items.indices {
            if let rule = items[index].ruleKey {
                items[index].reason = rule.reason(in: lang)
                items[index].impactNote = rule.impact(in: lang)
            }
        }
        if hasCleanerError {
            warnings = [Self.cleanerUnavailableWarning(in: lang)] + scanWarnings
        }
    }

    public func resetScanDefaults() {
        guard !isBusy else { return }
        config = ScannerConfig(minCacheSizeMB: 5, minimumAgeDays: 14, language: config.language)
    }

    public func startScan() {
        guard !isBusy else { return }
        isScanning = true; isStopping = false
        phaseState = .preparingScan
        phase = phaseState.localized(in: config.language)
        lastResults = []
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
            let lang = self.config.language
            var localizedItems = report.items
            for i in localizedItems.indices {
                if let rule = localizedItems[i].ruleKey {
                    localizedItems[i].reason = rule.reason(in: lang)
                    localizedItems[i].impactNote = rule.impact(in: lang)
                }
            }
            self.items = localizedItems
            self.scanWarnings = report.warnings
            self.warnings = (self.hasCleanerError ? [Self.cleanerUnavailableWarning(in: lang)] : []) + report.warnings
            self.scanTask = nil; self.isScanning = false; self.isStopping = false
            let cleanable = report.items.filter { !$0.inspectionOnly }.count
            self.phaseState = .scanFinished(
                cleanable: cleanable,
                inspectOnly: report.items.count - cleanable,
                warnings: report.warnings.count,
                canceled: report.canceled
            )
            self.phase = self.phaseState.localized(in: lang)
            self.diskUsage = DiskUsageInfo.current()
            self.record(
                L10n.tr(en: "Scan", ja: "スキャン", zh: "扫描", language: lang),
                self.phase
            )
        }
    }

    public func stop() {
        guard isScanning || isCleaning else { return }
        isStopping = true
        phaseState = .stopping
        phase = phaseState.localized(in: config.language)
        scanTask?.cancel(); cleanTask?.cancel()
        // Remain busy until the actual worker acknowledges completion.
    }

    public func startCleanSelected() {
        guard canClean, let cleaner else { return }
        let targets = selectedItems
        let mode = cleanMode
        isCleaning = true; isStopping = false
        phaseState = .verifyingClean
        phase = phaseState.localized(in: config.language)
        lastResults = []
        let receiver = self
        let worker = Task.detached(priority: .userInitiated) {
            await cleaner.clean(items: targets, mode: mode) { completed, total, title in
                await receiver.setCleaningProgress(completed: completed, total: total, title: title)
            }
        }
        cleanTask = worker
        Task { [weak self] in
            let report = await worker.value
            guard let self else { return }
            let lang = self.config.language
            self.lastResults = report.results
            let finishedIDs = Set(zip(targets, report.results).compactMap { $0.1.success ? $0.0.id : nil })
            self.items.removeAll { finishedIDs.contains($0.id) }
            self.cleanTask = nil; self.isCleaning = false; self.isStopping = false
            let amount = report.results.reduce(Int64(0)) { $0 + $1.processedBytes }
            let failures = report.results.filter { !$0.success }.count
            self.phaseState = .cleanFinished(mode: mode, bytes: amount, failures: failures, canceled: report.canceled)
            self.phase = self.phaseState.localized(in: lang)
            self.record(mode.title(in: lang), self.phase)
            self.diskUsage = DiskUsageInfo.current()
            await self.refreshRecovery()
        }
    }

    private func setPhase(_ message: String) {
        if !isStopping {
            phaseState = .custom(message)
            phase = message
        }
    }

    private func setCleaningProgress(completed: Int, total: Int, title: String) {
        if !isStopping {
            phaseState = .cleaningProgress(completed: completed, total: total, title: title)
            phase = phaseState.localized(in: config.language)
        }
    }

    public func toggle(_ id: UUID) {
        guard !isBusy, let i = items.firstIndex(where: { $0.id == id }), !items[i].inspectionOnly else { return }
        items[i].isSelected.toggle()
    }
    public func setSelected(_ id: UUID, _ selected: Bool) {
        guard !isBusy, let i = items.firstIndex(where: { $0.id == id }), !items[i].inspectionOnly else { return }
        if items[i].isSelected != selected {
            items[i].isSelected = selected
        }
    }
    public func selectRecommended() {
        guard !isBusy else { return }
        for i in items.indices { items[i].isSelected = items[i].tier == .safe && !items[i].inspectionOnly }
    }
    public func selectAllCleanable() {
        guard !isBusy else { return }
        let visibleIDs = Set(filteredItems.filter { !$0.inspectionOnly }.map(\.id))
        for i in items.indices where visibleIDs.contains(items[i].id) {
            items[i].isSelected = true
        }
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
            let lang = self.config.language
            do {
                let warning = try await cleaner.restore(entry)
                self.phaseState = .restored(warning: warning)
                self.phase = self.phaseState.localized(in: lang)
                self.items = []
                self.record(
                    L10n.tr(en: "Restore", ja: "復元", zh: "恢复", language: lang),
                    warning ?? L10n.tr(
                        en: "Restored one item from Trash.",
                        ja: "ゴミ箱の項目を 1 件復元しました。",
                        zh: "已恢复一个废纸篓项目。",
                        language: lang
                    )
                )
            } catch {
                self.phaseState = .restoreFailed(error.localizedDescription)
                self.phase = self.phaseState.localized(in: lang)
                self.record(
                    L10n.tr(en: "Restore Failed", ja: "復元失敗", zh: "恢复失败", language: lang),
                    error.localizedDescription
                )
            }
            await self.refreshRecovery()
            self.isRestoring = false
        }
    }
    public func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    public func copyDiagnostics() {
        let lang = config.language
        let stateLabel = isBusy
            ? L10n.tr(en: "Busy", ja: "処理中", zh: "处理中", language: lang)
            : L10n.tr(en: "Idle", ja: "待機中", zh: "空闲", language: lang)
        let text = L10n.tr(
            en: "MacSlim \(AppMetadata.version) (\(AppMetadata.buildNumber))\nmacOS \(UpdateEvaluator.detectedOSVersionString()) · \(UpdateEvaluator.detectedArchitecture())\nScanned items: \(items.count) · Skip/read notices: \(warnings.count)\nStatus: \(stateLabel)\nMin size: \(config.minCacheSizeMB) MB · Retention: \(config.minimumAgeDays) days · Language: \(lang.displayName)\n",
            ja: "MacSlim \(AppMetadata.version) (\(AppMetadata.buildNumber))\nmacOS \(UpdateEvaluator.detectedOSVersionString()) · \(UpdateEvaluator.detectedArchitecture())\nスキャン項目 \(items.count) · スキップ/読み取り通知 \(warnings.count)\n実行状態: \(stateLabel)\n最小サイズ \(config.minCacheSizeMB) MB · 保持 \(config.minimumAgeDays) 日 · 言語: \(lang.displayName)\n",
            zh: "MacSlim \(AppMetadata.version) (\(AppMetadata.buildNumber))\nmacOS \(UpdateEvaluator.detectedOSVersionString()) · \(UpdateEvaluator.detectedArchitecture())\n扫描项目 \(items.count) · 跳过/读取提示 \(warnings.count)\n运行状态：\(stateLabel)\n最小体积 \(config.minCacheSizeMB) MB · 保留 \(config.minimumAgeDays) 天 · 语言：\(lang.displayName)\n",
            language: lang
        )
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func record(_ title: String, _ detail: String) {
        history.insert(OperationRecord(date: Date(), title: title, detail: detail), at: 0)
        history = Array(history.prefix(30))
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: storage.appendingPathComponent("operations-v1.json"), options: .atomic)
        } catch {
            warnings.append(L10n.tr(
                en: "Failed to save operation history: \(error.localizedDescription)",
                ja: "操作履歴の保存に失敗しました: \(error.localizedDescription)",
                zh: "历史记录保存失败：\(error.localizedDescription)",
                language: config.language
            ))
        }
    }
    private func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: storage.appendingPathComponent("config.json"), options: .atomic)
        } catch {
            warnings.append(L10n.tr(
                en: "Failed to save settings: \(error.localizedDescription)",
                ja: "設定の保存に失敗しました: \(error.localizedDescription)",
                zh: "设置保存失败：\(error.localizedDescription)",
                language: config.language
            ))
        }
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
