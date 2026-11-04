import Foundation

public enum CleanupCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case updaterLeftovers, redundantFrameworks, browserAndAppCache, logsAndDevCache
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .updaterLeftovers: return "更新残留"
        case .redundantFrameworks: return "旧版内核"
        case .browserAndAppCache: return "应用缓存"
        case .logsAndDevCache: return "日志与开发缓存"
        }
    }
    public var iconName: String {
        switch self {
        case .updaterLeftovers: return "shippingbox"
        case .redundantFrameworks: return "square.stack.3d.up"
        case .browserAndAppCache: return "externaldrive"
        case .logsAndDevCache: return "doc.text"
        }
    }
}

public enum CleanupTier: String, Codable, Sendable {
    case safe, review
    public var title: String { self == .safe ? "建议清理" : "请先检查" }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let modified: Date
    public let size: Int64
}

public struct TreeStamp: Codable, Equatable, Sendable {
    public let root: FileStamp
    public let fingerprint: String
    public let contentFingerprint: String?
    public let allocatedBytes: Int64
    public let newestModification: Date
}

public struct ScanItem: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let appName: String
    public let category: CleanupCategory
    public let tier: CleanupTier
    public let path: String
    public let sizeBytes: Int64
    public let reason: String
    public let impactNote: String
    public let stamp: TreeStamp
    public let ownerBundleIDs: [String]
    public let ownerAppPaths: [String]
    public let inspectionOnly: Bool
    public var isSelected: Bool
    public var formattedSize: String { ByteFormatting.string(fromBytes: sizeBytes) }

    public init(title: String, appName: String, category: CleanupCategory, tier: CleanupTier,
                path: String, reason: String, impactNote: String, stamp: TreeStamp,
                ownerBundleIDs: [String] = [], ownerAppPaths: [String] = [], inspectionOnly: Bool = false) {
        self.title = title; self.appName = appName; self.category = category; self.tier = tier
        self.path = path; self.sizeBytes = stamp.allocatedBytes; self.reason = reason
        self.impactNote = impactNote; self.stamp = stamp; self.ownerBundleIDs = ownerBundleIDs
        self.ownerAppPaths = ownerAppPaths; self.inspectionOnly = inspectionOnly
        self.isSelected = tier == .safe && !inspectionOnly
    }
}

public struct ScanReport: Sendable {
    public var items: [ScanItem] = []
    public var warnings: [String] = []
    public var canceled = false
}

public enum CleanExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case moveToTrash, permanentDelete
    public var id: String { rawValue }
    public var title: String { self == .moveToTrash ? "移至废纸篓" : "永久删除" }
}

public struct CleanedItemResult: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let title: String
    public let success: Bool
    public let processedBytes: Int64
    public let message: String
}

public struct CleanReport: Sendable {
    public var results: [CleanedItemResult] = []
    public var canceled = false
}

public struct RecoveryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let originalPath: String
    public var trashPath: String?
    public let stamp: FileStamp
    public let tree: TreeStamp
    public let ownerBundleIDs: [String]
    public let ownerAppPaths: [String]
    public let createdAt: Date
    public var state: State
    public enum State: String, Codable, Sendable { case pending, trashed, restored }
}

public struct OperationRecord: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let date: Date
    public let title: String
    public let detail: String
}

public struct DiskUsageInfo: Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public static func current() -> DiskUsageInfo? {
        guard let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacity else { return nil }
        return DiskUsageInfo(totalBytes: Int64(total), availableBytes: Int64(available))
    }
}

public enum AppMetadata {
    public static let appName = "MacSlim"
    public static let version = "1.1.1-beta.3"
    public static let buildNumber = 113
    public static let defaultChannel = "stable"
    public static let minSystemVersion = "13.0"
    public static let repositoryURL = "https://github.com/jayson-sheyue/mac-slim"
    public static let releasesPageURL = repositoryURL + "/releases"
    public static let defaultUpdateManifestURL = repositoryURL + "/releases/latest/download/release-manifest.json"
}

public struct ScannerConfig: Codable, Equatable, Sendable {
    public var minCacheSizeMB: Int = 5
    public var minimumAgeDays: Int = 14
    public init(minCacheSizeMB: Int = 5, minimumAgeDays: Int = 14) {
        self.minCacheSizeMB = min(102400, max(1, minCacheSizeMB))
        self.minimumAgeDays = min(3650, max(1, minimumAgeDays))
    }
    enum CodingKeys: String, CodingKey { case minCacheSizeMB, minimumAgeDays }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minCacheSizeMB: try c.decodeIfPresent(Int.self, forKey: .minCacheSizeMB) ?? 5,
                  minimumAgeDays: try c.decodeIfPresent(Int.self, forKey: .minimumAgeDays) ?? 14)
    }
    public static let `default` = ScannerConfig()
}

public enum ByteFormatting {
    public static func string(fromBytes bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
