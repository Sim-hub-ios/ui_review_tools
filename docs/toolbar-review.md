# 顶部工具栏 Review 修复

历史修复记录：2026-09-05，适用于 V1 开发版（1.0.0，build 1）。下文保留当时的设计修复、缓存回归修复与验证结果；这些修复已纳入 V1，后续 V2 已更新部分按钮与交接流程。

当前工具栏入口为“截取屏幕”“模拟器截图”“导入素材”“导出 Review”“复制整个 Review”“复制当前素材”；复制入口直接生成交接内容。Review 名称旁菜单仍提供历史记录与新建操作。实现见 [ReviewToolbar.swift](../Sources/UIReview/ReviewToolbar.swift)，用法见 [README](../README.md)。下文的蓝色“交接按钮”与打包路径说明属于当时上下文。

- Review：AE6C2F41-01C5-4A31-ABDE-F95377C508D1
- 截图：854C50EA-2536-4964-ACD9-F2990E5D820E，2940 × 1846
- 问题：22865256-2465-49E8-8A09-0E34073B02FC，“这一块的实现效果和设计稿不一样。”
- 区域：原图左上角 x=23.34、y=14.46、w=2899.54、h=101.16，对应整个顶部工具栏。
- 设计：[Figma 深色编辑器](https://www.figma.com/design/HXkzr0N4y3qGg4rryDdTaC?node-id=1-113)，工具栏节点 1:114。

## 修改

将系统自动排列的图标工具栏替换为固定 64pt 高的顶部栏：左侧 UI Review 和可编辑 Review 名称，右侧文字操作按钮，以及 142 × 32pt、圆角 8pt 的蓝色交接按钮。深色背景 #292C32、文字 #E9EDF4、强调色 #76A5FF。名称区域随窗口宽度收缩，操作文字保持完整。保留原来的业务方法和禁用条件。

使用 AppKit 标准样式窗口按钮和 NSWindow 操作，提供关闭、最小化、全屏与空白区拖动。Review 名称旁菜单提供已有的历史记录与新建操作。

隔离运行时发现多截图冷启动崩溃：缩略图缓存写入发生在 SwiftUI body 计算中，触发 Observation 图更新。缓存改为 @ObservationIgnored；Review 数据的观察和持久化不变。加入回归测试验证缓存填充不触发视图观察失效。

## 验证

- 23 项 XCTest、17 次真实 MCP JSON-RPC 请求通过，Release 构建成功。
- 隔离副本使用测试数据，与用户 Review 分开；已查看实际深色窗口，对照 Figma 工具栏。
- 1000pt 窄窗口下文字完整；全屏进入/退出正常；Review 菜单能打开历史弹窗。
- 关闭按钮发出操作后桌面工具重新呈现窗口，未能独立确认关闭结果；最小化与拖动窗口未在本轮单独验收。
- 当时用户主 App 未重启，原 Review 与撤销历史未改动；需重新打开当时的 `build/UI Review.app` 才能加载该轮新版。

[测试日志](test-results/toolbar-review/tests.log) · [构建日志](test-results/toolbar-review/build.log)

这些日志是已被 Git 忽略的本机历史证据，仓库不附带；2026-10-13 仅校订文档，未重新执行上述测试。
