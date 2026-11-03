import SwiftUI
import AppKit

public struct MainView: View {
    @ObservedObject var store: AppStore
    @State private var showDeepPermanentConfirmAlert: Bool = false
    @State private var copiedDiagnosticToast: Bool = false

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if store.isDemoMode {
                demoModeBanner
                Divider()
            }

            if let summaryBanner = store.lastCleanSummaryBanner {
                cleanSummaryBanner(text: summaryBanner)
                Divider()
            }

            HSplitView {
                sidebarView
                    .frame(minWidth: 220, idealWidth: 236, maxWidth: 260)

                contentAreaView
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            bottomActionBar
        }
        .frame(minWidth: 900, idealWidth: 1020, minHeight: 620, idealHeight: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $store.isTaskDrawerOpen) {
            TaskCenterSheetView(store: store, copiedDiagnosticToast: $copiedDiagnosticToast)
        }
        .sheet(isPresented: $store.isUpdateSheetOpen) {
            UpdateCenterSheetView(store: store)
        }
        .alert("确认执行永久深度清理？", isPresented: $showDeepPermanentConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("改为移至废纸篓并执行") {
                store.cleanMode = .moveToTrash
                store.startCleanSelected()
            }
            Button("确认永久清理", role: .destructive) {
                store.startCleanSelected()
            }
        } message: {
            Text("当前勾选了「深度瘦身项」且选择了「直接永久清理」。建议优先使用「移至废纸篓」模式以便随时恢复。是否确认继续？")
        }
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            // Brand Identity
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MacSlim")
                            .font(.system(size: 16, weight: .bold))
                        Text("v\(AppMetadata.version)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        Text("Mac 瘦身助手")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Text(store.currentPhaseText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            // Disk Usage Meter
            diskUsageWidget

            // Real vs Demo Mode Switch
            Picker("", selection: Binding(
                get: { store.isDemoMode },
                set: { store.setDemoMode($0) }
            )) {
                Text("真实本机扫描").tag(false)
                Text("79GB 案例预览").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .help("切换真实本机扫描或查看 79.3 GB 典型膨胀案例演示")

            // Scan / Stop Action
            if store.isScanning {
                Button(action: { store.cancelScanIfNeeded() }) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("停止扫描")
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button(action: { store.startScan(forceRefresh: true) }) {
                    Label(store.items.isEmpty ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isCleaning)
            }

            // Settings Popover Button
            Button(action: { store.isSettingsPopoverOpen.toggle() }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("扫描阈值与更新源设置")
            .popover(isPresented: $store.isSettingsPopoverOpen, arrowEdge: .bottom) {
                SettingsPopoverView(store: store)
            }

            // Update Check Button
            Button(action: {
                if case .idle = store.updateState {
                    store.checkForUpdates(manual: true)
                } else {
                    store.isUpdateSheetOpen = true
                }
            }) {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                        Text(store.updateState.badgeLabel)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 4)

                    if store.updateState.hasUpdateOrAction {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(.bordered)
            .help("检查版本更新与查看 Release 完整性状态")

            // Global Task Center (Message Box) Button
            Button(action: {
                store.isTaskDrawerOpen = true
                store.markAllTasksRead()
            }) {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 13))
                        Text("消息盒子")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 4)

                    if store.unreadTaskCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(.bordered)
            .help("查看清理任务进度、历史记录与导出诊断摘要")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var diskUsageWidget: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Text("本机磁盘")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("可用 \(ByteFormatting.string(fromBytes: store.diskUsage.availableBytes)) / 共 \(ByteFormatting.string(fromBytes: store.diskUsage.totalBytes))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(store.diskUsage.usedPercentage > 0.85 ? Color.orange : Color.blue)
                        .frame(width: max(6, geo.size.width * CGFloat(min(1.0, store.diskUsage.usedPercentage))))
                }
            }
            .frame(width: 170, height: 6)
        }
    }

    // MARK: - Banners

    private var demoModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .foregroundColor(.orange)
            Text("当前处于「79.3 GB 典型膨胀案例演示预览」模式：展示 Chrome 旧内核、Electron 更新残留、Cursor 13.8GB 状态库等真实膨胀样本。在此模式下点击清理仅做模拟演示，不会改动你的本机磁盘。")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Button("切回真实本机扫描") {
                store.setDemoMode(false)
                if store.items.isEmpty {
                    store.startScan(forceRefresh: true)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private func cleanSummaryBanner(text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("查看明细") {
                store.isTaskDrawerOpen = true
                store.markAllTasksRead()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: { store.lastCleanSummaryBanner = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
    }

    // MARK: - Left Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Overview Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("概览")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)

                        sidebarRow(
                            title: "全部可清理项",
                            icon: "square.grid.2x2.fill",
                            tint: .blue,
                            count: store.items.count,
                            bytes: store.totalReclaimableBytes,
                            isSelected: store.selectedSidebarFilter == .all
                        ) {
                            store.selectedSidebarFilter = .all
                        }
                    }

                    // Safety Tier Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("安全分级模式")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)

                        ForEach(CleanupTier.allCases) { tier in
                            let tierItems = store.items.filter { $0.tier == tier }
                            let tierBytes = tierItems.reduce(0) { $0 + $1.sizeBytes }
                            sidebarRow(
                                title: tier == .safe ? "完全无感项" : "深度瘦身项",
                                icon: tier == .safe ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                tint: tier == .safe ? .green : .orange,
                                count: tierItems.count,
                                bytes: tierBytes,
                                isSelected: store.selectedSidebarFilter == .tier(tier)
                            ) {
                                store.selectedSidebarFilter = .tier(tier)
                            }
                        }
                    }

                    // Category Breakdown Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("膨胀成因分类")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)

                        ForEach(CleanupCategory.allCases) { cat in
                            let catItems = store.items.filter { $0.category == cat }
                            let catBytes = catItems.reduce(0) { $0 + $1.sizeBytes }
                            sidebarRow(
                                title: cat.title,
                                icon: cat.iconName,
                                tint: cat == .databaseCompact || cat == .dormantApps ? .orange : .teal,
                                count: catItems.count,
                                bytes: catBytes,
                                isSelected: store.selectedSidebarFilter == .category(cat)
                            ) {
                                store.selectedSidebarFilter = .category(cat)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            // Safety Architecture Footer Card
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("安全瘦身保障机制")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("• 零后台常驻进程，即开即用\n• 严禁篡改应用签名二进制架构\n• 数据库重组前自动校验键值行数\n• 支持移至废纸篓，随时一键原路恢复")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
    }

    private func sidebarRow(
        title: String,
        icon: String,
        tint: Color,
        count: Int,
        bytes: Int64,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : tint)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if count > 0 {
                    Text(ByteFormatting.string(fromBytes: bytes))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.95) : .secondary)
                } else {
                    Text("0 B")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Content Area

    private var contentAreaView: some View {
        VStack(spacing: 0) {
            filterToolbar
            Divider()

            if store.isScanning && store.items.isEmpty {
                scanningPlaceholderView
            } else if store.items.isEmpty {
                welcomeEmptyStateView
            } else if store.filteredItems.isEmpty {
                noFilterMatchView
            } else {
                scanResultsListView
            }
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("搜索应用名称、路径或膨胀原因...", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !store.searchText.isEmpty {
                    Button(action: { store.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .frame(maxWidth: 320)

            Spacer()

            if !store.items.isEmpty {
                Button("仅选无感安全项") {
                    store.selectAllSafeItems()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("全选当前列表") {
                    let visibleIDs = Set(store.filteredItems.map(\.id))
                    for idx in store.items.indices where visibleIDs.contains(store.items[idx].id) {
                        store.items[idx].isSelected = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("取消全选") {
                    let visibleIDs = Set(store.filteredItems.map(\.id))
                    for idx in store.items.indices where visibleIDs.contains(store.items[idx].id) {
                        store.items[idx].isSelected = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var scanningPlaceholderView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.3)
            Text("正在扫描 Mac 上的隐形存储膨胀项...")
                .font(.system(size: 16, weight: .semibold))
            Text(store.currentPhaseText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("取消扫描") {
                store.cancelScanIfNeeded()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeEmptyStateView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 72, height: 72)
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.blue)
                    }

                    Text("专治 Mac 软件「越用越大」的轻量级瘦身工具")
                        .font(.system(size: 20, weight: .bold))

                    Text("精准定位 Electron 自动更新残留、Chrome 双版本旧内核、Service Worker 离线缓存膨胀与 Cursor SQLite 状态库冗余。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)

                    HStack(spacing: 12) {
                        Button(action: {
                            store.setDemoMode(false)
                            store.startScan(forceRefresh: true)
                        }) {
                            Label("立即扫描我的 Mac", systemImage: "magnifyingglass.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(action: {
                            store.setDemoMode(true)
                        }) {
                            Label("预览 79.3 GB 典型膨胀案例", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 28)

                // 6 Rules Showcase Grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("六大核心扫描与安全清理规则")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ruleCard(
                            icon: "shippingbox.and.arrow.backward.fill",
                            title: "1. 自动更新残留包（无感安全）",
                            desc: "清理 Claude/Cursor (ShipIt)、腾讯会议、飞书、Sparkle 下载解压后未销毁的历史安装与更新包。"
                        )
                        ruleCard(
                            icon: "square.stack.3d.up.slash.fill",
                            title: "2. 应用内旧版冗余内核（无感安全）",
                            desc: "精准识别 Chrome 等应用 Frameworks/Versions 下非 Current 指向的旧版内核，不动二进制签名。"
                        )
                        ruleCard(
                            icon: "externaldrive.fill.badge.timemachine",
                            title: "3. 网页离线与图形缓存（无感安全）",
                            desc: "清理失控的 Service Worker CacheStorage 与 GPU 渲染缓存，完好保留 Cookie、书签与密码。"
                        )
                        ruleCard(
                            icon: "doc.text.magnifyingglass",
                            title: "4. 日志与开发缓存（无感安全）",
                            desc: "清理 ~/Library/Logs 调试日志、CrashReporter 崩溃转储及 pip/npm/Homebrew 历史下载包缓存。"
                        )
                        ruleCard(
                            icon: "cylinder.split.1x2.fill",
                            title: "5. Cursor 状态库无损重组（深度瘦身）",
                            desc: "导出并原样保留 ItemTable 登录与配置表，清空体积高达数十 GB 的 cursorDiskKV 历史快照气泡。"
                        )
                        ruleCard(
                            icon: "moon.zzz.fill",
                            title: "6. 长期休眠庞大应用（深度瘦身）",
                            desc: "检测超过 180 天未打开且体积 > 300MB 的大型应用及关联 Container，需手动勾选确认后移至废纸篓。"
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func ruleCard(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var noFilterMatchView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("当前筛选条件下没有匹配的项目")
                .font(.system(size: 15, weight: .medium))
            Button("重置筛选条件") {
                store.selectedSidebarFilter = .all
                store.searchText = ""
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanResultsListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(CleanupTier.allCases) { tier in
                    let tierItems = store.filteredItems.filter { $0.tier == tier }
                    if !tierItems.isEmpty {
                        tierSectionView(tier: tier, tierItems: tierItems)
                    }
                }
            }
            .padding(16)
        }
    }

    private func tierSectionView(tier: CleanupTier, tierItems: [ScanItem]) -> some View {
        let tierTotalBytes = tierItems.reduce(0) { $0 + $1.sizeBytes }
        let allSelected = tierItems.allSatisfy(\.isSelected)

        return VStack(alignment: .leading, spacing: 10) {
            // Section Header
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tier == .safe ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(tier.title)
                        .font(.system(size: 14, weight: .bold))
                }

                Text(tier.badgeText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tier == .safe ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((tier == .safe ? Color.green : Color.orange).opacity(0.14))
                    )

                Spacer()

                Text("共 \(tierItems.count) 项 · \(ByteFormatting.string(fromBytes: tierTotalBytes))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Button(allSelected ? "取消本组" : "全选本组") {
                    store.setAllSelection(in: tier, selected: !allSelected)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(tier.subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Item Cards
            VStack(spacing: 8) {
                ForEach(tierItems) { item in
                    ScanItemCardRow(
                        item: item,
                        onToggle: { store.toggleSelection(for: item.id) },
                        onReveal: { store.revealInFinder(path: item.path) }
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((tier == .safe ? Color.green : Color.orange).opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 16) {
            // Safety Execution Mode Picker
            HStack(spacing: 8) {
                Image(systemName: store.cleanMode == .moveToTrash ? "trash.circle.fill" : "flame.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(store.cleanMode == .moveToTrash ? .blue : .orange)

                Picker("清理方式", selection: $store.cleanMode) {
                    ForEach(CleanExecutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)
                .disabled(store.isCleaning)
            }

            if store.isCleaning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: store.cleanProgressFraction)
                        .frame(width: 180)
                    Text(store.currentPhaseText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Selection Metrics
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text("已勾选 \(store.selectedItems.count) 项")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("预计释放 \(ByteFormatting.string(fromBytes: store.selectedReclaimableBytes))")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(store.selectedReclaimableBytes > 0 ? .primary : .secondary)
                }
                let deepSelectedCount = store.selectedItems.filter { $0.tier == .deep }.count
                if deepSelectedCount > 0 {
                    Text("含 \(deepSelectedCount) 个深度瘦身项（已确认影响说明）")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                } else {
                    Text("当前仅含完全无感安全项，不影响任何登录态与个人文档")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }

            // Primary Action Button
            if store.isCleaning {
                Button(role: .destructive, action: { store.cancelCleanIfNeeded() }) {
                    Label("停止清理", systemImage: "stop.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button(action: handleCleanButtonTap) {
                    Label(
                        store.isDemoMode ? "模拟一键瘦身" : "一键瘦身释放空间",
                        systemImage: "sparkles"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.selectedItems.isEmpty || store.isScanning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func handleCleanButtonTap() {
        let hasDeepSelected = store.selectedItems.contains { $0.tier == .deep }
        if !store.isDemoMode && hasDeepSelected && store.cleanMode == .permanentDelete {
            showDeepPermanentConfirmAlert = true
        } else {
            store.startCleanSelected()
        }
    }
}

// MARK: - Individual Scan Item Card Row

private struct ScanItemCardRow: View {
    let item: ScanItem
    let onToggle: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 2)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((item.tier == .safe ? Color.blue : Color.orange).opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: item.category.iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(item.tier == .safe ? .blue : .orange)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(item.appName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.14))
                        )

                    if item.isDemoItem {
                        Text("演示样本")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }
                }

                // Path & Reveal Button
                HStack(spacing: 8) {
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !item.isDemoItem {
                        Button(action: onReveal) {
                            HStack(spacing: 2) {
                                Image(systemName: "folder")
                                Text("在访达中显示")
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Explanation & Impact Note
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("膨胀原因：")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(item.reason)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Text("清理影响：")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(item.tier == .safe ? .green : .orange)
                        Text(item.impactNote)
                            .font(.system(size: 11))
                            .foregroundColor(item.tier == .safe ? .secondary : .primary)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            // Right-aligned Monospace Size
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.formattedSize)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(item.sizeBytes >= 1024 * 1024 * 1024 ? .orange : .primary)

                Text(item.category.title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(item.isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Settings Popover View

private struct SettingsPopoverView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("扫描规则与阈值设置")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button("恢复默认") {
                    store.resetConfigToDefault()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                settingRow(
                    title: "最小缓存扫描阈值",
                    subtitle: "忽略小于该体积的零碎缓存目录",
                    valueText: "\(store.config.minCacheSizeMB) MB"
                ) {
                    Stepper("", value: $store.config.minCacheSizeMB, in: 1...500, step: 5)
                        .labelsHidden()
                }

                settingRow(
                    title: "Cursor 状态库重组阈值",
                    subtitle: "state.vscdb 超过此体积时提示无损瘦身",
                    valueText: "\(store.config.cursorDBCompactThresholdMB) MB"
                ) {
                    Stepper("", value: $store.config.cursorDBCompactThresholdMB, in: 20...2000, step: 50)
                        .labelsHidden()
                }

                settingRow(
                    title: "休眠应用未打开天数",
                    subtitle: "超过该天数未启动的应用归入深度瘦身项",
                    valueText: "\(store.config.dormantAppDaysThreshold) 天"
                ) {
                    Stepper("", value: $store.config.dormantAppDaysThreshold, in: 30...730, step: 30)
                        .labelsHidden()
                }

                settingRow(
                    title: "休眠应用最小体积",
                    subtitle: "仅统计体积大于该阈值的休眠应用",
                    valueText: "\(store.config.dormantAppMinSizeMB) MB"
                ) {
                    Stepper("", value: $store.config.dormantAppMinSizeMB, in: 100...2000, step: 50)
                        .labelsHidden()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("更新通道与清单源 (OTA)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("", selection: $store.config.updateChannel) {
                        Text("Stable 稳定版").tag("stable")
                        Text("Beta 预览版").tag("beta")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                TextField("https://.../release-manifest.json", text: $store.config.updateManifestURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            Divider()

            HStack {
                Text("修改阈值后点击「重新扫描」立即生效")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("立即重扫") {
                    store.isSettingsPopoverOpen = false
                    store.startScan(forceRefresh: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func settingRow<Control: View>(
        title: String,
        subtitle: String,
        valueText: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(valueText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
            control()
        }
    }
}

// MARK: - Global Task Center Sheet View ("消息盒子")

private struct TaskCenterSheetView: View {
    @ObservedObject var store: AppStore
    @Binding var copiedDiagnosticToast: Bool
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack(spacing: 12) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("全局任务中心（消息盒子）")
                        .font(.system(size: 16, weight: .bold))
                    Text("持久记录每次扫描与清理任务的执行状态、释放体积与明细日志")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    _ = store.copyDiagnosticReportToClipboard()
                    copiedDiagnosticToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        copiedDiagnosticToast = false
                    }
                }) {
                    Label(
                        copiedDiagnosticToast ? "已复制诊断摘要" : "复制诊断摘要",
                        systemImage: copiedDiagnosticToast ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("清空已完成记录") {
                    store.clearFinishedTaskHistory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.taskRecords.isEmpty)

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if store.taskRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("暂无扫描或清理任务记录")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.taskRecords) { record in
                            taskRecordCard(record)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 720, height: 500)
    }

    private func taskRecordCard(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusBadge(for: record.status)

                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))

                if record.isDemoMode {
                    Text("演示模式")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }

                Spacer()

                if record.totalBytesFreed > 0 {
                    Text("释放 \(ByteFormatting.string(fromBytes: record.totalBytesFreed))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }

                Text(Self.dateFormatter.string(from: record.updatedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text(record.phaseText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            if !record.itemResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.itemResults) { res in
                        HStack(spacing: 6) {
                            Image(systemName: res.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(res.success ? .green : .orange)
                                .font(.system(size: 11))
                            Text(res.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text("— \(res.message)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteFormatting.string(fromBytes: res.bytesFreed))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func statusBadge(for status: TaskStatus) -> some View {
        let color: Color = {
            switch status {
            case .queued, .running: return .blue
            case .succeeded: return .green
            case .partiallySucceeded: return .orange
            case .failed: return .red
            case .canceled: return .secondary
            }
        }()

        return Text(status.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - In-App Update Center Sheet View

private struct UpdateCenterSheetView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MacSlim 软件更新与完整性校验")
                        .font(.system(size: 16, weight: .bold))
                    Text("当前版本：v\(AppMetadata.version) (Build \(AppMetadata.buildNumber)) · 通道：\(store.config.updateChannel.uppercased())")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("重新检查") {
                    store.checkForUpdates(manual: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Divider()

            updateStateBody

            Spacer(minLength: 0)

            Divider()

            HStack {
                Text("更新包均通过 HTTPS 传输并在启用前强制校验 SHA-256 哈希摘要")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("前往 GitHub Releases 页面") {
                    store.openReleasesWebPage()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .padding(20)
        .frame(width: 560, height: 340)
    }

    @ViewBuilder
    private var updateStateBody: some View {
        switch store.updateState {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Text("尚未执行版本更新检查。")
                    .font(.system(size: 14, weight: .medium))
                Text("点击右上角「重新检查」将连接配置的 Release 清单源检测是否有可用的新版本。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在从更新源获取最新版本清单并比对 SemVer 版本号...")
                    .font(.system(size: 13))
            }
            .padding(.vertical, 20)
        case .upToDate(let ver, _):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("当前运行的 MacSlim v\(ver) 已是最新稳定版本。")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text("无需更新。如有预览版测试需求，可在设置中切换通道或前往 GitHub Releases 查看。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
        case .updateAvailable(let manifest):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("发现可用更新：v\(manifest.version) (\( ByteFormatting.string(fromBytes: manifest.sizeBytes)))", systemImage: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                    Spacer()
                    Text("SHA-256: \(manifest.sha256.prefix(16))...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                ScrollView {
                    Text(manifest.releaseNotes)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))

                HStack(spacing: 12) {
                    Button(action: {
                        store.downloadAndVerifyUpdate(manifest)
                    }) {
                        Label("一键下载并校验更新包", systemImage: "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("稍后提醒") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .downloading(let progress, let targetVer):
            VStack(alignment: .leading, spacing: 10) {
                Text("正在下载 MacSlim v\(targetVer) 安装镜像...")
                    .font(.system(size: 13, weight: .medium))
                ProgressView(value: progress)
            }
            .padding(.vertical, 16)
        case .verifying(let targetVer):
            HStack(spacing: 10) {
                ProgressView()
                Text("正在对 MacSlim v\(targetVer) 执行 SHA-256 完整性校验...")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.vertical, 16)
        case .readyToInstall(let dmgPath, let manifest):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("MacSlim v\(manifest.version) 下载并校验通过！")
                        .font(.system(size: 14, weight: .bold))
                }
                Text("安装包位置：\(dmgPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                if store.isScanning || store.isCleaning {
                    Text("⚠️ 当前有正在运行的扫描或清理任务，建议等待任务完成后再挂载替换新版本，以免中断任务。")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }

                HStack(spacing: 12) {
                    Button(action: {
                        store.openVerifiedUpdateDMG(path: dmgPath)
                    }) {
                        Label("打开并挂载 DMG 安装包", systemImage: "externaldrive.fill.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isScanning || store.isCleaning)

                    Button("稍后安装") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .failed(let reason, _):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("更新检查或校验未完成")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("重试检查") {
                        store.checkForUpdates(manual: false)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("手动打开 GitHub Releases") {
                        store.openReleasesWebPage()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
