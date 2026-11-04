import SwiftUI

public struct MainView: View {
    @ObservedObject var store: AppStore
    @State private var confirmClean = false
    @State private var showWarnings = false
    public init(store: AppStore) { self.store = store }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacSlim").font(.title2.weight(.semibold))
                    Text("更新残留、缓存与历史日志").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Button { store.showHistory = true } label: { Label("清理记录", systemImage: "clock") }
                Button { store.showSettings = true } label: { Label("设置", systemImage: "slider.horizontal.3") }
                Button(store.items.isEmpty ? "开始扫描" : "重新扫描") { store.startScan() }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy).keyboardShortcut("r", modifiers: .command)
            }.padding(16)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    filterRow("全部项目", icon: "tray", category: nil)
                    ForEach(CleanupCategory.allCases) { category in
                        filterRow(category.title, icon: category.iconName, category: category)
                    }
                    Spacer()
                    Text("不修改已安装应用。含已识别个人数据的项目会保留；未知内容请先检查。").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let disk = store.diskUsage {
                        Text("磁盘可用 \(ByteFormatting.string(fromBytes: disk.availableBytes)) / \(ByteFormatting.string(fromBytes: disk.totalBytes))").font(.caption).foregroundColor(.secondary)
                    } else { Text("磁盘容量暂不可用").font(.caption).foregroundColor(.secondary) }
                }.padding(12).frame(minWidth: 165, idealWidth: 180, maxWidth: 210)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        TextField("搜索应用或路径", text: $store.searchText).textFieldStyle(.roundedBorder)
                        Button("选择建议项") { store.selectRecommended() }.disabled(store.isBusy)
                        Button("取消选择") { store.clearSelection() }.disabled(store.isBusy)
                    }.padding(12)
                    if store.items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 36)).foregroundColor(.accentColor)
                            Text(store.isScanning ? "正在扫描" : "检查可以移除的历史文件").font(.title3.weight(.semibold))
                            Text("按目录结构识别不同应用的更新包、缓存和日志。近期修改的文件会保留，未知缓存需要你检查后选择。").foregroundColor(.secondary)
                            Text("默认移至废纸篓。旧版内核仅供检查，不自动删除。").font(.callout).foregroundColor(.secondary)
                        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else if store.filteredItems.isEmpty {
                        Text("没有匹配的项目").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
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
                    if store.isBusy { ProgressView().controlSize(.small).accessibilityLabel("正在处理") }
                    Text(store.phase).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !store.warnings.isEmpty {
                        Button("\(store.warnings.count) 条提示") { showWarnings = true }
                    }
                }
                HStack {
                    Picker("清理方式", selection: $store.cleanMode) {
                        ForEach(CleanExecutionMode.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 230).disabled(store.isBusy)
                    Spacer()
                    Text("已选 \(store.selectedItems.count) 项 · 约 \(ByteFormatting.string(fromBytes: store.selectedBytes))").font(.callout)
                    if store.isScanning || store.isCleaning {
                        Button(store.isStopping ? "正在停止…" : "停止") { store.stop() }.disabled(store.isStopping)
                    } else {
                        Button(store.cleanMode.title) { confirmClean = true }
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
                Text("跳过与读取提示").font(.headline)
                Text("权限不足或无法确认用途时会保留文件。需要扫描受保护目录时，可在系统设置中授予完全磁盘访问权限。").font(.callout)
                List(store.warnings, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                Button("关闭") { showWarnings = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 600, height: 430)
        }
        .confirmationDialog("\(store.cleanMode.title) \(store.selectedItems.count) 个项目？", isPresented: $confirmClean, titleVisibility: .visible) {
            Button(store.cleanMode.title, role: store.cleanMode == .permanentDelete ? .destructive : nil) { store.startCleanSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(store.cleanMode == .permanentDelete ? "永久删除无法撤销。离线缓存或开发工具资源可能需要重新下载，请先检查所选项目。" : "文件会移至废纸篓，可在清理记录中恢复。原位置存在同名文件时不会覆盖；清空废纸篓后无法恢复。")
        }
    }
    private func filterRow(_ title: String, icon: String, category: CleanupCategory?) -> some View {
        Button { store.selectedCategory = category } label: {
            HStack {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer()
                Text("\(store.items.filter { category == nil || $0.category == category }.count)").foregroundColor(.secondary)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(store.selectedCategory == category ? Color.accentColor.opacity(0.12) : .clear)
            .cornerRadius(6)
    }
    private func itemRow(_ item: ScanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("选择 \(item.title)", isOn: Binding(get: { item.isSelected }, set: { _ in store.toggle(item.id) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(store.isBusy || item.inspectionOnly)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(item.formattedSize).monospacedDigit()
                }
                HStack {
                    Text(item.inspectionOnly ? "仅供检查" : item.tier.title)
                        .foregroundColor(item.tier == .safe && !item.inspectionOnly ? .secondary : .primary)
                    Text("· \(item.appName) · \(item.category.title)").foregroundColor(.secondary)
                    Spacer()
                    Button("在访达中显示") { store.reveal(item.path) }.buttonStyle(.link)
                }.font(.caption)
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Text(item.impactNote).font(.callout).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("识别依据") { Text(item.reason).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.padding(.vertical, 14)
    }
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("扫描设置").font(.title3.weight(.semibold))
            Stepper("最小项目：\(store.config.minCacheSizeMB) MB", value: $store.config.minCacheSizeMB, in: 1...102400).disabled(store.isBusy)
            Stepper("保留近期 \(store.config.minimumAgeDays) 天的文件", value: $store.config.minimumAgeDays, in: 1...3650).disabled(store.isBusy)
            Text("清理候选中的所有内容都必须早于保留日期。修改设置后需要重新扫描。旧版内核检查不受保留日期限制。").font(.callout).foregroundColor(.secondary)
            Divider()
            HStack {
                Text("MacSlim \(AppMetadata.version)").foregroundColor(.secondary)
                Spacer()
                Button("检查更新") { store.showSettings = false; store.checkForUpdates() }
            }
            HStack {
                Button("恢复默认设置") { store.config = .default }.disabled(store.isBusy)
                Spacer()
                Button("完成") { store.showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 450)
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理记录与恢复").font(.title3.weight(.semibold))
                Spacer()
                Button("复制诊断摘要") { store.copyDiagnostics() }
                Button("关闭") { store.showHistory = false }.keyboardShortcut(.cancelAction)
            }
            if store.isBusy { Label(store.phase, systemImage: "hourglass").font(.callout) }
            Text("恢复会放回原位置，不覆盖已有文件。废纸篓已清空、内容已变化或原父目录不存在时，需要手动处理。").font(.callout).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.lastResults.isEmpty {
                        Text("最近处理结果").font(.headline)
                        ForEach(store.lastResults) { result in
                            Label { VStack(alignment: .leading) { Text(result.title); Text(result.message).font(.caption).foregroundColor(.secondary) } }
                                icon: { Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.circle") }
                        }
                        Divider()
                    }
                    Text("可恢复项目").font(.headline)
                    if store.recoveryEntries.filter({ $0.state != .restored }).isEmpty { Text("暂无项目").foregroundColor(.secondary) }
                    ForEach(store.recoveryEntries.filter { $0.state != .restored }) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: entry.originalPath).lastPathComponent)
                                Text(entry.originalPath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                if entry.state == .pending { Text("恢复记录待核对，请在废纸篓中检查。").font(.caption).foregroundColor(.primary) }
                            }
                            Spacer()
                            Button("恢复") { store.restore(entry) }.disabled(store.isBusy || entry.state != .trashed)
                        }
                    }
                    Divider()
                    Text("操作历史").font(.headline)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("软件更新").font(.title3.weight(.semibold))
            Text("当前版本 \(AppMetadata.version)").foregroundColor(.secondary)
            switch store.updateState {
            case .idle: Text("尚未检查更新。")
            case .checking: ProgressView("正在检查…")
            case .upToDate: Text("当前通道未发现更新版本。")
            case .updateAvailable(let manifest):
                Text("发现版本 \(manifest.version)")
                ScrollView { Text(manifest.releaseNotes).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                Button("下载并校验安装包") { store.downloadUpdate(manifest) }
            case .downloading: ProgressView("正在下载安装包…")
            case .verifying: ProgressView("正在校验安装包…")
            case .readyToInstall(let path, _):
                Text("安装包完整性校验通过。打开后将应用拖入“应用程序”完成替换。")
                Button("打开安装包") { store.openUpdate(path) }.disabled(store.isBusy)
                if store.isBusy { Text("请等待当前文件操作完成。").font(.caption) }
            case .failed(let reason, _): Text(reason).foregroundColor(.primary).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Link("版本发布页", destination: URL(string: AppMetadata.releasesPageURL)!)
                Spacer()
                Button("重新检查") { store.checkForUpdates() }
                Button("关闭") { store.showUpdate = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 500, height: 340)
    }
}
