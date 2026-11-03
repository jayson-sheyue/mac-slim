import SwiftUI
import AppKit

@main
struct MacSlimApp: App {
    @StateObject private var store = AppStore()

    init() {
        if CommandLine.arguments.contains("--self-check") {
            let demo = ScannerEngine.demoBlockerDataset()
            let disk = DiskUsageInfo.current()
            print("MacSlim v\(AppMetadata.version) (build \(AppMetadata.buildNumber)) self-check OK | demoItems=\(demo.count) | totalDisk=\(disk.totalBytes)")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("MacSlim — Mac 瘦身助手") {
            MainView(store: store)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始扫描本机") {
                    store.setDemoMode(false)
                    store.startScan(forceRefresh: true)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("切换 79GB 典型膨胀案例预览") {
                    store.setDemoMode(!store.isDemoMode)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("打开全局任务中心（消息盒子）") {
                    store.isTaskDrawerOpen = true
                    store.markAllTasksRead()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("检查软件更新...") {
                    store.checkForUpdates(manual: true)
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}
