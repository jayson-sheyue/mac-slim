# MacSlim

English · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

A native macOS cleanup utility that helps you inspect and remove leftover installer packages from app updates, accumulated caches, and historical logs. Built for macOS 13 and later as a Universal binary for Apple Silicon and Intel; see the [Testing Documentation](docs/testing.md) for verified environments.

> This document corresponds to the **1.1.1-beta.4 pre-release**. Official installer packages are defined by the assets listed on [GitHub Releases](https://github.com/jayson-sheyue/mac-slim/releases); earlier versions have different feature sets and safety boundaries.

[Installation & Build Guide](#installation--usage) · [Specific Scan Rules](#specific-scan-rules)

## Why Do Apps Keep Growing? Think of Your Disk as an Apartment

Your Mac's drive is like a furnished apartment you live in every day. Apps like Chrome, WeChat, Cursor, and WPS are residents or housekeepers helping you get work done.

When each app first moves in, it only brings a small suitcase. Over time, cardboard boxes unpacked during updates, ingredients kept on the counter for quick access, and old maintenance logs slowly fill up the storage room. **Not everything taking up space is junk: some items can be cleared away, some are still in active use, and some are your valuable belongings.**

Common disk growth can be understood through six everyday scenarios below, alongside what MacSlim does—and does not—touch.

### 1. Auto-Update Leftovers: Shipping Boxes Left Behind After Unpacking a New TV

While you are busy, the housekeeper brings in a new TV in its foam-lined shipping box to replace the old one, so you don't have to stand around waiting. However, if an update is interrupted, retried, or fails to clean up after itself, the shipping box and unpacked staging copy may stay sitting in the corner.

App updaters such as ShipIt, Sparkle, and others also download, unpack, and stage installer packages. **MacSlim primarily looks for these historical shipping boxes**: it inspects directory structures and modification times first, then checks whether the associated app or updater process is running. Recent files and active items are kept. Just having "update" in a folder name does not mean it can be thrown away immediately.

### 2. Legacy Framework Versions: The New Chair Is Here, But Someone Might Still Be Sitting in the Old One

When some apps upgrade, they place a new set of components next to the old ones and switch over the next time you restart the app, minimizing disruption to your current work. Old components may linger for a while or remain behind when automatic cleanup does not happen.

However, "a new chair is standing nearby" does not guarantee "nobody is using the old chair." **MacSlim lists legacy framework versions that match its rules so you can inspect their locations, but never deletes them automatically.** App code signing and runtime behavior vary widely; if cleanup is needed, use the app's own updater or reinstall it officially.

### 3. Web & Application Caches: Spices and Prep Ingredients Kept on the Kitchen Counter

Buying fresh groceries from scratch every time you open a web page would be slow, so apps keep images, scripts, and offline assets locally for instant reuse. This saves bandwidth and speeds up loading—and enables offline access—at the cost of leaving "spice jars" you used once months ago sitting on the counter.

MacSlim lists these cache candidates, with **unknown caches unselected by default**. Cleaning them may require re-downloading resources over the network or losing offline content. Accounts, passwords, and bookmarks are more like house keys and address books—they must not be swept away just because they sit in a nearby drawer. When MacSlim detects these personal-data signatures, it preserves the items and displays a warning.

### 4. AI & Office App Histories: Bound Drafts and Work Ledgers

Conversations, drafts, undo histories, workspace state, and code snapshots help you resume work or recover earlier content. They can grow large, but a thick ledger does not mean the pages inside are scrap paper, and storage formats can change across app versions.

**This category is outside MacSlim's cleanup scope.** The current version does not rebuild Cursor's `state.vscdb` and does not delete AI chat histories or other application databases. To manage that space, use the built-in management, backup, or export tools provided by the respective app.

### 5. Developer Tool Downloads & Build Artifacts: Scaffolding and Tool Sheds Left From Construction

Installing dependencies, compiling code, and running automated tests often download archives and set up environments first. Keeping them avoids starting from scratch next time; once a project ends, those materials can sit idle for months. Yet being stored in a "cache directory" does not make a tool scrap metal—browsers downloaded by Playwright may be actively required by your test suite.

MacSlim lists historical caches in standard locations for pip, Homebrew, and node-gyp, leaving them for you to review and select manually. For Playwright, it cross-checks package references and keeps versions registered as in use. **It never uninstalls project environments or infrequently used apps just because a project hasn't been opened recently.** Keep required download caches before working offline.

### 6. Diagnostic & Crash Logs: Dashcam Footage Kept for Troubleshooting

Apps write logs during normal operation and crashes so developers have clues when diagnosing issues. Right after a failure, these records are essential; over months of accumulation, they can take up substantial space.

MacSlim identifies historical log files while keeping recently modified ones. If you are actively troubleshooting an issue, keep the logs you need to share with developers first; **an old log is not automatically a useless log**.

## Why Don't App Developers Just Clean Everything Up Automatically?

Many apps already implement cache limits, log rotation, or post-update cleanup. However, those mechanisms cannot always cover interrupted updates, crashes, or side-by-side versions, and developers must balance several trade-offs:

- **The cost of false deletion is much higher.** Leaving an old box behind wastes disk space, but throwing away an important file tucked inside can cost a user their work.
- **Speed and disk space trade off against each other.** Keeping extra cache can make the next launch faster; clearing it may require re-downloading or recompiling.
- **Small leftovers from many apps add up across the whole system.** A single app may leave only a modest amount of data, but dozens of apps together become noticeable.
- **"Untouched for a while" does not mean "no longer needed."** An app cannot easily tell whether you abandoned a workflow or plan to pick it back up next week.

Because of this, disk usage cannot simply be blamed on developers "refusing to clean up," nor can a single aggressive deletion rule be applied safely across every application.

## How Does MacSlim Help You Organize?

Think of MacSlim as an assistant that prepares an itemized checklist before touching anything:

1. **Locate shipping boxes and historical records first.** It focuses on leftover update packages, caches, and logs without requiring you to memorize where each app stores its files.
2. **Explain purpose and impact clearly.** Recommended items among stale update packages and logs are pre-selected; unknown caches and developer caches require your manual review and selection; legacy framework versions are inspection-only.
3. **Move to Trash by default.** Before cleaning, MacSlim re-verifies that files have not changed and associated apps are not running, and records restoration paths. Moving items to Trash does not free disk space until Trash is emptied; permanent deletion requires separate confirmation.

On first use, quit related apps, keep the default settings, review the impact notes on recommended items, and clean a small batch first. Empty the Trash only after confirming your apps still work as expected. **The goal is to help you understand what you are cleaning—not to promise tens of gigabytes every run or claim that any cleanup is 100% side-effect-free.**

## Installation & Usage

End users do not need Python, Node.js, or Swift installed. Download the Universal DMG for the target version from [Releases](https://github.com/jayson-sheyue/mac-slim/releases), open it, and drag `MacSlim.app` into `/Applications`. Locally built release candidates are placed in `dist/`; the presence of a local candidate build does not mean that version has been published on GitHub.

The canonical launch location for the installed app is `/Applications/MacSlim.app`. Opening a newer build from a mounted DMG or another folder redirects to the installed app, or prompts you to install it first if `/Applications/MacSlim.app` is not present. Only one cleanup process runs at a time per macOS user account.

Builds currently use Ad-hoc code signing and have not yet undergone Developer ID signing or Apple notarization. On first launch after downloading, macOS Gatekeeper may block the app. After verifying the download source, follow [Apple's official guide](https://support.apple.com/en-gb/102445) to click **Open Anyway** in **System Settings → Privacy & Security**. You do not need to disable system security protections.

1. Click **Start Scan**. Scanning and cleaning run completely offline. The interface defaults to **English** on first launch and can be switched between `English`, `日本語`, and `中文` from the top toolbar or **Settings** without resetting your current scan results.
2. Review the detection basis, impact description, and file path for each item. Recommended items are selected by default; unknown caches must be selected manually.
3. The default mode is **Move to Trash**; **Delete Permanently** requires explicit confirmation and cannot be undone.
4. Open **History** to inspect results or restore items moved to Trash. Restoring will not overwrite newer files at the original path, and automatic restore is unavailable once Trash is emptied or the original parent directory no longer exists.
5. When permissions are insufficient, skipped paths are listed under warnings—do not interpret "0 items found" as "every protected directory was scanned." To scan protected directories, grant **Full Disk Access** to MacSlim in **System Settings → Privacy & Security → Full Disk Access**; never run the app as `root`.

"Moved to Trash" means the file location changed, not that free disk space has already increased. Sizes are estimated from allocated blocks; APFS clones, snapshots, compression, and other processes affect actual space reclaimed.

Clicking **Stop** halts subsequent items and waits for the in-flight file operation to finish. Operations already completed are not automatically rolled back. You cannot start a new scan or another cleanup batch while a cleanup operation is running.

## Specific Scan Rules

Detection rules rely on directory structure, app Bundle IDs, and file timestamps rather than targeting only a fixed list of brands. By default, files modified within the last 14 days are preserved, and caches whose purpose cannot be verified are left unselected.

<details>
<summary>View scanned directories, detection rules, and default behavior</summary>

| Category | Detection Basis | Default Behavior |
| --- | --- | --- |
| Electron update leftovers | `~/Library/Caches/*.ShipIt/update.*` for apps using the ShipIt updater layout | Recommended for stale directories; skipped if the associated app or an updater process inside the directory is running |
| Sparkle update leftovers | `org.sparkle-project.Sparkle/Installation/*` inside cache directories | Recommended for stale installer packages |
| Other updaters | Sandbox `Data/Library/Global/UpdatePackages/*`, `LarkShell/update/*`, `GoogleUpdater/crx_cache/*` | Unselected by default; verify sub-item purpose first—directory name alone does not prove it is safe to delete |
| Application caches | `~/Library/Caches/<App>/*`, plus explicit `Cache` / `Caches` / `Code Cache` / `GPUCache` / `CacheStorage` folders under Application Support | Unselected by default for manual review; not everything placed under `Caches` can be rebuilt without cost |
| Browser offline assets | `Service Worker/CacheStorage` in Chrome and other Chromium-based apps | Manual review required; cleaning may remove offline assets and require re-fetching over the network |
| Historical logs | `.log`, rotated logs, `.ips`, and `.crash` files under `~/Library/Logs` and app `logs` / `log` directories | Recommended for stale files while preserving recently modified logs |
| Dev-tool download caches | Standard cache locations for `pip`, `Homebrew`, and `node-gyp` | Manual review required; future installs or builds may need to re-download packages |
| Playwright historical browsers | Reads `.links` and each package's `browsers.json` to check all registered versions and platform overrides | Lists only unreferenced stale browser builds, unselected by default; keeps all builds if reference metadata is missing or corrupted. Re-verified before execution |
| Legacy app framework versions | `.app/Contents/Frameworks/*.framework/Versions` in app directories, listing only numeric versions older than a valid `Current` target | **Inspection only; never deleted by MacSlim** |

Scanning discovers applications in `/Applications`, `~/Applications`, and bounded subdirectories, correlating running state by app name and Bundle ID. Structural searches under Application Support have a fixed depth limit and never recursively walk your entire home directory.

</details>

## Data & Code-Signing Boundaries

- Never modifies installed `.app` bundles, never strips binary architectures, and never re-signs third-party applications. Whether an older framework version can be removed safely depends on how the app is packaged, signed, and launched; not being pointed to by `Current` is not sufficient proof that it is safe to delete. Use the application's official updater or reinstall instead.
- Cursor database rebuilding, chat history deletion, and dormant app uninstallation are no longer provided. MacSlim will never delete an application or its container simply because it has not been opened for a long time.
- If update leftovers or cache candidates contain personal data signatures—such as Cookies, Login Data, Bookmarks, passwords/keychains, or databases—they are preserved with a warning. MacSlim does not scan user `Documents`, chat storage, or draft folders. However, because it cannot infer every custom file format used by third-party apps, unknown caches still require manual inspection.
- Never cleans Playwright browsers that are currently running or still referenced by registered packages; Playwright-Go runtimes and installations whose references cannot be verified are preserved. Do not clean browser versions depended on by unregistered packages or custom browser paths.
- Does not promise "100% zero side effects" for any third-party application or future app update. App upgrades may change how directories are used; recently modified items, symlink redirects, cross-volume paths, and items that change after scanning are skipped.

## Settings, Updates & Recovery Data

Settings and recovery records are stored in `~/Library/Application Support/MacSlim/`. Upgrading from 1.0 preserves compatible minimum-size thresholds, while deprecated database, dormant-app, and custom update-feed settings are no longer active. Legacy history files are preserved on disk but are not imported as restorable records.

You can switch the interface language (`English` / `日本語` / `中文`, defaulting to `English` on first launch) and adjust the minimum size threshold and retention days in **Settings**. Network access occurs only when you click **Check for Updates**, using the repository's fixed GitHub Release manifest feed. Downloaded packages must pass both byte-size and SHA-256 verification, are saved in isolated temporary directories while preserving macOS quarantine metadata, and never automatically replace a running application. Note that SHA-256 verifies file integrity, not publisher code signing or Apple notarization.

Recovery records are written before moving files to Trash; if recovery storage is unavailable, moving to Trash is blocked. After an unexpected exit, pending recovery records are reconciled on launch. If the system Trash cannot be read, items must be restored manually in Finder. Do not delete `recovery-v1.json` manually if you expect the app to restore previously trashed items. Diagnostic summaries never contain file paths, access tokens, or raw task error messages, and are never uploaded automatically.

## Development & Verification

Building from source requires macOS and Xcode Command Line Tools with Swift 6 support. End users running the packaged app do not need developer tools.

```sh
./scripts/check.sh
./scripts/build_dmg.sh
./scripts/verify_release.sh
```

- `check.sh` runs static typechecking targeting the macOS 13 minimum deployment target and executes real file-operation regression suites inside isolated temporary directories—without quitting real apps, touching the user's real Trash, or accessing personal databases.
- `build_dmg.sh` builds the Universal (`arm64` + `x86_64`) app bundle, DMG, `SHA256SUMS.txt`, and `release-manifest.json`, and verifies version metadata, code signatures, and checksums.
- CI is configured for macOS 15 (`arm64` and Intel) and macOS 26 checks. The presence of a workflow file does not imply that a remote CI run has completed for uncommitted local changes.
- `--self-check` verifies startup and version identity only; it does not replace full UI, installation, or cleanup verification. MacSlim has no user-facing CLI cleanup interface and does not support Windows, Linux, or headless remote cleanup.

Maintainers publishing a release and synchronizing the local `/Applications/MacSlim.app` installation use:

```sh
./scripts/publish_release.sh --prerelease
# After full verification for a stable release, use --stable
```

The publish script requires a clean working tree whose commit is pushed and has passed CI. It builds once, uploads assets to a draft GitHub Release, downloads the exact DMG back from the draft, verifies its checksum, installs `/Applications/MacSlim.app` from that mounted DMG, verifies the full file tree, version, source commit, and single running instance, and only then publishes the Release. Re-running after an interruption reuses the existing draft assets rather than rebuilding and overwriting them. Maintainers need an authenticated GitHub CLI (`gh`), local Python 3, and write permissions to `/Applications`; end users do not need these tools.

Before updating `/Applications/MacSlim.app`, the installer requests a graceful quit and aborts if a scan or cleanup task is busy—never force-killing an active cleanup process. Verified existing installations and test copies are archived into verified compressed backups before runnable duplicates are removed, and failed installations attempt an automatic rollback. Backups and installation receipts are stored in `~/Library/Application Support/MacSlim/InstallBackups/`, while prior project build outputs are archived under `.build/prior-artifacts/`; user settings and cleanup recovery records are preserved. Post-release artifact checks can be re-run at any time with `./scripts/verify_release.sh`. The in-app "Check for Updates" feature only downloads and verifies the DMG—manual installation does not run this maintainer release pipeline.

Canonical-path enforcement and single-instance process locks apply to this version and future builds using the same mechanism; they cannot prevent a user from separately downloading and launching an older version that lacks this guard, nor do they lock across different macOS user accounts.

For detailed test cases, the platform support matrix, and environments still awaiting hardware verification, see [docs/testing.md](docs/testing.md).

## Technical References

- [Apple FileManager.trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)): Uses the system Trash and records the resulting item URL for restoration.
- [Apple Code Signing Technical Note TN2206](https://developer.apple.com/library/archive/technotes/tn2206/): Explains bundle signature boundaries and why "not pointed to by `Current`" does not make nested framework versions arbitrarily deletable.
- [Playwright Browsers Documentation](https://playwright.dev/docs/browsers) & [Official Registry Implementation](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/registry/index.ts): Used to cross-check browser references and preserve unknown layouts.
- [Swift Task](https://developer.apple.com/documentation/swift/task): Cooperative task cancellation while waiting for in-flight file operations to complete before unlocking UI state.
