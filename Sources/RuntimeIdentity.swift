import Foundation
import Darwin

/// One advisory lock per user, held by the process for its entire lifetime.
/// Never unlink a live lock file: replacing its inode would defeat mutual exclusion.
public final class InstanceLease: Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    public static func acquire(at url: URL) throws -> InstanceLease? {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SafetyError.refused(L10n.tr(
                en: "Could not create the application runtime lock",
                ja: "アプリの実行ロックを作成できませんでした",
                zh: "无法创建应用运行锁"
            ))
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw SafetyError.refused(L10n.tr(
                en: "Runtime lock file identity is invalid",
                ja: "実行ロックファイルの識別情報が無効です",
                zh: "运行锁的文件身份无效"
            ))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno; close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN { return nil }
            throw SafetyError.refused(L10n.tr(
                en: "Could not verify other running instances",
                ja: "他の実行中インスタンスを確認できませんでした",
                zh: "无法核对其他运行实例"
            ))
        }
        return InstanceLease(descriptor)
    }
    public func record(_ identity: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw SafetyError.refused(L10n.tr(
                en: "Could not write runtime identity",
                ja: "実行識別情報を書き込めませんでした",
                zh: "无法写入运行身份"
            ))
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard count > 0 else {
                    throw SafetyError.refused(L10n.tr(
                        en: "Failed to write runtime identity",
                        ja: "実行識別情報の書き込みに失敗しました",
                        zh: "写入运行身份失败"
                    ))
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SafetyError.refused(L10n.tr(
                en: "Failed to persist runtime identity",
                ja: "実行識別情報の保存に失敗しました",
                zh: "保存运行身份失败"
            ))
        }
    }
}

public enum RuntimeIdentity {
    public static let installationPath = "/Applications/MacSlim.app"
    public static let bundleID = "com.macslim.cleaner"
    public static func isCanonical(_ path: String) -> Bool {
        FileSafety.canonicalPath(path) == installationPath
    }
}
