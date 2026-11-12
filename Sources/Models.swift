import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case en = "en"
    case ja = "ja"
    case zhHans = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .ja: return "日本語"
        case .zhHans: return "中文"
        }
    }
}

public enum L10n {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .en
        func get() -> AppLanguage {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ newValue: AppLanguage) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private static let storage = Storage()

    public static var current: AppLanguage {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    /// Returns the localized string for `language` (defaulting to `L10n.current`),
    /// falling back to `en` if a translation is empty.
    public static func tr(
        en: String,
        ja: String? = nil,
        zh: String? = nil,
        language: AppLanguage? = nil
    ) -> String {
        let target = language ?? current
        switch target {
        case .en:
            return en
        case .ja:
            if let ja, !ja.isEmpty { return ja }
            return en
        case .zhHans:
            if let zh, !zh.isEmpty { return zh }
            return en
        }
    }

    /// Reads persisted language from disk (or falls back to `.en` on first launch).
    /// Never auto-switches to `.ja` or `.zhHans` based on OS locale.
    public static func loadPersistedLanguage(from storageDirectory: URL? = nil) -> AppLanguage {
        let dir = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSlim")
        let configURL = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(ScannerConfig.self, from: data) {
            return config.language
        }
        return .en
    }
}

public enum ScanRuleKey: Codable, Equatable, Sendable {
    case shipIt
    case sparkle
    case genericUpdater
    case appSupportCache
    case logFile
    case sandboxUpdater
    case sandboxCache
    case userCache
    case devToolCache
    case playwrightUnreferenced
    case legacyFramework(current: String, version: String)

    public func reason(in language: AppLanguage = L10n.current) -> String {
        switch self {
        case .shipIt:
            return L10n.tr(
                en: "ShipIt update staging directory unmodified beyond the retention period",
                ja: "保持期間を超えて変更されていない ShipIt アップデート展開ディレクトリ",
                zh: "ShipIt 更新解压目录，内容已超过保留天数未修改",
                language: language
            )
        case .sparkle:
            return L10n.tr(
                en: "Historical Sparkle Installation update package",
                ja: "Sparkle Installation の過去のアップデートファイル",
                zh: "Sparkle Installation 历史更新文件",
                language: language
            )
        case .genericUpdater:
            return L10n.tr(
                en: "Historical installer package directory created by an updater",
                ja: "アップデータの過去インストーラパッケージディレクトリ",
                zh: "更新器的历史安装包目录",
                language: language
            )
        case .appSupportCache:
            return L10n.tr(
                en: "Cache directory structure under Application Support",
                ja: "Application Support 内のキャッシュ構造",
                zh: "应用支持目录中的缓存结构",
                language: language
            )
        case .logFile:
            return L10n.tr(
                en: "Historical log file inside a logs directory",
                ja: "ログディレクトリ内の過去のログファイル",
                zh: "日志目录中的历史日志文件",
                language: language
            )
        case .sandboxUpdater:
            return L10n.tr(
                en: "Sandboxed app update package directory",
                ja: "サンドボックスアプリのアップデートパッケージディレクトリ",
                zh: "沙盒应用更新包目录",
                language: language
            )
        case .sandboxCache:
            return L10n.tr(
                en: "Sandboxed app Library/Caches candidate",
                ja: "サンドボックスアプリ Library/Caches のキャッシュ候補",
                zh: "沙盒应用 Library/Caches 缓存候选",
                language: language
            )
        case .userCache:
            return L10n.tr(
                en: "Application cache candidate under user Library/Caches",
                ja: "ユーザー Library/Caches 配下のアプリキャッシュ候補",
                zh: "用户 Library/Caches 下的应用缓存候选",
                language: language
            )
        case .devToolCache:
            return L10n.tr(
                en: "Developer tool download and build cache",
                ja: "開発ツールのダウンロード・ビルドキャッシュ",
                zh: "开发工具下载与构建缓存",
                language: language
            )
        case .playwrightUnreferenced:
            return L10n.tr(
                en: "Not referenced by any valid package registered in Playwright .links",
                ja: "Playwright .links に登録されたすべての有効パッケージから未参照のバージョン",
                zh: "Playwright .links 登记的所有有效包均未引用此版本",
                language: language
            )
        case .legacyFramework(let current, let version):
            return L10n.tr(
                en: "Current points to \(current); found older version \(version)",
                ja: "Current は \(current) を指しており、以前のバージョン \(version) を検出",
                zh: "Current 指向 \(current)，发现较早版本 \(version)",
                language: language
            )
        }
    }

    public func impact(in language: AppLanguage = L10n.current) -> String {
        switch self {
        case .shipIt:
            return L10n.tr(
                en: "Removes historical update files; future updates may need to download again.",
                ja: "過去の更新ファイルを削除します。今後のアップデート時に再ダウンロードが必要になる場合があります。",
                zh: "将移除历史更新文件；以后更新可能需要重新下载。",
                language: language
            )
        case .sparkle:
            return L10n.tr(
                en: "Does not modify installed apps; future updates may download again.",
                ja: "インストール済みアプリは変更しません。今後のアップデートで再ダウンロードされる場合があります。",
                zh: "不修改已安装的应用；以后更新可能重新下载。",
                language: language
            )
        case .genericUpdater:
            return L10n.tr(
                en: "Folder name alone does not prove it is safe to delete—review first; future updates may re-download.",
                ja: "フォルダ名だけでは削除可能と断定できないため先に確認してください。今後の更新で再ダウンロードされる場合があります。",
                zh: "目录名不能证明内容可删除，请先检查；以后更新可能需要重新下载。",
                language: language
            )
        case .appSupportCache:
            return L10n.tr(
                en: "Verify purpose first. Offline assets may be lost and the app may need to re-download or rebuild caches.",
                ja: "用途を確認してください。オフライン資産が失われ、再ダウンロードやキャッシュ再構築が必要になる場合があります。",
                zh: "请确认用途。离线资源可能丢失，应用可能需要重新下载或重建缓存。",
                language: language
            )
        case .logFile:
            return L10n.tr(
                en: "Cannot be used to diagnose past issues once removed; recently written logs are preserved.",
                ja: "削除すると過去の障害調査には使えなくなります。最近書き込まれたログは保持されます。",
                zh: "删除后无法用于回查历史故障；近期写入的日志会保留。",
                language: language
            )
        case .sandboxUpdater:
            return L10n.tr(
                en: "Confirm these are historical installer packages first; items with detected personal data are preserved.",
                ja: "過去のインストーラパッケージであることを先に確認してください。個人データの特徴を含む項目は保持されます。",
                zh: "请先确认这些是历史安装包；包含已识别个人数据的项目会保留。",
                language: language
            )
        case .sandboxCache:
            return L10n.tr(
                en: "Verify purpose first. Offline assets may need to be downloaded again.",
                ja: "用途を確認してください。オフライン資産の再ダウンロードが必要になる場合があります。",
                zh: "请确认用途。离线资源可能需要重新下载。",
                language: language
            )
        case .userCache:
            return L10n.tr(
                en: "Review purpose first. Cleaning may affect offline usage and trigger resource re-downloads.",
                ja: "用途を確認してください。整理するとオフライン利用に影響し、再ダウンロードが発生する場合があります。",
                zh: "请检查用途。清理可能影响离线使用，并触发资源重新下载。",
                language: language
            )
        case .devToolCache:
            return L10n.tr(
                en: "Subsequent installs or builds may re-download packages; keep required files before working offline.",
                ja: "今後のインストールやビルドで再ダウンロードが発生する場合があります。オフライン作業前は必要な内容を保持してください。",
                zh: "后续安装或编译可能重新下载；离线使用前请保留所需内容。",
                language: language
            )
        case .playwrightUnreferenced:
            return L10n.tr(
                en: "Lists only verifiably unreferenced old browsers. Unregistered or custom-path projects may still need them—review first.",
                ja: "未参照と検証できた古いブラウザのみ表示しています。未登録またはカスタムパスのプロジェクトで必要な場合があるため確認してください。",
                zh: "只列出可验证未被引用的旧浏览器。未登记或自定义路径的项目仍可能需要它，请先检查。",
                language: language
            )
        case .legacyFramework:
            return L10n.tr(
                en: "Inspection only. To protect code signatures and runtime integrity, app bundles are never modified; use the app's official updater or reinstall.",
                ja: "確認専用です。署名と実行整合性を保護するためアプリバンドルは変更しません。公式アップデートまたは再インストールで対処してください。",
                zh: "仅供检查。为保护应用签名和运行完整性，不自动修改应用包；请通过应用官方更新或重新安装处理。",
                language: language
            )
        }
    }
}

public enum CleanupCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case updaterLeftovers, redundantFrameworks, browserAndAppCache, logsAndDevCache
    public var id: String { rawValue }
    public var title: String { title(in: L10n.current) }
    public func title(in language: AppLanguage) -> String {
        switch self {
        case .updaterLeftovers:
            return L10n.tr(en: "Update Leftovers", ja: "更新の残骸", zh: "更新残留", language: language)
        case .redundantFrameworks:
            return L10n.tr(en: "Legacy Frameworks", ja: "旧フレームワーク", zh: "旧版内核", language: language)
        case .browserAndAppCache:
            return L10n.tr(en: "App Caches", ja: "アプリキャッシュ", zh: "应用缓存", language: language)
        case .logsAndDevCache:
            return L10n.tr(en: "Logs & Dev Caches", ja: "ログ・開発キャッシュ", zh: "日志与开发缓存", language: language)
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
    public var title: String { title(in: L10n.current) }
    public func title(in language: AppLanguage) -> String {
        self == .safe
            ? L10n.tr(en: "Recommended", ja: "整理推奨", zh: "建议清理", language: language)
            : L10n.tr(en: "Review First", ja: "要確認", zh: "请先检查", language: language)
    }
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
    public var reason: String
    public var impactNote: String
    public let ruleKey: ScanRuleKey?
    public let stamp: TreeStamp
    public let ownerBundleIDs: [String]
    public let ownerAppPaths: [String]
    public let inspectionOnly: Bool
    public var isSelected: Bool
    public var formattedSize: String { ByteFormatting.string(fromBytes: sizeBytes) }

    public init(title: String, appName: String, category: CleanupCategory, tier: CleanupTier,
                path: String, reason: String, impactNote: String, stamp: TreeStamp,
                ownerBundleIDs: [String] = [], ownerAppPaths: [String] = [], inspectionOnly: Bool = false,
                ruleKey: ScanRuleKey? = nil) {
        self.title = title; self.appName = appName; self.category = category; self.tier = tier
        self.path = path; self.sizeBytes = stamp.allocatedBytes; self.reason = reason
        self.impactNote = impactNote; self.ruleKey = ruleKey; self.stamp = stamp
        self.ownerBundleIDs = ownerBundleIDs; self.ownerAppPaths = ownerAppPaths
        self.inspectionOnly = inspectionOnly
        self.isSelected = tier == .safe && !inspectionOnly
    }

    public func localizedReason(in language: AppLanguage) -> String {
        ruleKey?.reason(in: language) ?? reason
    }

    public func localizedImpact(in language: AppLanguage) -> String {
        ruleKey?.impact(in: language) ?? impactNote
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
    public var title: String { title(in: L10n.current) }
    public func title(in language: AppLanguage) -> String {
        self == .moveToTrash
            ? L10n.tr(en: "Move to Trash", ja: "ゴミ箱に入れる", zh: "移至废纸篓", language: language)
            : L10n.tr(en: "Delete Permanently", ja: "完全削除", zh: "永久删除", language: language)
    }
}

public struct CleanedItemResult: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let title: String
    public let success: Bool
    public let processedBytes: Int64
    public var message: String
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
    public static let version = "1.1.1"
    public static let buildNumber = 116
    public static let defaultChannel = "stable"
    public static let minSystemVersion = "13.0"
    public static let repositoryURL = "https://github.com/jayson-sheyue/mac-slim"
    public static let releasesPageURL = repositoryURL + "/releases"
    public static let defaultUpdateManifestURL = repositoryURL + "/releases/latest/download/release-manifest.json"
}

public struct ScannerConfig: Codable, Equatable, Sendable {
    public var minCacheSizeMB: Int = 5
    public var minimumAgeDays: Int = 14
    public var language: AppLanguage = .en
    public init(minCacheSizeMB: Int = 5, minimumAgeDays: Int = 14, language: AppLanguage = .en) {
        self.minCacheSizeMB = min(102400, max(1, minCacheSizeMB))
        self.minimumAgeDays = min(3650, max(1, minimumAgeDays))
        self.language = language
    }
    enum CodingKeys: String, CodingKey { case minCacheSizeMB, minimumAgeDays, language }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lang: AppLanguage
        if let raw = try c.decodeIfPresent(String.self, forKey: .language),
           let parsed = AppLanguage(rawValue: raw) {
            lang = parsed
        } else {
            lang = .en
        }
        self.init(minCacheSizeMB: try c.decodeIfPresent(Int.self, forKey: .minCacheSizeMB) ?? 5,
                  minimumAgeDays: try c.decodeIfPresent(Int.self, forKey: .minimumAgeDays) ?? 14,
                  language: lang)
    }
    public static let `default` = ScannerConfig()
}

public enum ByteFormatting {
    public static func string(fromBytes bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
