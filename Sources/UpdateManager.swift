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

        // Split off +buildMetadata first
        let plusParts = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let withoutBuild = String(plusParts[0])
        self.buildMetadata = plusParts.count > 1 ? String(plusParts[1]) : nil

        // Split off -prerelease
        let dashParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let corePart = String(dashParts[0])
        if dashParts.count > 1 {
            let pre = String(dashParts[1])
            guard !pre.isEmpty else { return nil }
            self.prerelease = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if self.prerelease.contains(where: \.isEmpty) { return nil }
        } else {
            self.prerelease = []
        }

        let nums = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count >= 2 && nums.count <= 3 else { return nil }
        guard let maj = Int(nums[0]), let min = Int(nums[1]), maj >= 0, min >= 0 else { return nil }
        let pat: Int
        if nums.count == 3 {
            guard let p = Int(nums[2]), p >= 0 else { return nil }
            pat = p
        } else {
            pat = 0
        }

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
            let lNum = Int(lId)
            let rNum = Int(rId)
            switch (lNum, rNum) {
            case let (.some(ln), .some(rn)):
                return ln < rn
            case (.some, .none):
                // Numeric identifiers always have lower precedence than non-numeric identifiers
                return true
            case (.none, .some):
                return false
            case (.none, .none):
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
            return .incompatibleSystem(reason: "更新清单版本号格式无效 (\(manifest.version))")
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
        if !manifest.supportedArchitectures.isEmpty && !manifest.supportedArchitectures.contains(currentArch) {
            return .incompatibleSystem(
                reason: "新版 v\(manifest.version) 仅支持架构 [\(manifest.supportedArchitectures.joined(separator: ", "))]，当前本机为 \(currentArch)"
            )
        }

        // 4. Minimum macOS version check
        if let minOS = SemVer(string: manifest.minSystemVersion),
           let curOS = SemVer(string: currentOSVersion),
           curOS < minOS {
            return .incompatibleSystem(
                reason: "新版 v\(manifest.version) 需要 macOS \(manifest.minSystemVersion) 及以上版本（当前为 macOS \(currentOSVersion)）"
            )
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
                String(validatingUTF8: $0) ?? "arm64"
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

    public var badgeLabel: String {
        switch self {
        case .idle: return "检查更新"
        case .checking: return "检查中..."
        case .upToDate: return "已是最新"
        case .updateAvailable(let m): return "新版本 v\(m.version)"
        case .downloading(_, let v): return "下载 v\(v)..."
        case .verifying(let v): return "校验 v\(v)..."
        case .readyToInstall(_, let m): return "v\(m.version) 待安装"
        case .failed: return "检查未完成"
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

    public init() {}

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
              (scheme == "https" || scheme == "file") else {
            return .failed(
                reason: "更新源地址无效（仅支持安全的 HTTPS 或本地受控清单文件）",
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
                        reason: "更新服务器返回状态码 HTTP \(http.statusCode)（可能离线、限流或尚未发布 Release 清单）",
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
                reason: "无法获取更新清单（\(error.localizedDescription)）。你可以稍后重试或前往 GitHub Releases 查看。",
                manualURL: AppMetadata.releasesPageURL
            )
        }
    }

    public func downloadAndVerifyDMG(
        manifest: ReleaseManifest,
        destinationDirectory: URL = URL(fileURLWithPath: "/tmp"),
        onPhase: @Sendable (UpdateState) -> Void
    ) async -> UpdateState {
        let trimmedURL = manifest.dmgUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "file") else {
            return .failed(
                reason: "更新安装包下载地址不安全或格式无效（必须使用 HTTPS）",
                manualURL: AppMetadata.releasesPageURL
            )
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let partURL = destinationDirectory.appendingPathComponent("MacSlim-\(manifest.version).dmg.part")
        let finalURL = destinationDirectory.appendingPathComponent("MacSlim-\(manifest.version)-Universal.dmg")
        try? fm.removeItem(at: partURL)

        onPhase(.downloading(progress: 0.2, targetVersion: manifest.version))

        do {
            let dmgData: Data
            if scheme == "file" {
                dmgData = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
                request.setValue("MacSlim/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return .failed(
                        reason: "下载更新包失败（HTTP \(http.statusCode)），原应用与数据未受影响",
                        manualURL: AppMetadata.releasesPageURL
                    )
                }
                dmgData = data
            }

            guard !dmgData.isEmpty else {
                return .failed(
                    reason: "下载的更新包为空文件，已拒绝启用",
                    manualURL: AppMetadata.releasesPageURL
                )
            }

            try dmgData.write(to: partURL, options: .atomic)

            // Verify cryptographic SHA-256 digest before enabling the final DMG file
            onPhase(.verifying(targetVersion: manifest.version))
            let digest = SHA256.hash(data: dmgData)
            let actualHex = digest.map { String(format: "%02x", $0) }.joined()
            let expectedHex = manifest.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            guard actualHex == expectedHex else {
                try? fm.removeItem(at: partURL)
                return .failed(
                    reason: "更新包 SHA-256 完整性校验失败（期望 \(expectedHex.prefix(12))...，实际 \(actualHex.prefix(12))...），已安全销毁损坏文件",
                    manualURL: AppMetadata.releasesPageURL
                )
            }

            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: partURL, to: finalURL)

            return .readyToInstall(dmgPath: finalURL.path, manifest: manifest)
        } catch {
            try? fm.removeItem(at: partURL)
            return .failed(
                reason: "下载或写入更新包失败（\(error.localizedDescription)），已清理临时文件",
                manualURL: AppMetadata.releasesPageURL
            )
        }
    }
}
