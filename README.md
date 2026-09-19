# UI Review

面向开发者的原生 macOS UI 问题标注工具。

截图或录屏 → 框选与时间标记 → 评论 → 通过只读 MCP 或文件导出交给 Coding Agent。

当前开发版 **2.0.4**（build 7）：接入 Sparkle 自动更新。Sparkle 比较的是 `CFBundleVersion`，不是 2.0.3 / 2.0.4 营销版本号。

## 构建与运行

需要 macOS 14+、Xcode 16+（已选择 Command Line Tools）。当前工程使用 Swift Package。检查更新使用 [Sparkle](https://sparkle-project.org/)（MIT）。

```sh
bash scripts/build-app.sh
open 'build/UI Review.app'
```

发布优化构建：`bash scripts/build-app.sh release`。日常构建采用本机 ad-hoc 签名。对外安装包：`bash scripts/package-app.sh`（Developer ID 签名、公证 `.pkg`，并生成 Sparkle 用的 `UIReview-<version>.zip` 与 `appcast.xml`）。发布到 GitHub Releases：

```sh
bash scripts/package-app.sh
bash scripts/publish-release.sh
```

`publish-release.sh` 使用 tag `v<version>`，上传 pkg、zip 和 appcast。加 `--dry-run` 只打印命令；加 `--package` 会先打包再上传。可选把更新说明放在 `docs/releases/UIReview-<version>.md`。已装的非 Sparkle 版本不会自动升上来，需要先安装一次带更新器的包。EdDSA 私钥在本机登录钥匙串账户 `ui-review`，不要提交到 git。可用 Xcode 打开 `Package.swift` 开发。

## 使用

- **导入**：⌘O、⌘V、拖放图片，支持 PNG/JPEG/HEIC/TIFF/WebP（上限 100MB、4000 万像素；多帧图片取第一帧）。图片统一转换为正向 PNG，坐标使用转换后的原图像素。
- **视频**：导入 MP4/MOV，支持 H.264 与 SDR HEVC；单文件不超过 500MB、120 秒、4096 像素边长，HDR 暂不支持。支持播放、逐帧定位、倍速、时间点/时间段问题，以及暂停帧区域标注。
- **参考对比**：添加参考视频后，分别定位两侧起点并确认对齐；支持双视频播放和问题证据导出。
- **系统截图**：工具栏或全局快捷键 **⌃⌥⌘S**，拖选区域，Esc 取消。首次需授予 macOS 屏幕录制权限。App 关闭窗口后仍在运行，全局快捷键仍可用。
- **模拟器**：工具栏选择已启动的 iOS Simulator；未启动时提供打开 Simulator 的入口。不会自动重置或改变设备。
- **删除素材**：⌘Delete 删除当前选中的截图或动画及其问题，⌘Z 可撤销；输入框内保留文字编辑行为，长按不会连续删除多个素材。
- **标注**：主编辑窗口内 R 切换框选，V 切换选择（无需先点击画布，输入文字或弹窗中不触发）。拖动矩形移动，拖动四角缩放，Delete 删除。右侧编辑评论自动保存。空评论作为待填写的问题保留。
- **缩放**：适合窗口或 25%–200%，固定倍率下支持双向滚动。
- **管理**：左侧右键重命名/删除截图或动画。标题栏可编辑 Review 名称。“开始新的 Review”保留旧记录，在下一次导入时自动创建新 Review。应用菜单「检查更新…」可手动检查 GitHub Releases。
- **历史 Review**：从侧栏或 Review 菜单打开；双击整行切换并关闭历史窗口，单击不会切换。右键可删除 Review；删除当前记录后返回空白工作区，⌘Z 可撤销。空列表可点击“返回工作区”，Esc 关闭历史窗口。
- **撤销**：⌘Z / ⇧⌘Z，包含导入、删除、矩形、评论和 Review 切换。相邻评论输入合并，最多保留 80 次操作。重启保留内容，不保留撤销历史。
- **导出 / 复制**：工具栏始终提供导出 Review、复制整个 Review、复制当前素材。复制直接写入剪贴板；导出永远是当前这条 Review 的全部截图和视频，不含历史。含视频时先确认完整录屏体积。动画证据包含完整视频、有限关键帧、区域图与参考映射。纯截图导出包含 review.md、review.json、原图和标注图，不覆盖已有目录。

## MCP

在 App 的“连接 Coding Agent”中，可分别点击 Codex / Claude Code / Cursor 的“一键安装”。打开面板会自动检测；安装后会核对配置并完成本机 MCP 握手与只读工具检查；V2 提供五个截图工具和四个动画工具。绿色状态表示配置和服务可用，客户端仍需重新连接或开启新会话。

- Codex / Claude Code 需要已安装相应客户端命令行工具；Codex 优先使用桌面 App 内置 CLI，避免系统 Node 架构冲突；没有桌面版时回退到 PATH、Homebrew / `.local/bin` 等常见路径。
- Codex 使用官方 `mcp add`；Claude Code 合并当前用户的 `.claude.json`（支持 `CLAUDE_CONFIG_DIR`），保留其他 JSON 字段及文件权限。
- 修改前备份已有配置，备份位于原文件旁，扩展名为 `ui-review-backup-UUID`。相同配置重复安装不会重写；识别到标准 UI Review 的旧路径或禁用配置时，按钮改为“一键升级”，更新后重新检测。自定义同名配置不会自动覆盖。当前 App 内的 MCP 若仍是旧版，需先更新 App。
- Cursor 直接合并用户级 `~/.cursor/mcp.json`，无需安装 Cursor 命令行工具，保留其他 MCP 和 JSON 字段。配置格式见 [Cursor 官方文档](https://prod.cursor.com/help/customization/mcp)。
- Claude Code / Cursor 的项目配置可能覆盖用户配置；这里不修改项目配置。安装前请将 App 放在固定位置，移动后需要重新配置路径。
- “手动配置”中仍可复制 TOML / JSON。检测不会启动模型请求，不代表当前 Agent 会话已经调用过工具。

App 菜单 **Review → Agent 集成** 打开同一安装与检测面板；只有点击“一键安装”或“一键升级”才修改对应客户端配置，检测与复制配置不会修改客户端配置。
App 退出后，客户端仍可以按需启动包内 `ui-review-mcp`。

Codex 配置示例（替换成实际绝对路径）：

```toml
[mcp_servers.ui-review]
command = "/absolute/path/UI Review.app/Contents/MacOS/ui-review-mcp"
```

Claude Code / Cursor / 支持 JSON 的 MCP 客户端配置：

```json
{
  "mcpServers": {
    "ui-review": {
      "command": "/absolute/path/UI Review.app/Contents/MacOS/ui-review-mcp"
    }
  }
}
```

使用本地 stdio，兼容 MCP 2024-11-05、2025-03-26、2025-06-18、2025-11-25 初始化握手。
协议依据：[MCP 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[工具定义与图像内容](https://modelcontextprotocol.io/specification/2025-11-25/schema)。

| 工具 | 参数 | 返回 |
|---|---|---|
| get_current_review | 无 | 当前 Review；没有时为 null |
| list_reviews | 无 | Review 摘要 |
| get_review | review_id | Review 的截图视图；动画通过下列专用工具读取 |
| get_screenshot | screenshot_id，可选 review_id、variant | 元数据及 PNG；variant 为 original/annotated，默认 annotated |
| get_issues | 可选 review_id、screenshot_id | 按截图分组的问题 |
| list_animations | 可选 review_id、limit、cursor | 动画摘要、libraryRevision 与分页信息 |
| get_animation | review_id、animation_id，可选 expected_revision | 动画、问题及素材可用性 |
| get_animation_frame | review_id、animation_id，time 或 issue_id，可选 expected_revision、source、variant、max_dimension | 单帧原图或标注图及实际帧时间 |
| get_animation_frames | review_id、animation_id、issue_id，可选 expected_revision、count、max_dimension | 时间段问题的有限证据帧（2–8 帧） |

省略 review_id 时使用当前 Review。所有 ID 均为 UUID；坐标原点在图片左上角。截图 MCP 单张返回图片上限 25MB，超出时使用文件导出。动画工具另有图像与响应预算；交接时传入保存的 expected_revision，版本变化或素材缺失时先报告，不猜测参数。
App 提供“复制当前素材”和“复制整个 Review”，用户在自己的 Coding Agent 项目会话中粘贴执行。UI Review 不分析或修改项目代码。

## 本地数据

默认存储在 `~/Library/Application Support/UIReview/`：

```text
library.json      # 所有 Review 与当前 Review ID，原子写入
assets/UUID.png   # 不可变 PNG
assets/videos/   # 不可变视频素材
```

App 和 MCP 必须使用相同数据目录。可通过 `--data-dir /absolute/path` 或环境变量 `UI_REVIEW_DATA_DIR` 指定，便于测试隔离。
读取失败时 App 停止写入并显示错误，不用空数据覆盖损坏文件。
删除素材或整个 Review 后，相关资产暂时保留以支持撤销，当前没有自动清理资产的功能。V1 库首次由 App 升级为 V2 前保留原始备份；MCP 只读加载不触发迁移。
数据只保存在本机；配置的 MCP 客户端可以读取这个数据目录中的所有 Review。此 App 不提供 HTTP 服务、云同步或团队协作。

## 测试

```sh
bash scripts/test.sh
```

测试覆盖坐标、保存/加载、损坏数据保护、路径边界、导出、标注图方向、App 编辑撤销及真实 stdio MCP 进程。系统权限弹窗、全局快捷键、外部客户端配置和不同机器的模拟器环境需人工验证。

2.0.3 焦点修复通过 3 项相关测试，包含真实 AppKit 输入框的焦点释放和快捷键输入保护。视频兼容性主要使用合成素材测试，真实设备录屏及完整视觉验收仍需补齐，详见 [V2 冒烟记录](docs/UI_Review_V2_Smoke_Test.md)。

历史截图版本的验证结果与尚未覆盖的环境见 [验证总表](docs/verification.md)，真实界面操作记录见 [冒烟测试](docs/smoke-test-2026-09-05.md)。

需求入口：[PRD V2.0](docs/UI_Review_PRD_V2.0.md)（截图与动画审查整合需求）。历史需求见 [PRD V1.0](docs/UI_Review_PRD_V1.0.md)，交互稿见 [动画设计与原型记录](docs/motion-review-design.md)，已有决策见 [设计决策](docs/design-decisions.md)。

开发设计见 [V2 技术方案](docs/UI_Review_V2_Technical_Design.md)，包含数据迁移、视频帧与框选、MCP 契约、资源预算和开发拆分；附 [动画问题 JSON 示例](docs/examples/motion-issue-v2.json)。

视觉交付见 [V2 视觉设计稿](docs/UI_Review_V2_Visual_Design.md)，包含动画主流程页面、首次 MCP 向导弹窗，以及逐页 Figma 链接。

V2 本机开发版与验证边界见 [开发交付记录](docs/UI_Review_V2_Implementation.md)。使用 `scripts/open-v2-preview.command` 可在独立测试数据目录启动预览。
