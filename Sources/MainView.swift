import SwiftUI

public struct MainView: View {
    @ObservedObject var store: AppStore
    @State private var confirmClean = false
    @State private var showWarnings = false
    public init(store: AppStore) { self.store = store }
    private var lang: AppLanguage { store.config.language }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacSlim").font(.title2.weight(.semibold))
                    Text(L10n.tr(
                        en: "Update leftovers, caches, and historical logs",
                        ja: "更新の残骸・キャッシュ・過去のログ",
                        zh: "更新残留、缓存与历史日志",
                        language: lang
                    )).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(AppLanguage.allCases) { option in
                        Button {
                            store.language = option
                        } label: {
                            if store.language == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    Label(store.language.displayName, systemImage: "globe")
                }
                .accessibilityLabel(L10n.tr(en: "Language", ja: "表示言語", zh: "界面语言", language: lang))
                Button { store.showHistory = true } label: {
                    Label(L10n.tr(en: "History", ja: "履歴", zh: "清理记录", language: lang), systemImage: "clock")
                }
                Button { store.showSettings = true } label: {
                    Label(L10n.tr(en: "Settings", ja: "設定", zh: "设置", language: lang), systemImage: "slider.horizontal.3")
                }
                Button(store.items.isEmpty
                    ? L10n.tr(en: "Start Scan", ja: "スキャン開始", zh: "开始扫描", language: lang)
                    : L10n.tr(en: "Rescan", ja: "再スキャン", zh: "重新扫描", language: lang)
                ) { store.startScan() }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy).keyboardShortcut("r", modifiers: .command)
            }.padding(16)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    filterRow(L10n.tr(en: "All Items", ja: "すべての項目", zh: "全部项目", language: lang), icon: "tray", category: nil)
                    ForEach(CleanupCategory.allCases) { category in
                        filterRow(category.title(in: lang), icon: category.iconName, category: category)
                    }
                    Spacer()
                    Text(L10n.tr(
                        en: "Installed apps are never modified. Items with detected personal data are preserved; review unknown items first.",
                        ja: "インストール済みアプリは変更しません。個人データの特徴を含む項目は保持されます。未知の項目は先に確認してください。",
                        zh: "不修改已安装应用。含已识别个人数据的项目会保留；未知内容请先检查。",
                        language: lang
                    )).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let disk = store.diskUsage {
                        Text(L10n.tr(
                            en: "Available \(ByteFormatting.string(fromBytes: disk.availableBytes)) / \(ByteFormatting.string(fromBytes: disk.totalBytes))",
                            ja: "空き容量 \(ByteFormatting.string(fromBytes: disk.availableBytes)) / \(ByteFormatting.string(fromBytes: disk.totalBytes))",
                            zh: "磁盘可用 \(ByteFormatting.string(fromBytes: disk.availableBytes)) / \(ByteFormatting.string(fromBytes: disk.totalBytes))",
                            language: lang
                        )).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(L10n.tr(
                            en: "Disk capacity unavailable",
                            ja: "ディスク容量を取得できません",
                            zh: "磁盘容量暂不可用",
                            language: lang
                        )).font(.caption).foregroundColor(.secondary)
                    }
                }.padding(12).frame(minWidth: 185, idealWidth: 205, maxWidth: 235)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr(
                            en: "Search app or path",
                            ja: "アプリまたはパスを検索",
                            zh: "搜索应用或路径",
                            language: lang
                        ), text: $store.searchText).textFieldStyle(.roundedBorder)
                        Button(L10n.tr(
                            en: "Recommended",
                            ja: "推奨のみ",
                            zh: "选建议项",
                            language: lang
                        )) { store.selectRecommended() }.disabled(store.isBusy || !store.hasCleanableFilteredItems)
                        Button(L10n.tr(
                            en: "Select All",
                            ja: "すべて選択",
                            zh: "全选",
                            language: lang
                        )) { store.selectAllCleanable() }.disabled(store.isBusy || !store.hasCleanableFilteredItems)
                        Button(L10n.tr(
                            en: "Clear",
                            ja: "選択解除",
                            zh: "取消选择",
                            language: lang
                        )) { store.clearSelection() }.disabled(store.isBusy || store.selectedItems.isEmpty)
                    }.padding(12)
                    if store.items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 36)).foregroundColor(.accentColor)
                            Text(store.isScanning
                                ? L10n.tr(en: "Scanning…", ja: "スキャン中…", zh: "正在扫描", language: lang)
                                : L10n.tr(en: "Inspect Historical Files You Can Remove", ja: "削除可能な過去のファイルを確認", zh: "检查可以移除的历史文件", language: lang)
                            ).font(.title3.weight(.semibold))
                            Text(L10n.tr(
                                en: "Detects update packages, caches, and logs across apps by directory layout. Recently modified files are preserved; unknown caches require manual review.",
                                ja: "ディレクトリ構造に基づいて各アプリの更新パッケージ、キャッシュ、ログを識別します。最近変更されたファイルは保持され、未知のキャッシュは確認後に手動で選択します。",
                                zh: "按目录结构识别不同应用的更新包、缓存和日志。近期修改的文件会保留，未知缓存需要你检查后选择。",
                                language: lang
                            )).foregroundColor(.secondary)
                            Text(L10n.tr(
                                en: "Moves items to Trash by default. Legacy framework versions are for inspection only and are never deleted automatically.",
                                ja: "初期設定ではゴミ箱へ移動します。旧バージョンのフレームワークは確認専用で、自動削除されません。",
                                zh: "默认移至废纸篓。旧版内核仅供检查，不自动删除。",
                                language: lang
                            )).font(.callout).foregroundColor(.secondary)
                        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else if store.filteredItems.isEmpty {
                        Text(L10n.tr(
                            en: "No matching items",
                            ja: "一致する項目がありません",
                            zh: "没有匹配的项目",
                            language: lang
                        )).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        if !store.hasCleanableFilteredItems {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.shield").foregroundColor(.secondary)
                                Text(L10n.tr(
                                    en: "Items in this view are for inspection only. MacSlim never modifies or deletes files inside .app bundles so code signatures stay intact.",
                                    ja: "この表示の項目は確認専用です。コード署名を保護するため、MacSlim は .app バンドル内のファイルを変更・削除しません。",
                                    zh: "当前视图中的项目仅供检查。为保护应用代码签名完整，MacSlim 不会勾选或删除 .app 应用包内文件。",
                                    language: lang
                                )).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(store.filteredItems) { item in
                                    itemRow(item)
                                    Divider()
                                }
                            }.padding(.horizontal, 12)
                        }
                    }
                }.frame(minWidth: 450)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    if store.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.tr(en: "Processing", ja: "処理中", zh: "正在处理", language: lang))
                    }
                    Text(store.phase).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !store.warnings.isEmpty {
                        Button(L10n.tr(
                            en: "\(store.warnings.count) Notice(s)",
                            ja: "\(store.warnings.count) 件の通知",
                            zh: "\(store.warnings.count) 条提示",
                            language: lang
                        )) { showWarnings = true }
                    }
                }
                HStack {
                    Picker(L10n.tr(en: "Mode", ja: "整理方法", zh: "清理方式", language: lang), selection: $store.cleanMode) {
                        ForEach(CleanExecutionMode.allCases) { Text($0.title(in: lang)).tag($0) }
                    }.frame(width: 245).disabled(store.isBusy)
                    Spacer()
                    Text(L10n.tr(
                        en: "Selected \(store.selectedItems.count) · ~\(ByteFormatting.string(fromBytes: store.selectedBytes))",
                        ja: "選択中 \(store.selectedItems.count) 件 · 約 \(ByteFormatting.string(fromBytes: store.selectedBytes))",
                        zh: "已选 \(store.selectedItems.count) 项 · 约 \(ByteFormatting.string(fromBytes: store.selectedBytes))",
                        language: lang
                    )).font(.callout)
                    if store.isScanning || store.isCleaning {
                        Button(store.isStopping
                            ? L10n.tr(en: "Stopping…", ja: "停止中…", zh: "正在停止…", language: lang)
                            : L10n.tr(en: "Stop", ja: "停止", zh: "停止", language: lang)
                        ) { store.stop() }.disabled(store.isStopping)
                    } else {
                        Button(store.cleanMode.title(in: lang)) { confirmClean = true }
                            .buttonStyle(.borderedProminent).disabled(!store.canClean)
                    }
                }
            }.padding(14)
        }
        .frame(minWidth: 740, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .sheet(isPresented: $store.showHistory) { historyView }
        .sheet(isPresented: $store.showSettings) { settingsView }
        .sheet(isPresented: $store.showUpdate) { UpdateView(store: store) }
        .sheet(isPresented: $showWarnings) {
            VStack(alignment: .leading) {
                Text(L10n.tr(
                    en: "Skip & Read Notices",
                    ja: "スキップと読み取り通知",
                    zh: "跳过与读取提示",
                    language: lang
                )).font(.headline)
                Text(L10n.tr(
                    en: "Files are preserved when permissions are insufficient or purpose cannot be verified. Grant Full Disk Access in System Settings if you need to scan protected directories.",
                    ja: "権限不足または用途を確認できない場合、ファイルは保持されます。保護されたディレクトリをスキャンするには、システム設定でフルディスクアクセスを許可してください。",
                    zh: "权限不足或无法确认用途时会保留文件。需要扫描受保护目录时，可在系统设置中授予完全磁盘访问权限。",
                    language: lang
                )).font(.callout)
                List(store.warnings, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                Button(L10n.tr(en: "Close", ja: "閉じる", zh: "关闭", language: lang)) { showWarnings = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 600, height: 430)
        }
        .confirmationDialog(
            L10n.tr(
                en: "\(store.cleanMode.title(in: lang)) (\(store.selectedItems.count) item(s))?",
                ja: "\(store.selectedItems.count) 件の項目を「\(store.cleanMode.title(in: lang))」しますか？",
                zh: "\(store.cleanMode.title(in: lang)) \(store.selectedItems.count) 个项目？",
                language: lang
            ),
            isPresented: $confirmClean,
            titleVisibility: .visible
        ) {
            Button(store.cleanMode.title(in: lang), role: store.cleanMode == .permanentDelete ? .destructive : nil) {
                store.startCleanSelected()
            }
            Button(L10n.tr(en: "Cancel", ja: "キャンセル", zh: "取消", language: lang), role: .cancel) {}
        } message: {
            Text(store.cleanMode == .permanentDelete
                ? L10n.tr(
                    en: "Permanent deletion cannot be undone. Offline caches or developer tool resources may need to be downloaded again—please review selected items first.",
                    ja: "完全削除は取り消せません。オフラインキャッシュや開発ツール資源の再ダウンロードが必要になる場合があるため、選択項目を先に確認してください。",
                    zh: "永久删除无法撤销。离线缓存或开发工具资源可能需要重新下载，请先检查所选项目。",
                    language: lang
                )
                : L10n.tr(
                    en: "Files will be moved to Trash and can be restored from Cleanup History. Existing files at the original path are never overwritten; items cannot be restored after emptying Trash.",
                    ja: "ファイルはゴミ箱へ移動され、履歴から復元できます。元の場所に同名ファイルがある場合は上書きしません。ゴミ箱を空にした後は復元できません。",
                    zh: "文件会移至废纸篓，可在清理记录中恢复。原位置存在同名文件时不会覆盖；清空废纸篓后无法恢复。",
                    language: lang
                )
            )
        }
    }
    private func filterRow(_ title: String, icon: String, category: CleanupCategory?) -> some View {
        Button { store.selectedCategory = category } label: {
            HStack {
                Image(systemName: icon).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer()
                Text("\(store.items.filter { category == nil || $0.category == category }.count)").foregroundColor(.secondary)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(store.selectedCategory == category ? Color.accentColor.opacity(0.12) : .clear)
            .cornerRadius(6)
    }
    private func itemRow(_ item: ScanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if item.inspectionOnly {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 18)
                    .help(L10n.tr(
                        en: "Inspection only: app bundles are never modified to protect code signatures.",
                        ja: "確認専用: コード署名を保護するためアプリバンドルは変更しません。",
                        zh: "仅供检查：为保护代码签名，不修改已安装应用包。",
                        language: lang
                    ))
            } else {
                Toggle(
                    L10n.tr(
                        en: "Select \(item.title)",
                        ja: "\(item.title) を選択",
                        zh: "选择 \(item.title)",
                        language: lang
                    ),
                    isOn: Binding(get: { item.isSelected }, set: { store.setSelected(item.id, $0) })
                )
                    .labelsHidden().toggleStyle(.checkbox).disabled(store.isBusy)
            }
            VStack(alignment: .leading, spacing: 6) {
                if item.inspectionOnly {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.headline)
                        Spacer()
                        Text(item.formattedSize).monospacedDigit()
                    }
                } else {
                    Button {
                        store.toggle(item.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(.headline)
                            Spacer()
                            Text(item.formattedSize).monospacedDigit()
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)
                }
                HStack {
                    Text(item.inspectionOnly
                        ? L10n.tr(
                            en: "Inspection Only (Protected)",
                            ja: "確認専用（保護対象）",
                            zh: "仅供检查（保护签名，不可删除）",
                            language: lang
                        )
                        : item.tier.title(in: lang)
                    )
                        .foregroundColor(item.tier == .safe && !item.inspectionOnly ? .secondary : .primary)
                    Text("· \(item.appName) · \(item.category.title(in: lang))").foregroundColor(.secondary)
                    Spacer()
                    Button(L10n.tr(
                        en: "Show in Finder",
                        ja: "Finder で表示",
                        zh: "在访达中显示",
                        language: lang
                    )) { store.reveal(item.path) }.buttonStyle(.link)
                }.font(.caption)
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text(item.localizedImpact(in: lang)).font(.callout).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.tr(en: "Detection Basis", ja: "判定根拠", zh: "识别依据", language: lang)) {
                    Text(item.localizedReason(in: lang)).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(.vertical, 14)
    }
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr(en: "Settings", ja: "設定", zh: "扫描设置", language: lang)).font(.title3.weight(.semibold))
            Picker(L10n.tr(en: "Language", ja: "表示言語", zh: "界面语言", language: lang), selection: $store.config.language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }.pickerStyle(.segmented)
            Stepper(
                L10n.tr(
                    en: "Minimum item size: \(store.config.minCacheSizeMB) MB",
                    ja: "最小サイズ: \(store.config.minCacheSizeMB) MB",
                    zh: "最小项目：\(store.config.minCacheSizeMB) MB",
                    language: lang
                ),
                value: $store.config.minCacheSizeMB,
                in: 1...102400
            ).disabled(store.isBusy)
            Stepper(
                L10n.tr(
                    en: "Preserve files modified within \(store.config.minimumAgeDays) day(s)",
                    ja: "直近 \(store.config.minimumAgeDays) 日以内のファイルを保持",
                    zh: "保留近期 \(store.config.minimumAgeDays) 天的文件",
                    language: lang
                ),
                value: $store.config.minimumAgeDays,
                in: 1...3650
            ).disabled(store.isBusy)
            Text(L10n.tr(
                en: "All contents inside a cleanup candidate must be older than the retention period. Rescan is required after changing scan thresholds. Legacy framework inspection is not filtered by age.",
                ja: "整理候補内のすべての項目が保持期間より古い必要があります。スキャン条件を変更した後は再スキャンが必要です。旧フレームワークの確認は保持期間の影響を受けません。",
                zh: "清理候选中的所有内容都必须早于保留日期。修改设置后需要重新扫描。旧版内核检查不受保留日期限制。",
                language: lang
            )).font(.callout).foregroundColor(.secondary)
            Divider()
            HStack {
                Text("MacSlim \(AppMetadata.version)").foregroundColor(.secondary)
                Spacer()
                Button(L10n.tr(
                    en: "Check for Updates",
                    ja: "アップデートを確認",
                    zh: "检查更新",
                    language: lang
                )) { store.showSettings = false; store.checkForUpdates() }
            }
            HStack {
                Button(L10n.tr(
                    en: "Restore Defaults",
                    ja: "初期設定に戻す",
                    zh: "恢复默认设置",
                    language: lang
                )) { store.resetScanDefaults() }.disabled(store.isBusy)
                Spacer()
                Button(L10n.tr(en: "Done", ja: "完了", zh: "完成", language: lang)) { store.showSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr(
                    en: "Cleanup History & Recovery",
                    ja: "クリーンアップ履歴と復元",
                    zh: "清理记录与恢复",
                    language: lang
                )).font(.title3.weight(.semibold))
                Spacer()
                Button(L10n.tr(
                    en: "Copy Diagnostics",
                    ja: "診断サマリーをコピー",
                    zh: "复制诊断摘要",
                    language: lang
                )) { store.copyDiagnostics() }
                Button(L10n.tr(en: "Close", ja: "閉じる", zh: "关闭", language: lang)) { store.showHistory = false }
                    .keyboardShortcut(.cancelAction)
            }
            if store.isBusy { Label(store.phase, systemImage: "hourglass").font(.callout) }
            Text(L10n.tr(
                en: "Restoring returns items to their original paths without overwriting existing files. Manual action in Finder is required if Trash was emptied, contents changed, or the parent folder no longer exists.",
                ja: "復元は既存のファイルを上書きせずに元の場所へ戻します。ゴミ箱が空になった場合、内容が変化した場合、または親フォルダが存在しない場合は手動で対応してください。",
                zh: "恢复会放回原位置，不覆盖已有文件。废纸篓已清空、内容已变化或原父目录不存在时，需要手动处理。",
                language: lang
            )).font(.callout).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.lastResults.isEmpty {
                        Text(L10n.tr(en: "Latest Results", ja: "直近の処理結果", zh: "最近处理结果", language: lang)).font(.headline)
                        ForEach(store.lastResults) { result in
                            Label { VStack(alignment: .leading) { Text(result.title); Text(result.message).font(.caption).foregroundColor(.secondary) } }
                                icon: { Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.circle") }
                        }
                        Divider()
                    }
                    Text(L10n.tr(en: "Restorable Items", ja: "復元可能な項目", zh: "可恢复项目", language: lang)).font(.headline)
                    if store.recoveryEntries.filter({ $0.state != .restored }).isEmpty {
                        Text(L10n.tr(en: "No items", ja: "項目なし", zh: "暂无项目", language: lang)).foregroundColor(.secondary)
                    }
                    ForEach(store.recoveryEntries.filter { $0.state != .restored }) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: entry.originalPath).lastPathComponent)
                                Text(entry.originalPath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                if entry.state == .pending {
                                    Text(L10n.tr(
                                        en: "Recovery record is pending verification; please check in Trash.",
                                        ja: "復元記録の確認待ちです。ゴミ箱を確認してください。",
                                        zh: "恢复记录待核对，请在废纸篓中检查。",
                                        language: lang
                                    )).font(.caption).foregroundColor(.primary)
                                }
                            }
                            Spacer()
                            Button(L10n.tr(en: "Restore", ja: "復元", zh: "恢复", language: lang)) {
                                store.restore(entry)
                            }.disabled(store.isBusy || entry.state != .trashed)
                        }
                    }
                    Divider()
                    Text(L10n.tr(en: "Operation History", ja: "操作履歴", zh: "操作历史", language: lang)).font(.headline)
                    ForEach(store.history) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(record.title); Spacer(); Text(record.date, style: .date).foregroundColor(.secondary) }
                            Text(record.detail).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(22).frame(width: 660, height: 480)
    }
}

private struct UpdateView: View {
    @ObservedObject var store: AppStore
    private var lang: AppLanguage { store.config.language }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr(
                en: "Software Update",
                ja: "ソフトウェアアップデート",
                zh: "软件更新",
                language: lang
            )).font(.title3.weight(.semibold))
            Text(L10n.tr(
                en: "Current version \(AppMetadata.version)",
                ja: "現在のバージョン \(AppMetadata.version)",
                zh: "当前版本 \(AppMetadata.version)",
                language: lang
            )).foregroundColor(.secondary)
            switch store.updateState {
            case .idle:
                Text(L10n.tr(
                    en: "Updates have not been checked yet.",
                    ja: "まだアップデートを確認していません。",
                    zh: "尚未检查更新。",
                    language: lang
                ))
            case .checking:
                ProgressView(L10n.tr(en: "Checking…", ja: "確認中…", zh: "正在检查…", language: lang))
            case .upToDate:
                Text(L10n.tr(
                    en: "No newer version found on the current channel.",
                    ja: "現在のチャンネルに新しいバージョンはありません。",
                    zh: "当前通道未发现更新版本。",
                    language: lang
                ))
            case .updateAvailable(let manifest):
                Text(L10n.tr(
                    en: "New version available: \(manifest.version)",
                    ja: "新しいバージョンが見つかりました: \(manifest.version)",
                    zh: "发现版本 \(manifest.version)",
                    language: lang
                ))
                ScrollView { Text(manifest.releaseNotes).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                Button(L10n.tr(
                    en: "Download & Verify Installer",
                    ja: "インストーラをダウンロードして検証",
                    zh: "下载并校验安装包",
                    language: lang
                )) { store.downloadUpdate(manifest) }
            case .downloading:
                ProgressView(L10n.tr(
                    en: "Downloading installer…",
                    ja: "インストーラをダウンロード中…",
                    zh: "正在下载安装包…",
                    language: lang
                ))
            case .verifying:
                ProgressView(L10n.tr(
                    en: "Verifying installer…",
                    ja: "インストーラを検証中…",
                    zh: "正在校验安装包…",
                    language: lang
                ))
            case .readyToInstall(let path, _):
                Text(L10n.tr(
                    en: "Installer integrity verified. Open the disk image and drag MacSlim into Applications to replace.",
                    ja: "インストーラの完全性検証を通過しました。開いた後にアプリケーションフォルダへドラッグして置き換えてください。",
                    zh: "安装包完整性校验通过。打开后将应用拖入“应用程序”完成替换。",
                    language: lang
                ))
                Button(L10n.tr(
                    en: "Open Installer",
                    ja: "インストーラを開く",
                    zh: "打开安装包",
                    language: lang
                )) { store.openUpdate(path) }.disabled(store.isBusy)
                if store.isBusy {
                    Text(L10n.tr(
                        en: "Please wait for the current file operation to finish.",
                        ja: "現在のファイル操作が完了するまでお待ちください。",
                        zh: "请等待当前文件操作完成。",
                        language: lang
                    )).font(.caption)
                }
            case .failed(let reason, _):
                Text(reason).foregroundColor(.primary).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Link(
                    L10n.tr(en: "Releases Page", ja: "リリースページ", zh: "版本发布页", language: lang),
                    destination: URL(string: AppMetadata.releasesPageURL)!
                )
                Spacer()
                Button(L10n.tr(en: "Check Again", ja: "再確認", zh: "重新检查", language: lang)) {
                    store.checkForUpdates()
                }
                Button(L10n.tr(en: "Close", ja: "閉じる", zh: "关闭", language: lang)) {
                    store.showUpdate = false
                }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 500, height: 340)
    }
}
