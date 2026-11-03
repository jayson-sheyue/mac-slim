# MacSlim (Mac 瘦身助手)

[![CI & Release Verification](https://github.com/jayson-sheyue/mac-slim/actions/workflows/ci.yml/badge.svg)](https://github.com/jayson-sheyue/mac-slim/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jayson-sheyue/mac-slim)](https://github.com/jayson-sheyue/mac-slim/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B%20(Universal)-blue)](https://github.com/jayson-sheyue/mac-slim/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

> **专治 Mac 软件「越用越大」的原生轻量级瘦身小工具**
> 纯原生 SwiftUI 构建 · Universal 通用双架构 (`arm64` + `x86_64`) · 零后台常驻进程 · 安装包仅 ~2.0 MB

---

## 1. 产品用途与解决痛点

许多 macOS 日常软件（Chrome、Cursor、VS Code、飞书、腾讯会议、Claude、ChatGPT 等）刚安装时只有几百 MB，使用几个月后却膨胀到几 GB 甚至几十 GB。其核心根源在于：
1. **自动更新“只下不删”**：Electron (`ShipIt`)、Sparkle、腾讯会议 (`UpdatePackages`)、飞书 (`LarkShell/update`) 在后台下载解压完整的新版 `.app` 或历史备份包后未及时销毁。
2. **双版本/多版本内核并存**：Chrome 等应用在 `.app/Contents/Frameworks/*.framework/Versions/` 内同时保留旧版与新版完整内核（每个版本 700MB+）。
3. **网页离线缓存与日志失控**：Chrome `Service Worker/CacheStorage` 离线缓存与代理/编辑器日志无限追加，动辄占用 10GB+。
4. **AI 编辑器 SQLite 状态库膨胀**：Cursor 的 `state.vscdb` 在 `cursorDiskKV` 表中堆积海量历史 AI 对话气泡与代码快照，导致单文件膨胀至 10GB+，而真正的账号登录与配置表 (`ItemTable`) 仅不到 2MB。

**MacSlim** 将经过实战验证的 6 大安全清理规则封装为开箱即用的 `.dmg` 桌面小工具，帮助 Mac 用户安全、透明地找回数十 GB 存储空间。

---

## 2. 核心功能与安全边界

### 🟢 / 🟡 双级安全分类模式
- **🟢 完全无感项（默认勾选）**
  - 包含：**自动更新残留包**、**应用内旧版冗余内核**、**浏览器与应用缓存**、**日志与开发工具缓存**。
  - **100% 零副作用**：不触碰任何软件的账号登录态（Cookie / Token）、聊天记录、浏览器书签或个人文档。
  - **严守 macOS 代码签名安全边界**：对第三方应用仅清理 `Versions/` 下未被 `Current` 符号链接指向的旧版内核目录，**绝不篡改二进制可执行文件架构 (`lipo`)**，彻底杜绝破坏 Apple Code Signature 导致应用崩溃或丢失钥匙串登录态的问题。
- **🟡 深度瘦身项（默认不勾选，需手动确认影响说明）**
  - **Cursor 状态数据库无损重组 (`state.vscdb`)**：通过系统内置 `/usr/bin/sqlite3` 原子导出并 100% 保留 `ItemTable`（账号登录、UI 布局、插件状态），清空膨胀的 `cursorDiskKV` 历史对话气泡并重建紧凑数据库，重组前后自动校验 `ItemTable` 行数一致性。
  - **长期休眠大型应用**：基于 Spotlight `kMDItemLastUsedDate` 与包修改时间，识别超过 180 天未打开且体积 > 300MB 的大型应用及其关联沙盒容器 (`~/Library/Containers/<bundle-id>/Data`)，清理时自动跳过受 macOS 系统保护的 `.com.apple.containermanagerd.metadata.plist`。

### 🛡️ 双重清理执行模式与全局任务中心
- **移至废纸篓（推荐默认）**：所有被清理的目录、旧内核或数据库原件均移入 macOS 废纸篓 (`~/.Trash`)，如有需要可随时一键原路恢复。
- **直接永久清理**：立即释放磁盘扇区，针对深度瘦身项配有二次安全确认弹窗。
- **真实扫描 + 79.3 GB 典型案例演示预览**：顶部工具栏支持一键切换「真实本机扫描」与「79GB 案例预览」（演示模式带醒目提示横幅，所有操作仅做模拟演练，绝不修改真实磁盘）。
- **全局任务中心（消息盒子）与安全更新**：内置跨视图结果缓存、所有权令牌防并发冲突、一键导出脱敏诊断摘要，以及基于 SemVer 2.0.0 和 SHA-256 完整性校验的应用内更新检查。

---

## 3. 普通用户安装与快速开始（无需安装任何开发工具）

### 3.1 系统与环境要求
- **操作系统**：macOS 13.0 (Ventura) 及以上版本
- **处理器架构**：原生支持 Apple Silicon (`M1 / M2 / M3 / M4` `arm64`) 与 Intel (`x86_64`)
- **外部运行时依赖**：**无**（纯 macOS 原生二进制，无需安装 Python、Node.js 或任何第三方库）
- **网络条件**：扫描与清理功能 **100% 离线可用**；仅点击「检查更新」时需连接 HTTPS 更新源

### 3.2 下载与安装步骤
1. 前往 [**GitHub Releases 页面**](https://github.com/jayson-sheyue/mac-slim/releases/latest) 下载最新版的 **`MacSlim-1.0.0-Universal.dmg`**。
2. 双击挂载 `.dmg` 镜像，将 **`MacSlim.app`** 拖入右侧的 **`Applications`（应用程序）** 文件夹。
3. **首次启动说明（Ad-hoc 签名提示）**：
   由于本开源项目采用本地 Ad-hoc 签名分发（未启用付费 Apple Developer ID 公证），首次打开时若系统提示“无法验证开发者”，请按以下任一方式打开：
   - 在访达（Finder）中按住 `Control` 键点击 `MacSlim.app`，选择 **「打开」** 并在弹窗中确认；
   - 或在终端执行以下命令移除下载隔离属性：
     ```bash
     xattr -cr /Applications/MacSlim.app
     ```
4. **可选权限配置**：如需扫描受 macOS 沙盒保护的部分第三方应用容器目录 (`~/Library/Containers`)，可在 **系统设置 → 隐私与安全性 → 完全磁盘访问权限 (Full Disk Access)** 中添加并开启 `MacSlim`。

### 3.3 升级与更新方式
- 点击应用顶部工具栏的 **「检查更新」**（或使用快捷键 `⌘U`），应用将从配置的 HTTPS 更新清单 (`release-manifest.json`) 获取最新版本信息。
- 发现新版后可点击 **「一键下载并校验更新包」**，应用会在本地强制验证 `.dmg` 的 `SHA-256` 哈希摘要通过后再打开挂载（若当前有正在执行的扫描或清理任务，将自动保护任务并允许稍后安装）。

---

## 4. 开发者源码构建与分层测试

如果你希望从源码编译、修改扫描规则或运行自动化测试，仅需 macOS 自带的 Xcode Command Line Tools (`xcode-select --install`)。

### 4.1 快速检查与隔离测试套件
```bash
# 运行全部 Swift 源码静态类型检查 + 26 项沙盒隔离单元/集成测试
./scripts/check.sh
```

### 4.2 构建 Universal `.app` 与 `.dmg` 发布包
```bash
# 执行测试门禁 -> 生成矢量图标 -> 编译 arm64+x86_64 通用二进制 -> 签名自检 -> 打包 DMG 与 SHA256 清单
./scripts/build_dmg.sh
```
构建完成后，产物位于 `dist/` 目录：
- `dist/MacSlim.app`：通用双架构原生应用包
- `dist/MacSlim-1.0.0-Universal.dmg`：可分发的 DMG 安装镜像
- `dist/SHA256SUMS.txt` & `dist/release-manifest.json`：SHA-256 校验文件与 OTA 更新清单

完整支持矩阵、回归测试用例说明与发布准入标准请参见 [**docs/testing.md**](./docs/testing.md)，版本历史请参见 [**CHANGELOG.md**](./CHANGELOG.md)。

---

## 5. 注意事项与已知限制

1. **正在运行的应用占用**：清理 Chrome 旧版内核框架后，建议重启一次 Chrome 以释放旧内核句柄；执行 Cursor `state.vscdb` 无损重组时，工具会自动通知 Cursor 安全退出后再执行原子替换。
2. **微信 / 飞书本地聊天记录保护**：为绝对保护用户隐私与数据安全，MacSlim **永远不会**扫描或删除微信 (`xwechat_files`)、飞书本地聊天数据库或剪映本地剪辑草稿 (`JianyingPro Drafts`)。
3. **签名与公证范围**：当前版本使用 Ad-hoc 代码签名 (`codesign --sign -`) 并通过 SHA-256 清单校验完整性，尚未包含 Apple Developer ID Notarization 公证票据。

---

## 6. 官方技术参考依据

本项目在系统 API 调用、数据库重组与版本发布规范上严格遵循以下官方文档：
- **Apple FileManager & Trash API**：[NSFileManager.trashItem(at:resultingItemURL:)](https://developer.apple.com/documentation/foundation/filemanager/1407692-trashitem) — 原生废纸篓安全移动与恢复机制。
- **Apple Spotlight Metadata (`kMDItemLastUsedDate`)**：[MDItem Reference](https://developer.apple.com/documentation/coreservices/mditem-r5u) — 准确读取应用真实最后打开时间。
- **Apple CryptoKit SHA-256**：[SHA256 Structure Reference](https://developer.apple.com/documentation/cryptokit/sha256) — 更新包加密哈希完整性校验。
- **SQLite 3 Atomic Rebuild & VACUUM**：[SQLite Official Documentation](https://www.sqlite.org/lang_vacuum.html) — 状态数据库无损导出与紧凑重建。
- **Semantic Versioning 2.0.0**：[SemVer 2.0.0 Specification](https://semver.org/) — 版本优先级比较规范。
- **GitHub Releases Management**：[Managing Releases in a Repository](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) — 发布资产与版本标签管理。
