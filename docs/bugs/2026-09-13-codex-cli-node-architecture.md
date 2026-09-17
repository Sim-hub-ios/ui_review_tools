---
date: 2026-09-13
mode: 前台
related_files:
  - Sources/UIReview/AgentIntegration.swift
---

## Bug 分析

### 问题描述
Codex 状态检测显示“命令未完成（退出码 1）”。已修复并安装验证；客户端配置未修改。

### Bug 路径追踪
1. AgentIntegration.swift:253：refresh 发起检测，调用 check。
2. AgentIntegration.swift:179 → 85：findCLI 按 PATH 优先找到 /opt/homebrew/bin/codex，桌面 App 内置二进制排在最后。
3. AgentIntegration.swift:99：运行 mcp list --json；npm 启动器通过 PATH 使用 /usr/local/bin/node（x64）。
4. 启动器因缺少 @openai/codex-darwin-x64 退出 1，尚未读取 MCP 配置。
5. AgentIntegration.swift:48 丢弃 stderr，界面只显示退出码。

### 根本原因
UI Review 实际进程 PATH 中 /usr/local/bin 优先于 /opt/homebrew/bin，分别对应 x64 和 arm64 Node。Codex npm 启动器在 Intel Node 下寻找未安装的 x64 平台依赖。候选查找仅检查可执行权限，没有保证该 CLI 能启动。

### 证据
- 使用 UI Review 实际 PATH 复现 mcp list --json：退出 1，Missing optional dependency @openai/codex-darwin-x64。
- /usr/local/bin/node 报告 x64；/opt/homebrew/bin/node 报告 arm64。
- 改用以 /opt/homebrew/bin 优先于 /usr/local/bin 的精简环境，相同 npm CLI 退出 0。
- /Applications/ChatGPT.app/Contents/Resources/codex 版本 0.153.4，mcp list --json 退出 0；ui-review 配置已启用，指向当前已安装 App 和原数据目录。

### 解决方案
#### 方案一：UI Review 优先使用桌面 App 内置 CLI（推荐）
做法：调整 findCLI 的 Codex 候选顺序，优先桌面 App 内置二进制，没有桌面版时保留 PATH 回退；补充候选优先级回归测试并重新安装验证。
- 优点：绕开 Node 架构及 PATH 差异，改动局限于 UI Review。
- 缺点：同时安装多个版本时，检测默认使用桌面版而非用户 PATH 中的版本；需重打包。
- 改动范围：AgentIntegration.swift、AgentIntegrationTests.swift。

#### 方案二：调整启动 UI Review 的 PATH
做法：确保 /opt/homebrew/bin 在 /usr/local/bin 前，再退出并重新启动 UI Review。
- 优点：无需修改 App，当前环境已验证可用。
- 缺点：启动环境变化后可能复发；全局调整 PATH 还可能影响其他工具。

### 推荐理由
桌面 App 内置 CLI 已在本机验证能读取现有配置，优先使用它可在应用自身解决问题，避免改变其他开发工具的环境。无需删除或重新创建 MCP 配置。

### 修复与验证结果
- findCLI 调整为桌面 App 内置 Codex 优先，保留 PATH 回退；README 已同步说明。
- 新增回归测试，修复前捕获错误 PATH 选择并失败；修复后 16 项 AgentIntegrationTests 全部通过，无跳过。
- Release 构建成功，签名校验通过，安装副本与构建产物 SHA-256 一致。
- 已保存现有 Review、退出旧版并安装至 /Applications/UI Review.app。
- 实际界面显示 Codex “已安装”，状态为“配置已安装 · 截图和动画读取可用。请在客户端重新连接。”
- 未提交或推送代码。
