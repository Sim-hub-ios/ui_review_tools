# UI Review 产品需求文档 PRD V1.0

## 1. 产品定位

UI Review 是一款面向开发者的 macOS 视觉 UI Issue 标注工具。

核心流程：

截图 → 框选问题区域 → 输入修改要求 → 将结构化视觉上下文交给 Coding
Agent。

产品负责整理视觉问题，不负责： - 分析代码 - 定位代码 -
生成代码修改方案 - 修改项目代码

这些工作交给 Codex、Claude Code 等 Coding Agent。

核心体验：

> 截一下 → 框一下 → 说一句 → 交给 Agent

------------------------------------------------------------------------

## 2. 核心产品模型

产品核心对象：

Review → Screenshot → Issue

一个 Issue：

-   一个 Rectangle
-   一个 Comment

自动记录：

-   x / y / width / height
-   normalized region
-   用户评论

原则：

> 图片负责表达 Where，Comment 负责表达 What。

------------------------------------------------------------------------

## 3. 截图入口

V1 支持：

-   Mac 快捷键截图
-   ⌘V 剪贴板图片导入
-   Drag & Drop / 文件导入
-   iOS Simulator Capture

截图后直接进入 Annotation Editor。

------------------------------------------------------------------------

## 4. Annotation Editor

采用三栏布局：

-   左侧：Screenshot 列表
-   中间：Canvas
-   右侧：Issue Panel

支持：

-   Rectangle 创建
-   Move
-   Resize
-   Delete
-   Comment 编辑
-   Undo / Redo

------------------------------------------------------------------------

## 5. Review 工作流

采用 Current Review 自动 Session。

用户无需主动创建 Review。

第一次：

-   截图
-   粘贴图片
-   导入图片
-   Simulator Capture

自动创建 Current Review。

一个 Review 支持：

-   多个 Screenshot
-   每个 Screenshot 多个 Issue

------------------------------------------------------------------------

## 6. MCP Integration

MCP 是主要 Agent 集成方式。

MCP Server：

-   只读
-   不修改 Review 数据

支持：

-   get_current_review()
-   list_reviews()
-   get_review()
-   get_screenshot()
-   get_issues()

Codex / Claude Code 通过 MCP 获取：

-   Screenshot
-   Annotated Screenshot
-   Issue
-   Comment
-   Region

------------------------------------------------------------------------

## 7. Export

支持：

-   review.md
-   review.json
-   Original Screenshot
-   Annotated Screenshot

导出结构：

``` text
review/
├── review.md
├── review.json
└── screenshots/
    ├── screenshot-01.png
    └── screenshot-01-annotated.png
```

------------------------------------------------------------------------

## 8. MVP 范围

### P0

-   Mac Screenshot
-   Clipboard Paste
-   Drag & Drop
-   File Import
-   iOS Simulator Capture
-   Current Review
-   Screenshot 管理
-   Rectangle Issue
-   Comment
-   Issue Panel
-   Undo / Redo
-   MCP Server
-   review.md Export

### 不做

-   AI 自动识别 UI Bug
-   AI 自动生成 Issue
-   AI 自动写代码
-   项目目录绑定
-   云同步
-   团队协作
-   Visual Diff

------------------------------------------------------------------------

## 9. 产品目标

UI Review 的目标：

成为开发者和 AI Coding Agent 之间的视觉沟通层。

完整流程：

发现 UI 问题

↓

截图

↓

框选

↓

描述

↓

Review

↓

MCP

↓

Coding Agent
