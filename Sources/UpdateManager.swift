import Foundation
import CryptoKit

// MARK: - SemVer 2.0.0 Parser & Comparator

public struct SemVer: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let buildMetadata: String?

    public init?(string: String) {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw.removeFirst()
        }

        let parts = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        func validIdentifiers(_ value: String) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
        if parts.count == 2 && !validIdentifiers(String(parts[1])) { return nil }
        buildMetadata = parts.count == 2 ? String(parts[1]) : nil
        let dash = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if dash.count == 2 {
            guard validIdentifiers(String(dash[1])) else { return nil }
            prerelease = dash[1].split(separator: ".").map(String.init)
            guard !prerelease.contains(where: { $0.utf8.allSatisfy { (48...57).contains($0) } && $0.count > 1 && $0.first == "0" }) else { return nil }
        } else { prerelease = [] }
        let nums = dash[0].split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count == 3, nums.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0") }),
              let maj = Int(nums[0]), let min = Int(nums[1]), let pat = Int(nums[2]) else { return nil }

        self.major = maj
        self.minor = min
        self.patch = pat
    }

    public var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        let pre = prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")
        let build = (buildMetadata != nil && !buildMetadata!.isEmpty) ? "+\(buildMetadata!)" : ""
        return base + pre + build
    }

    /// SemVer 2.0.0 §10 & §11: Build metadata MUST be ignored when determining version precedence.
    public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        lhs.major == rhs.major &&
        lhs.minor == rhs.minor &&
        lhs.patch == rhs.patch &&
        lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A normal version has higher precedence than a pre-release version (1.0.0 > 1.0.0-alpha)
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (lId, rId) in zip(lhs.prerelease, rhs.prerelease) {
            if lId == rId { continue }
            let lNum = lId.utf8.allSatisfy { (48...57).contains($0) }
            let rNum = rId.utf8.allSatisfy { (48...57).contains($0) }
            switch (lNum, rNum) {
            case (true, true):
                return lId.count == rId.count ? lId < rId : lId.count < rId.count
            case (true, false):
                // Numeric identifiers always have lower precedence than non-numeric identifiers
                return true
            case (false, true):
                return false
            case (false, false):
                return lId < rId
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - Release Manifest & Compatibility Evaluation

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let version: String
    public let buildNumber: Int
    public let channel: String
    public let publishedAt: String
    public let minSystemVersion: String
    public let supportedArchitectures: [String]
    public let dmgUrl: String
    public let sha256: String
    public let sizeBytes: Int64
    public let releaseNotes: String

    public init(
        version: String,
        buildNumber: Int,
        channel: String = "stable",
        publishedAt: String,
        minSystemVersion: String = "13.0",
        supportedArchitectures: [String] = ["arm64", "x86_64"],
        dmgUrl: String,
        sha256: String,
        sizeBytes: Int64,
        releaseNotes: String
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.channel = channel
        self.publishedAt = publishedAt
        self.minSystemVersion = minSystemVersion
        self.supportedArchitectures = supportedArchitectures
        self.dmgUrl = dmgUrl
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.releaseNotes = releaseNotes
    }
}

public enum UpdateCompatibilityResult: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case channelFilteredOut(manifestChannel: String)
    case incompatibleSystem(reason: String)
    case updateAvailable(ReleaseManifest)
}

public enum UpdateEvaluator {
    public static func evaluate(
        manifest: ReleaseManifest,
        currentVersion: String = AppMetadata.version,
        preferredChannel: String = AppMetadata.defaultChannel,
        currentOSVersion: String = Self.detectedOSVersionString(),
        currentArch: String = Self.detectedArchitecture()
    ) -> UpdateCompatibilityResult {
        guard let targetSemVer = SemVer(string: manifest.version),
              let currentSemVer = SemVer(string: currentVersion) else {
            return .incompatibleSystem(reason: L10n.tr(
                en: "Invalid version format in update manifest (\(manifest.version))",
                ja: "更新マニフェストのバージョン形式が無効です (\(manifest.version))",
                zh: "更新清单版本号格式无效 (\(manifest.version))"
            ))
        }

        // 1. Channel filtering: stable users must never automatically receive beta/prerelease updates
        let normalizedPreferred = preferredChannel.lowercased()
        let normalizedManifestChannel = manifest.channel.lowercased()
        if normalizedPreferred == "stable" && (normalizedManifestChannel != "stable" || targetSemVer.isPrerelease) {
            return .channelFilteredOut(manifestChannel: manifest.channel)
        }

        // 2. SemVer precedence comparison
        guard targetSemVer > currentSemVer else {
            return .upToDate(currentVersion: currentVersion)
        }

        // 3. Architecture check
        if !manifest.supportedArchitectures.contains(currentArch) {
            let archList = manifest.supportedArchitectures.joined(separator: ", ")
            return .incompatibleSystem(
                reason: L10n.tr(
                    en: "New version v\(manifest.version) only supports [\(archList)]; current machine is \(currentArch)",
                    ja: "新バージョン v\(manifest.version) はアーキテクチャ [\(archList)] のみ対応しています（現在のマシンは \(currentArch)）",
                    zh: "新版 v\(manifest.version) 仅支持架构 [\(archList)]，当前本机为 \(currentArch)"
                )
            )
        }

        func osVersion(_ value: String) -> SemVer? {
            SemVer(string: value.split(separator: ".", omittingEmptySubsequences: false).count == 2 ? value + ".0" : value)
        }
        guard let minOS = osVersion(manifest.minSystemVersion), let curOS = osVersion(currentOSVersion),
              !minOS.isPrerelease, minOS.buildMetadata == nil else {
            return .incompatibleSystem(reason: L10n.tr(
                en: "Invalid macOS version format in update manifest",
                ja: "更新マニフェストのシステムバージョン形式が無効です",
                zh: "更新清单系统版本格式无效"
            ))
        }
        if curOS < minOS {
            return .incompatibleSystem(reason: L10n.tr(
                en: "New version requires macOS \(manifest.minSystemVersion) (current: \(currentOSVersion))",
                ja: "新バージョンには macOS \(manifest.minSystemVersion) が必要です（現在: \(currentOSVersion)）",
                zh: "新版需要 macOS \(manifest.minSystemVersion)，当前为 \(currentOSVersion)"
            ))
        }

        return .updateAvailable(manifest)
    }

    public static func detectedOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func detectedArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

// MARK: - Explicit Update UI State

public enum UpdateState: Equatable, Sendable {
    /// Never checked yet — must never claim "up to date"
    case idle
    case checking
    case upToDate(version: String, checkedAt: Date)
    case updateAvailable(ReleaseManifest)
    case downloading(progress: Double, targetVersion: String)
    case verifying(targetVersion: String)
    case readyToInstall(dmgPath: String, manifest: ReleaseManifest)
    case failed(reason: String, manualURL: String)

    public var badgeLabel: String { badgeLabel(in: L10n.current) }

    public func badgeLabel(in language: AppLanguage) -> String {
        switch self {
        case .idle:
            return L10n.tr(en: "Check for Updates", ja: "アップデートを確認", zh: "检查更新", language: language)
        case .checking:
            return L10n.tr(en: "Checking...", ja: "確認中...", zh: "检查中...", language: language)
        case .upToDate:
            return L10n.tr(en: "Up to Date", ja: "最新です", zh: "已是最新", language: language)
        case .updateAvailable(let m):
            return L10n.tr(en: "New v\(m.version)", ja: "新バージョン v\(m.version)", zh: "新版本 v\(m.version)", language: language)
        case .downloading(_, let v):
            return L10n.tr(en: "Downloading v\(v)...", ja: "v\(v) をダウンロード中...", zh: "下载 v\(v)...", language: language)
        case .verifying(let v):
            return L10n.tr(en: "Verifying v\(v)...", ja: "v\(v) を検証中...", zh: "校验 v\(v)...", language: language)
        case .readyToInstall(_, let m):
            return L10n.tr(en: "v\(m.version) Ready", ja: "v\(m.version) 準備完了", zh: "v\(m.version) 待安装", language: language)
        case .failed:
            return L10n.tr(en: "Check Incomplete", ja: "確認未完了", zh: "检查未完成", language: language)
        }
    }

    public var hasUpdateOrAction: Bool {
        switch self {
        case .updateAvailable, .readyToInstall:
            return true
        default:
            return false
        }
    }
}

// MARK: - Safe Update Service (Fetch Manifest + Download + SHA256 Verification)

public actor UpdateService {
    private var isCheckInFlight: Bool = false

    private let allowLocalFiles: Bool
    public init(allowLocalFiles: Bool = false) { self.allowLocalFiles = allowLocalFiles }

    public func fetchAndEvaluateManifest(
        from urlString: String,
        currentVersion: String = AppMetadata.version,
        preferredChannel: String = AppMetadata.defaultChannel
    ) async -> UpdateState {
        guard !isCheckInFlight else {
            return .checking
        }
        isCheckInFlight = true
        defer { isCheckInFlight = false }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || (scheme == "file" && allowLocalFiles)) else {
            return .failed(
                reason: L10n.tr(
                    en: "Invalid update feed URL (only secure HTTPS or controlled local manifest files are supported)",
                    ja: "更新元の URL が無効です（安全な HTTPS または管理されたローカルマニフェストのみ対応）",
                    zh: "更新源地址无效（仅支持安全的 HTTPS 或本地受控清单文件）"
                ),
                manualURL: AppMetadata.releasesPageURL
            )
        }

        do {
            let data: Data
            if scheme == "file" {
                data = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
                request.setValue("MacSlim/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (fetchedData, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return .failed(
                        reason: L10n.tr(
                            en: "Update server returned HTTP \(http.statusCode) (offline, rate-limited, or release manifest not published yet)",
                            ja: "更新サーバーが HTTP \(http.statusCode) を返しました（オフライン、レート制限、または Release マニフェスト未公開の可能性があります）",
                            zh: "更新服务器返回状态码 HTTP \(http.statusCode)（可能离线、限流或尚未发布 Release 清单）"
                        ),
                        manualURL: AppMetadata.releasesPageURL
                    )
                }
                data = fetchedData
            }

            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            let eval = UpdateEvaluator.evaluate(
                manifest: manifest,
                currentVersion: currentVersion,
                preferredChannel: preferredChannel
            )

            switch eval {
            case .upToDate(let ver):
                return .upToDate(version: ver, checkedAt: Date())
            case .channelFilteredOut:
                return .upToDate(version: currentVersion, checkedAt: Date())
            case .incompatibleSystem(let reason):
                return .failed(reason: reason, manualURL: AppMetadata.releasesPageURL)
            case .updateAvailable(let validManifest):
                return .updateAvailable(validManifest)
            }
        } catch {
            return .failed(
                reason: L10n.tr(
                    en: "Could not fetch update manifest (\(error.localizedDescription)). Please try again later or visit GitHub Releases.",
                    ja: "更新マニフェストを取得できませんでした（\(error.localizedDescription)）。後で再試行するか GitHub Releases を確認してください。",
                    zh: "无法获取更新清单（\(error.localizedDescription)）。你可以稍后重试或前往 GitHub Releases 查看。"
                ),
                manualURL: AppMetadata.releasesPageURL
            )
        }
    }

    public func downloadAndVerifyDMG(
        manifest: ReleaseManifest,
        destinationDirectory: URL? = nil,
        onPhase: @Sendable (UpdateState) async -> Void
    ) async -> UpdateState {
        let fm = FileManager.default
        let expected = manifest.sha256.lowercased()
        guard let version = SemVer(string: manifest.version), version.description == manifest.version,
              expected.count == 64, expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest.sizeBytes > 0, manifest.sizeBytes <= 1024 * 1024 * 1024,
              let url = URL(string: manifest.dmgUrl),
              url.scheme == "https" || (url.isFileURL && allowLocalFiles) else {
            return .failed(
                reason: L10n.tr(
                    en: "Invalid URL, version, size, or checksum in update manifest",
                    ja: "更新マニフェスト内の URL、バージョン、サイズ、またはチェックサムが無効です",
                    zh: "更新清单中的地址、版本、体积或校验值无效"
                ),
                manualURL: AppMetadata.releasesPageURL
            )
        }
        // Each attempt owns a private directory; no shared predictable /tmp files.
        let parent = destinationDirectory ?? fm.temporaryDirectory
        let work = parent.appendingPathComponent("MacSlim-update-" + UUID().uuidString, isDirectory: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: work) } }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let part = work.appendingPathComponent("download.part")
            await onPhase(.downloading(progress: 0, targetVersion: manifest.version))
            if url.isFileURL {
                try fm.copyItem(at: url, to: part)
            } else {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                request.setValue("MacSlim/" + AppMetadata.version, forHTTPHeaderField: "User-Agent")
                let (download, response) = try await URLSession.shared.download(for: request)
                defer { try? fm.removeItem(at: download) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.url?.scheme == "https" else {
                    throw SafetyError.refused(L10n.tr(
                        en: "Update download failed or was redirected to an insecure URL",
                        ja: "更新パッケージのダウンロードに失敗したか、安全でない URL へリダイレクトされました",
                        zh: "更新包下载失败或被重定向到不安全地址"
                    ))
                }
                try fm.moveItem(at: download, to: part)
            }
            try Task.checkCancellation()
            let size = (try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == manifest.sizeBytes else {
                throw SafetyError.refused(L10n.tr(
                    en: "Installer size does not match the update manifest",
                    ja: "インストーラのサイズが更新マニフェストと一致しません",
                    zh: "安装包体积与更新清单不符"
                ))
            }
            await onPhase(.verifying(targetVersion: manifest.version))
            let handle = try FileHandle(forReadingFrom: part)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw SafetyError.refused(L10n.tr(
                    en: "Installer SHA-256 verification failed; downloaded file was not enabled",
                    ja: "インストーラの SHA-256 検証に失敗したため、ダウンロードファイルを有効化しませんでした",
                    zh: "安装包 SHA-256 校验失败，未启用下载文件"
                ))
            }
            let final = work.appendingPathComponent("MacSlim-" + manifest.version + "-Universal.dmg")
            try fm.moveItem(at: part, to: final)
            if !url.isFileURL {
                let quarantine = "0081;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";MacSlim;"
                guard ProcessRunner.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", quarantine, final.path]).status == 0 else {
                    throw SafetyError.refused(L10n.tr(
                        en: "Could not preserve macOS download quarantine metadata; please download manually from Releases",
                        ja: "システムのダウンロード隔離属性を保持できませんでした。Releases ページから手動でダウンロードしてください",
                        zh: "无法保留系统下载安全标记，请从版本发布页手动下载"
                    ))
                }
            }
            keep = true
            return .readyToInstall(dmgPath: final.path, manifest: manifest)
        } catch {
            return .failed(
                reason: L10n.tr(
                    en: "Update package was not enabled: \(error.localizedDescription)",
                    ja: "更新パッケージを有効化できませんでした: \(error.localizedDescription)",
                    zh: "更新包未启用：" + error.localizedDescription
                ),
                manualURL: AppMetadata.releasesPageURL
            )
        }
    }
}
