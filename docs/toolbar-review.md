# 顶部工具栏 Review 修复

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
- 用户主 App 未重启，原 Review 与撤销历史未改动。重新打开 build/UI Review.app 后加载新版。

[测试日志](test-results/toolbar-review/tests.log) · [构建日志](test-results/toolbar-review/build.log)
