# 分层测试、环境验证与发布准入规范

本文档记录 `MacSlim` 的支持矩阵、分层自动化验证入口、高价值回归用例以及版本发布准入标准。

---

## 1. 支持矩阵与运行依赖策略

| 维度 | 规格说明 | 验证状态 |
| --- | --- | --- |
| **目标操作系统** | macOS 13.0 (Ventura) 及以上 | 已在 macOS (Apple Silicon `arm64`) 实际运行验证 |
| **CPU 架构** | Universal 通用双架构 (`arm64` Apple Silicon + `x86_64` Intel) | `lipo` 双架构构建通过，`arm64` 原生执行验证通过（`x86_64` 已完成交叉构建与二进制校验） |
| **交付形式** | 独立 `.dmg` 磁盘镜像 (`MacSlim-<version>-Universal.dmg`)，内含 `MacSlim.app` 与 `/Applications` 拖拽链接 | 已验证实际产物构建、签名与 `--self-check` 启动 |
| **运行时与外部依赖** | 零第三方依赖；仅调用 macOS 系统内置框架 (`SwiftUI`, `AppKit`, `CoreServices`, `CryptoKit`) 与系统自带 `/usr/bin/sqlite3` | 已随系统内置，无需用户额外安装 Python/Node 等运行时 |
| **网络前提** | 扫描与清理核心功能 **100% 离线可用**；仅「检查更新 / 下载更新包」需访问 HTTPS 更新源 | 已验证离线/错误地址不阻塞主流程 |
| **代码签名状态** | 本地 Ad-hoc 签名 (`codesign --force --deep --sign -`)，附 SHA-256 校验清单 | 未配置 Apple Developer ID 公证（已在 README 明确标注首次启动指引） |

---

## 2. 一键检查与构建命令

### 2.1 日常快速检查（Static Typecheck + 隔离单元/集成回归）
每次修改代码后执行，耗时约 5–8 秒，返回精确退出码：

```bash
./scripts/check.sh
```

包含两个阶段：
1. **静态类型与语法检查**：对 `Sources/` 下全部 7 个 Swift 源码文件执行 `/usr/bin/swiftc -typecheck`。
2. **隔离沙盒单元与集成测试 (`Tests/run_tests.swift`)**：在 `/tmp/macslim_test_<uuid>` 隔离目录中构造模拟的 `Home`、`Applications` 与 `AppSupport`，执行 26 项断言验证，不触碰开发机真实用户数据。

### 2.2 发布候选构建与产物核验
准备发布或打包 `.dmg` 时执行：

```bash
./scripts/build_dmg.sh
```

依次执行：
1. 调用 `./scripts/check.sh` 确保全部 26 项测试通过。
2. 矢量生成全尺寸 `AppIcon.icns`。
3. 分别编译 `arm64-apple-macosx13.0` 与 `x86_64-apple-macosx13.0` 并合成 Universal 二进制。
4. 注入权威版本 `VERSION` 至 `Info.plist`，执行 `codesign --verify --deep --strict`。
5. 运行 `MacSlim.app/Contents/MacOS/MacSlim --self-check` 校验包内版本身份与初始化链路。
6. 打包 `dist/MacSlim-<version>-Universal.dmg`，并生成 `dist/SHA256SUMS.txt` 与 `dist/release-manifest.json`。

---

## 3. 核心高价值回归用例清单

| 用例编号 | 覆盖场景 | 输入 / 前置条件 | 预期可观察结果 |
| --- | --- | --- | --- |
| **TC-01** | Electron `ShipIt` 更新残留识别 | `~/Library/Caches/*.ShipIt/update.*` 含超过阈值的残留包 | 归类为 `.safe`（完全无感项），默认勾选 (`isSelected == true`) |
| **TC-02** | 应用包内多版本内核安全清理 | `.app/Contents/Frameworks/*.framework/Versions/` 含 `130.0.1`、`131.0.2` 及 `Current -> 131.0.2` | 仅扫描并清理 `130.0.1`，严格保留 `Current` 指向的 `131.0.2` 激活版本 |
| **TC-03** | Chrome `Service Worker` 离线缓存 | `Default/Service Worker/CacheStorage` 超过阈值 | 识别并清理离线缓存，不触碰同级 `Cookies`、`Bookmarks`、`Login Data` |
| **TC-04** | 中文与空格路径兼容性 | `~/Library/Logs/中文 空格测试应用/debug.log` | 正确计算字节大小并完成清理，无路径转义错误 |
| **TC-05** | Cursor `state.vscdb` 原子无损重组 | 含 3 条 `ItemTable` 核心键值（含 `cursorAuth/accessToken`）与膨胀 `cursorDiskKV` | 归为 `.deep`（默认不勾选）；重组后 `cursorDiskKV` 清零，`ItemTable` 3 条数据与 Token 原值 100% 保留 |
| **TC-06** | 休眠大应用与受保护容器元数据 | 超过 180 天未打开的 `.app` 及 `~/Library/Containers/<id>`（含 `.com.apple.containermanagerd.metadata.plist`） | 清理应用与容器 `Data/` 载荷，保留受系统保护的 `.com.apple.containermanagerd.metadata.plist` 不报错 |
| **TC-07** | 演示模式与真实模式隔离及配置持久化 | 切换 `isDemoMode` 并修改 `minCacheSizeMB` 后重建 `AppStore` | 演示数据 (13 项) 与真实状态完全隔离；配置跨会话持久化生效 |
| **TC-08** | SemVer 2.0.0 语义比较与通道过滤 | 比较 `1.10.0` vs `1.9.0`、`1.0.0` vs `1.0.0-beta.1`、`1.0.0+b1` vs `1.0.0+b2` 及 `stable` 过滤 `beta` | `1.10.0 > 1.9.0`；正式版高于预发布版；`+build` 不提升优先级；稳定版用户忽略测试版更新 |
| **TC-09** | 更新包 SHA-256 校验与损坏包拒绝 | 分别传入匹配 SHA-256 与篡改 SHA-256 的更新清单与 `.dmg` | 匹配时进入 `.readyToInstall`；篡改时拒绝启用、转入 `.failed` 并自动清除临时 `.part` 文件 |

---

## 4. 发布准入标准 (Release Gate)

1. `./scripts/check.sh` 全部 26 项断言 100% 通过。
2. `VERSION`、`Sources/Models.swift` (`AppMetadata.version`)、`Info.plist`、Git Tag (`vX.Y.Z`)、`.dmg` 文件名与 `release-manifest.json` 版本号完全一致。
3. 最终 `.dmg` 资产、对应的 `SHA256SUMS.txt` 与 `release-manifest.json` 完整上传至对应 GitHub Release，并通过 `shasum -a 256 -c` 核验。
