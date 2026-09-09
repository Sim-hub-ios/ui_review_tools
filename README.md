# UI Review

面向开发者的原生 macOS UI 问题标注工具。

截图 → 框选 → 评论 → 通过只读 MCP 或文件导出交给 Coding Agent。

## 构建与运行

需要 macOS 14+、Xcode 16+（已选择 Command Line Tools）。当前工程使用 Swift Package，无第三方依赖。

```sh
bash scripts/build-app.sh
open 'build/UI Review.app'
```

发布优化构建：`bash scripts/build-app.sh release`。构建产物采用本机 ad-hoc 签名，尚未公证，也不是可对外分发的安装包。可用 Xcode 打开 `Package.swift` 开发。

## 使用

- **导入**：⌘O、⌘V、拖放图片，支持 PNG/JPEG/HEIC/TIFF/WebP（上限 100MB、4000 万像素；多帧图片取第一帧）。图片统一转换为正向 PNG，坐标使用转换后的原图像素。
- **系统截图**：工具栏或全局快捷键 **⌃⌥⌘S**，拖选区域，Esc 取消。首次需授予 macOS 屏幕录制权限。App 关闭窗口后仍在运行，全局快捷键仍可用。
- **模拟器**：工具栏选择已启动的 iOS Simulator；未启动时提供打开 Simulator 的入口。不会自动重置或改变设备。
- **删除截图**：⌘Delete 删除当前选中截图及其问题，⌘Z 可撤销；输入框内保留文字编辑行为，长按不会连续删除多张。
- **标注**：主编辑窗口内 R 切换框选，V 切换选择（无需先点击画布，输入文字或弹窗中不触发）。拖动矩形移动，拖动四角缩放，Delete 删除。右侧编辑评论自动保存。空评论作为待填写的问题保留。
- **缩放**：适合窗口或 25%–200%，固定倍率下支持双向滚动。
- **管理**：左侧右键重命名/删除截图。标题栏可编辑 Review 名称。“开始新的 Review”保留旧记录，在下一次导入时自动创建新 Review。
- **历史 Review**：从侧栏或 Review 菜单打开；双击整行切换并关闭历史窗口，单击不会切换。右键可删除 Review；删除当前记录后返回空白工作区，⌘Z 可撤销。空列表可点击“返回工作区”，Esc 关闭历史窗口。
- **撤销**：⌘Z / ⇧⌘Z，包含导入、删除、矩形、评论和 Review 切换。相邻评论输入合并，最多保留 80 次操作。重启保留内容，不保留撤销历史。
- **导出**：工具栏选择父目录，一次生成 review.md、review.json、原图、标注图。不覆盖已有目录。

## MCP

在 App 的“连接 Coding Agent”中，可分别点击 Codex / Claude Code 的“一键安装”。打开面板会自动检测；安装后会核对配置并完成本机 MCP 握手及五个只读工具检查。绿色状态表示配置和服务可用，客户端仍需重新连接或开启新会话。

- 需要已安装相应客户端命令行工具；会搜索常见 Homebrew / `.local/bin` 路径，以及 Codex 桌面包内的 CLI。
- Codex 使用官方 `mcp add`；Claude Code 合并当前用户的 `.claude.json`（支持 `CLAUDE_CONFIG_DIR`），保留其他 JSON 字段及文件权限。
- 修改前备份已有配置，备份位于原文件旁，扩展名为 `ui-review-backup-UUID`。相同配置重复安装不会重写；不同的同名配置或禁用状态会提示冲突，需先在客户端处理。
- Claude 的项目配置可能覆盖用户配置；这里不修改项目配置。安装前请将 App 放在固定位置，移动后需要重新配置路径。
- “手动配置”中仍可复制 TOML / JSON。检测不会启动模型请求，不代表当前 Agent 会话已经调用过工具。

App 菜单 **Review → Agent 集成** 打开同一安装与检测面板；只有点击“一键安装”才修改对应客户端配置，检测与复制配置不会修改客户端配置。
App 退出后，客户端仍可以按需启动包内 `ui-review-mcp`。

Codex 配置示例（替换成实际绝对路径）：

```toml
[mcp_servers.ui-review]
command = "/absolute/path/UI Review.app/Contents/MacOS/ui-review-mcp"
```

Claude Code / 支持 JSON 的 MCP 客户端配置：

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
| get_review | review_id | 完整 Review |
| get_screenshot | screenshot_id，可选 review_id、variant | 元数据及 PNG；variant 为 original/annotated，默认 annotated |
| get_issues | 可选 review_id、screenshot_id | 按截图分组的问题 |

省略 review_id 时使用当前 Review。所有 ID 均为 UUID；坐标原点在图片左上角。MCP 单张返回图片上限 25MB，超出时使用文件导出。
App 提供“复制交接提示词”，用户在自己的 Coding Agent 项目会话中粘贴执行。UI Review 不分析或修改项目代码。

## 本地数据

默认存储在 `~/Library/Application Support/UIReview/`：

```text
library.json      # 所有 Review 与当前 Review ID，原子写入
assets/UUID.png   # 不可变 PNG
```

App 和 MCP 必须使用相同数据目录。可通过 `--data-dir /absolute/path` 或环境变量 `UI_REVIEW_DATA_DIR` 指定，便于测试隔离。
读取失败时 App 停止写入并显示错误，不用空数据覆盖损坏文件。
删除截图或整个 Review 后，相关图片资产暂时保留以支持撤销；V1 没有自动清理资产的功能。
数据只保存在本机；配置的 MCP 客户端可以读取这个数据目录中的所有 Review。此 App 不提供 HTTP 服务、云同步或团队协作。

## 测试

```sh
bash scripts/test.sh
```

测试覆盖坐标、保存/加载、损坏数据保护、路径边界、导出、标注图方向、App 编辑撤销及真实 stdio MCP 进程。系统权限弹窗、全局快捷键、外部客户端配置和不同机器的模拟器环境需人工验证。

当前验证结果与尚未覆盖的环境见 [验证总表](docs/verification.md)，真实界面操作记录见 [冒烟测试](docs/smoke-test-2026-09-05.md)。

需求入口：[PRD V2.0](docs/UI_Review_PRD_V2.0.md)（截图与动画审查整合需求）。历史需求见 [PRD V1.0](docs/UI_Review_PRD_V1.0.md)，交互稿见 [动画设计与原型记录](docs/motion-review-design.md)，已有决策见 [设计决策](docs/design-decisions.md)。

开发设计见 [V2 技术方案](docs/UI_Review_V2_Technical_Design.md)，包含数据迁移、视频帧与框选、MCP 契约、资源预算和开发拆分；附 [动画问题 JSON 示例](docs/examples/motion-issue-v2.json)。

视觉交付见 [V2 视觉设计稿](docs/UI_Review_V2_Visual_Design.md)，包含七张流程/空状态页面、主要异常状态和视觉规范，以及逐页 Figma 链接。

V2 本机开发版与验证边界见 [开发交付记录](docs/UI_Review_V2_Implementation.md)。使用 `scripts/open-v2-preview.command` 可在独立测试数据目录启动预览。
