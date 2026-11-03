import Foundation

public final class CleanerEngine: Sendable {
    public init() {}

    public func clean(
        items: [ScanItem],
        mode: CleanExecutionMode,
        quitCursorIfNeeded: Bool = true,
        onItemProgress: @Sendable (Int, Int, String, CleanedItemResult?) -> Void
    ) async -> [CleanedItemResult] {
        var results: [CleanedItemResult] = []
        let total = items.count

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            onItemProgress(index, total, "正在处理：\(item.title)...", nil)

            let result: CleanedItemResult
            if item.isDemoItem {
                try? await Task.sleep(nanoseconds: 120_000_000)
                result = CleanedItemResult(
                    title: item.title,
                    path: item.path,
                    bytesFreed: item.sizeBytes,
                    success: true,
                    message: "[演示预览] 已模拟\(mode.shortTitle)，未改动真实磁盘"
                )
            } else {
                result = executeRealClean(for: item, mode: mode, quitCursorIfNeeded: quitCursorIfNeeded)
            }

            results.append(result)
            onItemProgress(index + 1, total, "已完成：\(item.title)", result)
        }

        return results
    }

    // MARK: - Single Item Execution

    public func executeRealClean(
        for item: ScanItem,
        mode: CleanExecutionMode,
        quitCursorIfNeeded: Bool = true
    ) -> CleanedItemResult {
        switch item.actionType {
        case .removeItem, .removeAppAndContainers:
            return removePaths(
                primaryPath: item.path,
                additionalPaths: item.additionalPaths,
                title: item.title,
                estimatedBytes: item.sizeBytes,
                mode: mode
            )
        case .removeChildren:
            return removeChildren(
                inDirectory: item.path,
                title: item.title,
                estimatedBytes: item.sizeBytes,
                mode: mode
            )
        case .rebuildCursorStateDB:
            return rebuildCursorDatabase(
                dbPath: item.path,
                title: item.title,
                mode: mode,
                quitCursorIfNeeded: quitCursorIfNeeded
            )
        }
    }

    // MARK: - Remove Item / Paths

    private func removePaths(
        primaryPath: String,
        additionalPaths: [String],
        title: String,
        estimatedBytes: Int64,
        mode: CleanExecutionMode
    ) -> CleanedItemResult {
        let fm = FileManager.default
        let allPaths = [primaryPath] + additionalPaths
        var freedBytes: Int64 = 0
        var errors: [String] = []

        for path in allPaths {
            guard fm.fileExists(atPath: path) else { continue }
            let beforeSize = ScannerEngine.directorySize(atPath: path)
            do {
                try deleteOrTrash(path: path, mode: mode)
                freedBytes += max(beforeSize, 0)
            } catch {
                errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }

        if errors.isEmpty {
            let finalFreed = freedBytes > 0 ? freedBytes : estimatedBytes
            return CleanedItemResult(
                title: title,
                path: primaryPath,
                bytesFreed: finalFreed,
                success: true,
                message: "已\(mode.shortTitle)（释放 \(ByteFormatting.string(fromBytes: finalFreed))）"
            )
        } else {
            return CleanedItemResult(
                title: title,
                path: primaryPath,
                bytesFreed: freedBytes,
                success: freedBytes > 0,
                message: "部分或全部受限：\(errors.joined(separator: "; "))"
            )
        }
    }

    // MARK: - Remove Children Inside Directory

    private func removeChildren(
        inDirectory dirPath: String,
        title: String,
        estimatedBytes: Int64,
        mode: CleanExecutionMode
    ) -> CleanedItemResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dirPath) else {
            return CleanedItemResult(
                title: title,
                path: dirPath,
                bytesFreed: 0,
                success: true,
                message: "目录已不存在，无需清理"
            )
        }

        guard let children = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return CleanedItemResult(
                title: title,
                path: dirPath,
                bytesFreed: 0,
                success: false,
                message: "无法读取目录内容（可能需要完全磁盘访问权限）"
            )
        }

        let protectedNames: Set<String> = [
            ".com.apple.containermanagerd.metadata.plist",
            ".DS_Store"
        ]

        var freedBytes: Int64 = 0
        var errors: [String] = []

        for child in children where !protectedNames.contains(child) {
            let childPath = (dirPath as NSString).appendingPathComponent(child)
            let childSize = ScannerEngine.directorySize(atPath: childPath)
            do {
                try deleteOrTrash(path: childPath, mode: mode)
                freedBytes += childSize
            } catch {
                errors.append("\(child): \(error.localizedDescription)")
            }
        }

        if errors.isEmpty || freedBytes > 0 {
            let reported = freedBytes > 0 ? freedBytes : estimatedBytes
            let suffix = errors.isEmpty ? "" : "（\(errors.count) 个正在写入的临时文件已跳过）"
            return CleanedItemResult(
                title: title,
                path: dirPath,
                bytesFreed: reported,
                success: true,
                message: "已\(mode.shortTitle)释放 \(ByteFormatting.string(fromBytes: reported))\(suffix)"
            )
        } else {
            return CleanedItemResult(
                title: title,
                path: dirPath,
                bytesFreed: 0,
                success: false,
                message: "清理失败：\(errors.first ?? "权限不足")"
            )
        }
    }

    // MARK: - Atomic Lossless Rebuild of Cursor state.vscdb

    public func rebuildCursorDatabase(
        dbPath: String,
        title: String,
        mode: CleanExecutionMode,
        quitCursorIfNeeded: Bool
    ) -> CleanedItemResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else {
            return CleanedItemResult(
                title: title,
                path: dbPath,
                bytesFreed: 0,
                success: false,
                message: "未找到数据库文件：\(dbPath)"
            )
        }

        let beforeBytes = ScannerEngine.directorySize(atPath: dbPath)
            + ScannerEngine.directorySize(atPath: dbPath + "-wal")
            + ScannerEngine.directorySize(atPath: dbPath + "-shm")

        let cleanPath = dbPath + ".macslim_clean"
        try? fm.removeItem(atPath: cleanPath)

        // 1. Query original ItemTable row count
        let countResult = Self.runSQLite(
            dbPath: dbPath,
            sql: "SELECT count(*) FROM ItemTable;"
        )
        guard countResult.exitCode == 0,
              let originalRowCount = Int(countResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return CleanedItemResult(
                title: title,
                path: dbPath,
                bytesFreed: 0,
                success: false,
                message: "读取原数据库 ItemTable 失败，已终止操作以保护原文件：\(countResult.error)"
            )
        }

        // 2. Build clean database with identical schema and copy ItemTable
        let escapedOldPath = dbPath.replacingOccurrences(of: "'", with: "''")
        let rebuildSQL = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);
        CREATE INDEX idx_composerHeaders_0 ON composerHeaders (workspaceId, isSubagent, isArchived, recency);
        CREATE INDEX idx_composerHeaders_1 ON composerHeaders (recency, composerId);
        ATTACH DATABASE '\(escapedOldPath)' AS old_db;
        INSERT INTO main.ItemTable SELECT key, value FROM old_db.ItemTable;
        DETACH DATABASE old_db;
        PRAGMA journal_mode=WAL;
        """

        let buildResult = Self.runSQLite(dbPath: cleanPath, sql: rebuildSQL)
        guard buildResult.exitCode == 0, fm.fileExists(atPath: cleanPath) else {
            try? fm.removeItem(atPath: cleanPath)
            return CleanedItemResult(
                title: title,
                path: dbPath,
                bytesFreed: 0,
                success: false,
                message: "构建新数据库失败，原文件未受任何改动：\(buildResult.error)"
            )
        }

        // 3. Verify new ItemTable row count matches original
        let verifyResult = Self.runSQLite(
            dbPath: cleanPath,
            sql: "SELECT count(*) FROM ItemTable;"
        )
        guard verifyResult.exitCode == 0,
              let newRowCount = Int(verifyResult.output.trimmingCharacters(in: .whitespacesAndNewlines)),
              newRowCount == originalRowCount else {
            try? fm.removeItem(atPath: cleanPath)
            return CleanedItemResult(
                title: title,
                path: dbPath,
                bytesFreed: 0,
                success: false,
                message: "校验新数据库配置行数不一致，已中止替换并保留原数据库"
            )
        }

        // 4. Gracefully quit Cursor if requested so file descriptors are released
        if quitCursorIfNeeded {
            _ = Self.runProcess(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"Cursor\" to quit"])
            Thread.sleep(forTimeInterval: 1.0)
        }

        // 5. Swap clean DB into place (moving old DB to Trash if mode == .moveToTrash)
        do {
            try deleteOrTrash(path: dbPath, mode: mode)
            try? fm.removeItem(atPath: dbPath + "-wal")
            try? fm.removeItem(atPath: dbPath + "-shm")
            try fm.moveItem(atPath: cleanPath, toPath: dbPath)
        } catch {
            return CleanedItemResult(
                title: title,
                path: dbPath,
                bytesFreed: 0,
                success: false,
                message: "替换数据库文件时出错：\(error.localizedDescription)"
            )
        }

        let afterBytes = ScannerEngine.directorySize(atPath: dbPath)
        let savedBytes = max(0, beforeBytes - afterBytes)
        return CleanedItemResult(
            title: title,
            path: dbPath,
            bytesFreed: savedBytes,
            success: true,
            message: "无损重组完成：保留全部 \(newRowCount) 项个人配置，数据库从 \(ByteFormatting.string(fromBytes: beforeBytes)) 降至 \(ByteFormatting.string(fromBytes: afterBytes))"
        )
    }

    // MARK: - Low-Level File & Process Helpers

    private func deleteOrTrash(path: String, mode: CleanExecutionMode) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        switch mode {
        case .moveToTrash:
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                // Fallback to moving directly into ~/.Trash if NSFileManager.trashItem fails
                let trashDir = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
                try fm.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
                let baseName = (path as NSString).lastPathComponent
                let destPath = (trashDir as NSString).appendingPathComponent("\(baseName)-\(Int(Date().timeIntervalSince1970))")
                try fm.moveItem(atPath: path, toPath: destPath)
            }
        case .permanentDelete:
            try fm.removeItem(at: url)
        }
    }

    private static func runSQLite(dbPath: String, sql: String) -> (exitCode: Int32, output: String, error: String) {
        return runProcess(executable: "/usr/bin/sqlite3", arguments: [dbPath, sql])
    }

    private static func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, output: String, error: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, outStr, errStr)
    }
}
