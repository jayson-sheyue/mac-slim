import Foundation
import CryptoKit
import AppKit

public enum SafetyError: LocalizedError {
    case refused(String)
    public var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}

public struct ScanEnvironment: Sendable {
    public let homeDirectory: String
    public let applicationDirectories: [String]
    public init(homeDirectory: String = NSHomeDirectory(), applicationDirectories: [String]? = nil) {
        self.homeDirectory = FileSafety.canonicalPath(homeDirectory)
        self.applicationDirectories = (applicationDirectories ?? ["/Applications", NSHomeDirectory() + "/Applications"])
            .map { FileSafety.canonicalPath($0) }
    }
    public var library: String { homeDirectory + "/Library" }
    // App bundles are deliberately absent: version directories are inspection-only.
    public var writableRoots: [String] { [library + "/Caches", library + "/Logs", library + "/Application Support", library + "/Containers"] }
}

public enum FileSafety {
    public static func canonicalPath(_ path: String) -> String {
        if let pointer = path.withCString({ realpath($0, nil) }) {
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/" else { return "/" }
        return URL(fileURLWithPath: canonicalPath(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path
    }

    public static func isBelow(_ path: String, _ root: String) -> Bool { path.hasPrefix(root + "/") }
    public static func stamp(_ path: String) throws -> FileStamp {
        let a = try FileManager.default.attributesOfItem(atPath: path)
        guard let device = (a[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = a[.modificationDate] as? Date,
              let size = (a[.size] as? NSNumber)?.int64Value else {
            throw SafetyError.refused("无法读取可靠的文件身份与时间信息")
        }
        return FileStamp(device: device, inode: inode, modified: modified, size: size)
    }
    public static func validate(_ path: String, roots: [String]) throws {
        guard path.hasPrefix("/"), !path.contains("//"), !path.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }),
              let root = roots.first(where: { isBelow(path, $0) }) else {
            throw SafetyError.refused("路径不在允许的清理范围内")
        }
        // Check every ancestor, including the allowed root. Never traverse redirected paths.
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw SafetyError.refused("路径包含符号链接，已跳过")
            }
            url.deleteLastPathComponent()
        }
        let base = try stamp(root)
        let target = try stamp(FileManager.default.fileExists(atPath: path) ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path)
        guard base.device == target.device else { throw SafetyError.refused("目标位于其他磁盘，已跳过") }
    }
    public static func tree(_ path: String, rejectProtectedData: Bool = false, includeContent: Bool = true) throws -> TreeStamp {
        let fm = FileManager.default
        let root = try stamp(path)
        var digest = SHA256()
        var contentDigest = SHA256()
        var allocated: Int64 = 0
        var newest = root.modified
        let pathRoot = path
        func visit(_ path: String) throws {
            try Task.checkCancellation()
            let s = try stamp(path)
            guard s.device == root.device else { throw SafetyError.refused("目录内存在其他挂载卷") }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let protectedNames: Set<String> = ["cookies", "cookies-journal", "login data", "login data-journal", "bookmarks", "bookmarks.bak", "history", "passwords", "keychains", "documents", "drafts", "chats", "messages", "local storage", "indexeddb", "session storage"]
            if rejectProtectedData && (protectedNames.contains(name) || ["cookies-", "login data-", "bookmarks-"].contains(where: { name.hasPrefix($0) }) || [".sqlite", ".vscdb", ".keychain"].contains(where: { name.contains($0) }) || name.hasSuffix(".db") || name.contains(".db-")) {
                throw SafetyError.refused("包含数据库、凭据或个人数据特征，已保留")
            }
            let a = try fm.attributesOfItem(atPath: path)
            let type = a[.type] as? FileAttributeType
            let relative = path == pathRoot ? "." : String(path.dropFirst(pathRoot.count))
            digest.update(data: Data("\(relative.utf8.count):\(relative)|\(s.device)|\(s.inode)|\(s.modified.timeIntervalSince1970)|\(s.size)|\(type?.rawValue ?? "")\n".utf8))
            if includeContent { contentDigest.update(data: Data("\(relative.utf8.count):\(relative)|".utf8)) }
            newest = max(newest, s.modified)
            if type == .typeDirectory {
                for child in try fm.contentsOfDirectory(atPath: path).sorted() { try visit(path + "/" + child) }
            } else if type == .typeRegular {
                if includeContent {
                    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard descriptor >= 0 else { throw SafetyError.refused("无法安全读取文件内容") }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var identity = stat()
                    guard fstat(descriptor, &identity) == 0, (identity.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                          UInt64(identity.st_ino) == s.inode,
                          UInt64(identity.st_dev) == s.device else { throw SafetyError.refused("读取时文件身份变化") }
                    var fileDigest = SHA256()
                    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                        try Task.checkCancellation()
                        fileDigest.update(data: chunk)
                    }
                    contentDigest.update(data: Data(fileDigest.finalize()))
                }
                let v = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
                allocated += Int64(v.fileAllocatedSize ?? v.fileSize ?? 0)
            } else if type == .typeSymbolicLink && includeContent {
                contentDigest.update(data: Data(try fm.destinationOfSymbolicLink(atPath: path).utf8))
            } // Symlinks inside archives are counted as leaves and never followed.
            guard try stamp(path) == s else { throw SafetyError.refused("读取时内容已变化，请重新扫描") }
        }
        try visit(path)
        return TreeStamp(root: root, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                         contentFingerprint: includeContent ? contentDigest.finalize().map { String(format: "%02x", $0) }.joined() : nil,
                         allocatedBytes: allocated, newestModification: newest)
    }
}

public struct RunningApplication: Sendable {
    public let bundleID: String
    public let path: String
    public init(bundleID: String, path: String) { self.bundleID = bundleID; self.path = path }
}

public struct ActivitySnapshot: Sendable {
    public let apps: [RunningApplication]
    public let executables: [String]
    public let reliable: Bool
    public init(apps: [RunningApplication] = [], executables: [String] = [], reliable: Bool = true) {
        self.apps = apps; self.executables = executables; self.reliable = reliable
    }
    public func isBusy(path: String, bundleIDs: [String], appPaths: [String]) -> Bool {
        !reliable || apps.contains { app in
            bundleIDs.contains(app.bundleID) || appPaths.contains(app.path)
        } || executables.contains { executable in
            executable == path || FileSafety.isBelow(executable, path) || appPaths.contains(where: { executable == $0 || FileSafety.isBelow(executable, $0) })
        }
    }
    public static func current() -> ActivitySnapshot {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningApplication(bundleID: $0.bundleIdentifier ?? "", path: $0.bundleURL.map { FileSafety.canonicalPath($0.path) } ?? "")
        }
        let result = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 5)
        return ActivitySnapshot(apps: apps, executables: result.output.split(separator: "\n").map(String.init), reliable: result.status == 0)
    }
}

public enum ProcessRunner {
    // Read output concurrently; waiting before draining pipes can deadlock on large output.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let group = DispatchGroup()
        let box = OutputBox()
        group.enter()
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if group.wait(timeout: .now() + 2) == .timedOut { return (-1, "") }
        process.waitUntilExit()
        return (timedOut ? -1 : process.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }
    private final class OutputBox: @unchecked Sendable { var data = Data() }
}
