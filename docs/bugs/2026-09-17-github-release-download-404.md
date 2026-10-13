---
date: 2026-09-17
mode: 前台
status: 代码已修复，线上下载状态未在本次复验
fix_commit: 2a25af4bcfc19d76d44ba9ab37a609d776049c2d
related_files:
  - scripts/publish-release.sh
  - scripts/package-app.sh
  - Resources/Info.plist
---

## Bug 分析

### 修复状态（2026-10-13 核对）

代码已在提交 `2a25af4`（`fix: 允许覆盖已有 Release，并将 Sparkle 更新源切到 Sim-hub-ios`）修复：

- [发布脚本](../../scripts/publish-release.sh) 检查目标 Release 是否存在；已有 Release 使用 `gh release upload --clobber` 更新资源，不存在时创建 Release。上传安装包名为 `UIReview-<version>.pkg`，默认仓库为 `Sim-hub-ios/ui_review_tools`。
- [Info.plist](../../Resources/Info.plist) 的 Sparkle feed 和 [打包脚本](../../scripts/package-app.sh) 的 zip 下载前缀均指向 `Sim-hub-ios/ui_review_tools`。
- [SparkleTests](../../Tests/UIReviewTests/SparkleTests.swift) 覆盖 feed 配置、资源缺失处理、发布命令的 dry-run 输出、覆盖上传参数及无空格资源名；这些测试不访问 GitHub，不能证明匿名下载或自动更新的线上状态。

本次仅核对本地实现与测试内容，未重新运行测试、发布资源或验证匿名下载。已安装且仍使用旧 feed 的版本，需要更新应用后才能使用新地址。

以下访问结果、路径、行号、根因与建议保留为 **2026-09-17 修复前分析**，不代表旧仓库或新仓库当前的访问状态。

### 问题描述（修复前）
重新执行 `publish-release.sh` 因 tag `v2.0.4` 已存在失败；未登录用户无法下载 Release 资源，Sparkle 检查更新也会失败。

### Bug 路径追踪（修复前）

1. **触发点：** `scripts/publish-release.sh:61` — 脚本只调用 `gh release create`。tag 已存在时 GitHub 返回 `a release with the same tag name already exists`，新打包的 pkg/zip/appcast 不会上传。
2. **传递过程：** App 的 `SUFeedURL` 是 `https://github.com/bay2/ui_review_tools/releases/latest/download/appcast.xml`（`Resources/Info.plist`）。Sparkle 以未登录身份 GET 该地址，再按 enclosure 下载 zip。
3. **出错位置：** 未登录访问 `github.com/bay2`、仓库页、`releases/latest/download/appcast.xml`、`releases/download/v2.0.4/UIReview-2.0.4.zip` 全部 HTTP 404。登录后 `gh` 能看到仓库 `visibility=public` 且资源 `state=uploaded`。另外 GitHub 把带空格的 `UI Review-2.0.4.pkg` 存成 `UI.Review-2.0.4.pkg`。

### 根本原因（修复前）
当时两件事叠在一起：发布脚本不能覆盖已有 tag；仓库对匿名用户不可见（账号/仓库公开页 404）。Sparkle 没有 GitHub 登录态，因此当时无法从该地址取得 appcast 和 zip。

### 当时评估的解决方案

#### 方案一：修发布脚本 + 确认 GitHub 对未登录可见（当时推荐）
**做法：** `publish-release.sh` 在 tag 已存在时改走 `gh release upload --clobber`；上传 pkg 使用无空格文件名 `UIReview-<version>.pkg`。同时用无痕窗口打开 `https://github.com/bay2/ui_review_tools`，若仍 404，需在 GitHub 设置里把账号/仓库做成对未登录用户可见（邮箱验证、解除限制等）。
- 优点：保留现有 GitHub Releases 方案；重复发同一版本可更新资源。
- 缺点：匿名 404 不在代码里，必须改 GitHub 账号可见性。
- 改动范围：`scripts/publish-release.sh`、`Tests/UIReviewTests/SparkleTests.swift`
- 屏幕适配：无

#### 方案二：把 appcast/zip 改放到另一个公开托管
**做法：** 换一个对匿名可见的账号、GitHub Pages、或对象存储，修改 `SUFeedURL` 和 `generate_appcast` 的 download prefix。
- 优点：不依赖 `bay2` 账号是否被 GitHub 对匿名隐藏。
- 缺点：要改 App 内写死的 feed URL，已安装的 2.0.4 不会跟着改。
- 改动范围：`Info.plist`、打包/发布脚本、已安装用户无法热修 feed。

### 当时的推荐理由
当时设计使用 GitHub Releases。建议先让同一 tag 能覆盖上传，并去掉 pkg 空格；当时下载失败的直接证据是匿名 404，还需要确认仓库对未登录用户可见。
