import SwiftUI
import AppKit

@main
struct MacSlimApp: App {
    @StateObject private var store: AppStore
    private let fixtureMode: Bool
    private let runtimeLease: InstanceLease?
    @NSApplicationDelegateAdaptor(MacSlimDelegate.self) private var appDelegate
    init() {
        if CommandLine.arguments.contains("--self-check") {
            let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let bundleBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            if let bundleVersion, bundleVersion != AppMetadata.version { fputs("Bundle/source version mismatch\n", stderr); exit(1) }
            if let bundleBuild, bundleBuild != String(AppMetadata.buildNumber) { fputs("Bundle/source build mismatch\n", stderr); exit(1) }
            print("MacSlim v\(AppMetadata.version) (build \(AppMetadata.buildNumber)) self-check OK | \(UpdateEvaluator.detectedArchitecture()) | macOS \(UpdateEvaluator.detectedOSVersionString())")
            exit(0)
        }
        // Dedicated fixture bundles let UI automation select test data without relaunching a real-home instance.
        let fixtureRoot: String?
        #if UI_TESTING
        let index = CommandLine.arguments.firstIndex(of: "--ui-fixture")
        let argumentRoot = index.flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
        fixtureRoot = Bundle.main.object(forInfoDictionaryKey: "MacSlimUIFixtureRoot") as? String ?? argumentRoot
        #else
        fixtureRoot = nil
        #endif
        fixtureMode = fixtureRoot != nil
        if let fixtureRoot {
            runtimeLease = nil
            let root = FileSafety.canonicalPath(fixtureRoot)
            guard root.hasPrefix("/private/tmp/macslim-ui-"),
                  ["Home", "Applications", "Trash", "State"].allSatisfy({ FileSafety.isBelow(FileSafety.canonicalPath(root + "/" + $0), root) }) else { exit(2) }
            _store = StateObject(wrappedValue: AppStore(environment: ScanEnvironment(homeDirectory: root + "/Home", applicationDirectories: [root + "/Applications"]),
                storageDirectoryURL: URL(fileURLWithPath: root + "/State"), activity: { ActivitySnapshot() }, testTrashDirectory: root + "/Trash"))
        } else {
            guard RuntimeIdentity.isCanonical(Bundle.main.bundleURL.path) else {
                if FileManager.default.fileExists(atPath: RuntimeIdentity.installationPath) {
                    _ = NSWorkspace.shared.open(URL(fileURLWithPath: RuntimeIdentity.installationPath))
                } else {
                    let alert = NSAlert()
                    alert.messageText = "请先安装 MacSlim"
                    alert.informativeText = "请将应用拖入“应用程序”，然后从 /Applications/MacSlim.app 启动。其他副本不会执行清理。"
                    alert.runModal()
                }
                exit(0)
            }
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSlim")
                guard let lease = try InstanceLease.acquire(at: support.appendingPathComponent("runtime.lock")) else {
                    _ = NSWorkspace.shared.open(URL(fileURLWithPath: RuntimeIdentity.installationPath))
                    exit(0)
                }
                try lease.record(["pid": String(ProcessInfo.processInfo.processIdentifier), "path": RuntimeIdentity.installationPath,
                                  "version": AppMetadata.version, "build": String(AppMetadata.buildNumber),
                                  "sourceCommit": Bundle.main.object(forInfoDictionaryKey: "MacSlimSourceCommit") as? String ?? "unknown"])
                runtimeLease = lease
            } catch {
                fputs("MacSlim cannot acquire its runtime identity: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            _store = StateObject(wrappedValue: AppStore())
        }

    }
    private var testAppearance: ColorScheme? {
        #if UI_TESTING
        if CommandLine.arguments.contains("--ui-dark") || Bundle.main.object(forInfoDictionaryKey: "MacSlimUIDark") as? Bool == true { return .dark }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup(fixtureMode ? "MacSlim · 测试数据" : "MacSlim") {
            MainView(store: store).preferredColorScheme(testAppearance).onAppear { appDelegate.store = store }
        }
            .windowStyle(.titleBar)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("开始扫描") { store.startScan() }.keyboardShortcut("r", modifiers: .command).disabled(store.isBusy)
                    Button("清理记录") { store.showHistory = true }.keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("检查更新…") { store.checkForUpdates() }.keyboardShortcut("u", modifiers: .command)
                }
            }
    }
}

@MainActor
final class MacSlimDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.isBusy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "当前文件操作尚未结束"
        alert.informativeText = "请先停止或等待任务完成，再退出或安装更新。"
        alert.runModal()
        return .terminateCancel
    }
}
