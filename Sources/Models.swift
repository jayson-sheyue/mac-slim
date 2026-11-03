import Foundation
import SwiftUI

// MARK: - Cleanup Tier & Category

public enum CleanupTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case safe = "safe"
    case deep = "deep"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safe:
            return "完全无感项（推荐默认清理）"
        case .deep:
            return "深度瘦身项（需手动确认）"
        }
    }

    public var subtitle: String {
        switch self {
        case .safe:
            return "仅清理自动更新残留包、旧版冗余内核、网页静态缓存与日志，不触碰登录态、聊天记录与个人数据"
        case .deep:
            return "清理历史 AI 会话数据库气泡或长期未使用的庞大应用，释放空间巨大，请确认影响说明后勾选"
        }
    }

    public var badgeText: String {
        switch self {
        case .safe: return "无感安全"
        case .deep: return "需确认影响"
        }
    }
}

public enum CleanupCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case updaterLeftovers = "updater_leftovers"
    case redundantFrameworks = "redundant_frameworks"
    case browserAndAppCache = "browser_app_cache"
    case logsAndDevCache = "logs_dev_cache"
    case databaseCompact = "database_compact"
    case dormantApps = "dormant_apps"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .updaterLeftovers: return "自动更新残留包"
        case .redundantFrameworks: return "应用内旧版内核"
        case .browserAndAppCache: return "浏览器与应用缓存"
        case .logsAndDevCache: return "日志与开发工具缓存"
        case .databaseCompact: return "数据库无损重组"
        case .dormantApps: return "长期未使用应用"
        }
    }

    public var iconName: String {
        switch self {
        case .updaterLeftovers: return "shippingbox.and.arrow.backward.fill"
        case .redundantFrameworks: return "square.stack.3d.up.slash.fill"
        case .browserAndAppCache: return "externaldrive.fill.badge.timemachine"
        case .logsAndDevCache: return "doc.text.magnifyingglass"
        case .databaseCompact: return "cylinder.split.1x2.fill"
        case .dormantApps: return "moon.zzz.fill"
        }
    }
}

// MARK: - Cleanup Action Type

public enum CleanupActionType: String, Codable, Sendable {
    /// Remove the target file or directory itself
    case removeItem
    /// Remove all children inside the target directory while keeping the directory itself
    case removeChildren
    /// Rebuild Cursor's state.vscdb preserving ItemTable and clearing cursorDiskKV
    case rebuildCursorStateDB
    /// Remove an application bundle and its associated container data paths
    case removeAppAndContainers
}

// MARK: - Scan Item

public struct ScanItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let appName: String
    public let category: CleanupCategory
    public let tier: CleanupTier
    public let path: String
    public let additionalPaths: [String]
    public let sizeBytes: Int64
    public let actionType: CleanupActionType
    public let reason: String
    public let impactNote: String
    public var isSelected: Bool
    public let isDemoItem: Bool
    public let lastAccessedDate: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        appName: String,
        category: CleanupCategory,
        tier: CleanupTier,
        path: String,
        additionalPaths: [String] = [],
        sizeBytes: Int64,
        actionType: CleanupActionType,
        reason: String,
        impactNote: String,
        isSelected: Bool? = nil,
        isDemoItem: Bool = false,
        lastAccessedDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.appName = appName
        self.category = category
        self.tier = tier
        self.path = path
        self.additionalPaths = additionalPaths
        self.sizeBytes = sizeBytes
        self.actionType = actionType
        self.reason = reason
        self.impactNote = impactNote
        self.isSelected = isSelected ?? (tier == .safe)
        self.isDemoItem = isDemoItem
        self.lastAccessedDate = lastAccessedDate
    }

    public var formattedSize: String {
        ByteFormatting.string(fromBytes: sizeBytes)
    }
}

// MARK: - Clean Execution Mode

public enum CleanExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case moveToTrash = "trash"
    case permanentDelete = "permanent"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .moveToTrash:
            return "移至废纸篓（推荐，可随时恢复）"
        case .permanentDelete:
            return "直接永久清理（立即释放磁盘）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .moveToTrash: return "移至废纸篓"
        case .permanentDelete: return "直接永久清理"
        }
    }
}

// MARK: - Disk Usage Info

public struct DiskUsageInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    public var usedPercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    public static func current() -> DiskUsageInfo {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let availImportant = values.volumeAvailableCapacityForImportantUsage ?? 0
            let availStandard = Int64(values.volumeAvailableCapacity ?? 0)
            let avail = availImportant > 0 ? availImportant : availStandard
            return DiskUsageInfo(totalBytes: total, availableBytes: avail)
        }
        return DiskUsageInfo(totalBytes: 256 * 1024 * 1024 * 1024, availableBytes: 80 * 1024 * 1024 * 1024)
    }
}

// MARK: - Task Center Models

public enum TaskStatus: String, Codable, Sendable {
    case queued = "queued"
    case running = "running"
    case succeeded = "succeeded"
    case partiallySucceeded = "partial"
    case failed = "failed"
    case canceled = "canceled"

    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "进行中"
        case .succeeded: return "已完成"
        case .partiallySucceeded: return "部分完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }
}

public struct CleanedItemResult: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let bytesFreed: Int64
    public let success: Bool
    public let message: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        path: String,
        bytesFreed: Int64,
        success: Bool,
        message: String
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.bytesFreed = bytesFreed
        self.success = success
        self.message = message
    }
}

public struct TaskRecord: Identifiable, Codable, Sendable {
    public let jobId: String
    public var id: String { jobId }
    public let title: String
    public let operationType: String // "scan" or "clean"
    public let createdAt: Date
    public var updatedAt: Date
    public var status: TaskStatus
    public var phaseText: String
    public var totalItemsCount: Int
    public var processedItemsCount: Int
    public var totalBytesFreed: Int64
    public var cleanMode: CleanExecutionMode?
    public var isDemoMode: Bool
    public var itemResults: [CleanedItemResult]
    public var errorSummary: String?
    public var isUnread: Bool

    public init(
        jobId: String = UUID().uuidString,
        title: String,
        operationType: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: TaskStatus = .running,
        phaseText: String = "",
        totalItemsCount: Int = 0,
        processedItemsCount: Int = 0,
        totalBytesFreed: Int64 = 0,
        cleanMode: CleanExecutionMode? = nil,
        isDemoMode: Bool = false,
        itemResults: [CleanedItemResult] = [],
        errorSummary: String? = nil,
        isUnread: Bool = true
    ) {
        self.jobId = jobId
        self.title = title
        self.operationType = operationType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.phaseText = phaseText
        self.totalItemsCount = totalItemsCount
        self.processedItemsCount = processedItemsCount
        self.totalBytesFreed = totalBytesFreed
        self.cleanMode = cleanMode
        self.isDemoMode = isDemoMode
        self.itemResults = itemResults
        self.errorSummary = errorSummary
        self.isUnread = isUnread
    }
}

// MARK: - Authoritative App Version & Release Identity

public enum AppMetadata {
    public static let appName = "MacSlim"
    public static let version = "1.0.0"
    public static let buildNumber = 100
    public static let defaultChannel = "stable"
    public static let minSystemVersion = "13.0"
    public static let repositoryURL = "https://github.com/jayson-sheyue/mac-slim"
    public static let releasesPageURL = "https://github.com/jayson-sheyue/mac-slim/releases"
    public static let defaultUpdateManifestURL = "https://github.com/jayson-sheyue/mac-slim/releases/latest/download/release-manifest.json"
}

// MARK: - App Configuration

public struct ScannerConfig: Codable, Equatable, Sendable {
    /// Minimum size in MB to report a cache directory
    public var minCacheSizeMB: Int
    /// Number of days since last access to consider a large app "dormant"
    public var dormantAppDaysThreshold: Int
    /// Minimum size in MB for dormant app detection
    public var dormantAppMinSizeMB: Int
    /// Minimum size in MB to suggest Cursor state.vscdb compaction
    public var cursorDBCompactThresholdMB: Int
    /// Configurable HTTPS URL for release-manifest.json
    public var updateManifestURL: String
    /// Update channel ("stable" or "beta")
    public var updateChannel: String

    public init(
        minCacheSizeMB: Int = 5,
        dormantAppDaysThreshold: Int = 180,
        dormantAppMinSizeMB: Int = 300,
        cursorDBCompactThresholdMB: Int = 100,
        updateManifestURL: String = AppMetadata.defaultUpdateManifestURL,
        updateChannel: String = AppMetadata.defaultChannel
    ) {
        self.minCacheSizeMB = minCacheSizeMB
        self.dormantAppDaysThreshold = dormantAppDaysThreshold
        self.dormantAppMinSizeMB = dormantAppMinSizeMB
        self.cursorDBCompactThresholdMB = cursorDBCompactThresholdMB
        self.updateManifestURL = updateManifestURL
        self.updateChannel = updateChannel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minCacheSizeMB = try container.decodeIfPresent(Int.self, forKey: .minCacheSizeMB) ?? 5
        self.dormantAppDaysThreshold = try container.decodeIfPresent(Int.self, forKey: .dormantAppDaysThreshold) ?? 180
        self.dormantAppMinSizeMB = try container.decodeIfPresent(Int.self, forKey: .dormantAppMinSizeMB) ?? 300
        self.cursorDBCompactThresholdMB = try container.decodeIfPresent(Int.self, forKey: .cursorDBCompactThresholdMB) ?? 100
        self.updateManifestURL = try container.decodeIfPresent(String.self, forKey: .updateManifestURL) ?? AppMetadata.defaultUpdateManifestURL
        self.updateChannel = try container.decodeIfPresent(String.self, forKey: .updateChannel) ?? AppMetadata.defaultChannel
    }

    public static let `default` = ScannerConfig()
}

// MARK: - Byte Formatting Helper

public enum ByteFormatting {
    public static func string(fromBytes bytes: Int64) -> String {
        let doubleBytes = Double(max(0, bytes))
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0

        if doubleBytes >= gb {
            return String(format: "%.2f GB", doubleBytes / gb)
        } else if doubleBytes >= mb {
            return String(format: "%.1f MB", doubleBytes / mb)
        } else if doubleBytes >= kb {
            return String(format: "%.0f KB", doubleBytes / kb)
        } else {
            return "\(bytes) B"
        }
    }
}
