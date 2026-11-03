# Changelog

All notable changes to **MacSlim (Mac 瘦身助手)** are documented in this file.
This project adheres to [Semantic Versioning 2.0.0](https://semver.org/).

## [1.0.0] - 2026-11-03

### Added
- **双级安全分类扫描引擎 (`ScannerEngine`)**：
  - 🟢 **完全无感项（默认勾选）**：
    - 自动识别 Electron `ShipIt`（Claude、Cursor、VS Code、Trae 等）、`Sparkle`（ChatGPT/Codex）、腾讯会议 `UpdatePackages`、飞书 `LarkShell/update`、`GoogleUpdater/crx_cache` 自动更新残留包。
    - 精准扫描 `/Applications/*.app/Contents/Frameworks/*.framework/Versions/` 下非 `Current` 符号链接指向的旧版冗余内核框架（严格保护 Apple Code Signature，不修改二进制可执行文件架构）。
    - 扫描 Chrome `Service Worker/CacheStorage` 离线静态资源膨胀及常见办公软件 `~/Library/Caches` 可再生缓存。
    - 扫描 `~/Library/Logs` 应用日志、崩溃转储及 `pip`、`Homebrew`、`Playwright`、`node-gyp` 历史下载缓存。
  - 🟡 **深度瘦身项（默认不勾选，附明确影响提示）**：
    - **Cursor `state.vscdb` 状态库原子无损重组**：100% 导出并保留 `ItemTable`（账号登录、UI 布局与插件状态），清空膨胀的 `cursorDiskKV` 历史对话气泡表，重组前后自动校验 `ItemTable` 行数一致性。
    - **长期休眠大型应用检测**：基于 Spotlight `kMDItemLastUsedDate` 与包修改时间识别超过 180 天未打开的大体积应用及关联容器（清理时自动跳过受系统保护的 `.com.apple.containermanagerd.metadata.plist`）。
- **双重安全清理模式 (`CleanerEngine`)**：
  - 支持 **「移至废纸篓（推荐，可随时恢复）」** 与 **「直接永久清理」**，对深度瘦身项永久清理提供二次安全确认拦截。
- **79.3 GB 典型膨胀案例演示预览**：
  - 支持一键切换「真实本机扫描」与「79GB 案例预览」，演示模式带醒目横幅标识且绝不修改本机磁盘。
- **持久化全局任务中心（消息盒子）与一键诊断导出 (`AppStore`)**：
  - 跨视图切换保持扫描结果缓存，使用所有权令牌 (`activeScanToken` / `activeCleanToken`) 防止并发竞态，支持一键复制环境与任务诊断摘要。
- **应用内安全更新与完整性校验 (`UpdateManager`)**：
  - 遵循 SemVer 2.0.0 版本比较与 `stable`/`beta` 通道过滤，下载 `.dmg` 更新包时强制校验 `CryptoKit.SHA256` 摘要，损坏包自动拒绝并清理临时文件。
