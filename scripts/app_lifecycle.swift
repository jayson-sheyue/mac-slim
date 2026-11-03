import AppKit
import Foundation

@main
struct AppLifecycle {
    @MainActor
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw NSError(domain: "Usage", code: 1) }
            let apps = NSWorkspace.shared.runningApplications.filter { ($0.bundleIdentifier ?? "").hasPrefix("com.macslim.") }
            switch command {
            case "inventory":
                let rows = apps.map { ["pid": String($0.processIdentifier), "path": $0.bundleURL?.path ?? "", "executable": $0.executableURL?.path ?? "", "id": $0.bundleIdentifier ?? ""] }
                print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), encoding: .utf8)!)
            case "stop":
                let paths = Set(args.dropFirst().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
                let targets = apps.filter { paths.contains($0.bundleURL?.resolvingSymlinksInPath().path ?? "") }
                for app in targets {
                    guard app.terminate() else { throw NSError(domain: "App refused to quit; finish current tasks first", code: 2) }
                }
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    if targets.allSatisfy({ $0.isTerminated }) { return }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                throw NSError(domain: "App is still running; no files were replaced", code: 3)
            case "launch":
                guard args.count == 2 else { throw NSError(domain: "Usage", code: 1) }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args[1]), configuration: configuration) { app, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let app { continuation.resume(returning: app.processIdentifier) }
                        else { continuation.resume(throwing: NSError(domain: "No running application", code: 4)) }
                    }
                }
                print(pid)
            default: throw NSError(domain: "Unknown lifecycle command", code: 1)
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
