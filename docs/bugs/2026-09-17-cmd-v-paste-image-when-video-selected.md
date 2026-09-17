---
date: 2026-09-17
mode: 前台
related_files:
  - Sources/UIReview/UIReviewApp.swift
  - Sources/UIReview/MotionWorkspace.swift
  - Sources/UIReview/MotionStore.swift
  - Sources/UIReview/MotionPlayerView.swift
  - Sources/UIReview/ReviewStore.swift
  - Sources/UIReview/AnnotationCanvas.swift
---

## Bug 分析

### 问题描述
当前 Review 的第一项（或当前选中项）是视频时，复制图片后按 ⌘V，不会导入为截图。

### Bug 路径追踪

1. **触发点：** `Sources/UIReview/UIReviewApp.swift:92-105` — 用户在视频工作区按下 ⌘V。AppDelegate 的本地按键监视拦截该快捷键。
2. **传递过程：** `UIReviewApp.swift:98-101` → `MotionWorkspace.swift:227` 或 `MotionWorkspace.swift:54` — 视频暂停时 `MotionCanvas` 复用 `CanvasView`，点击画面后 firstResponder 是 `CanvasView`；播放时 firstResponder 是 `MotionPlayerSurface`。两者的 `onPaste` 都被写成 `store.pasteReferenceVideo()`。
3. **出错位置：** `Sources/UIReview/MotionStore.swift:85-98` — `pasteReferenceVideo()` 只接受恰好一个 MP4/MOV 文件 URL。剪贴板是图片时走失败分支，状态变成「请先复制一个 MP4 或 MOV 视频文件。」，`pasteImage()` 从未被调用。

对照路径：空 Review 或当前选中截图时，⌘V 会落到 `store.pasteImage()`（`ReviewStore.swift:322`），图片能正常导入。菜单「粘贴图片」（⇧⌘V）也始终走 `pasteImage()`，所以问题只出现在「选中视频 + ⌘V」。

### 根本原因
动画画布把 ⌘V 硬绑成「粘贴参考视频」，且不看剪贴板内容。`MotionCanvas` 又复用了截图画布的 `CanvasView`，AppDelegate 按 `CanvasView` 类型把粘贴交给视图自己的 `onPaste`，于是图片粘贴被参考视频导入完全挡住。

### 解决方案

#### 方案一：按剪贴板内容分发粘贴 ✅ 推荐
**做法：** 抽出统一的 `pasteClipboard()`（或在现有 `pasteImage` / `pasteReferenceVideo` 之上做分发）：
1. 剪贴板有图片数据（PNG/TIFF）或图片文件 → `pasteImage()`，导入为截图并选中。
2. 否则，当前选中动画且剪贴板恰好有一个 MP4/MOV → `pasteReferenceVideo()`。
3. 否则沿用现有失败提示。
AppDelegate、`CanvasView.onPaste`、`MotionPlayerSurface.onPaste` 都改走这一入口。
- 优点：贴什么就导入什么；视频画布上粘贴参考视频的能力仍在；改动集中、可单测。
- 缺点：粘贴分发逻辑要从「看焦点」改成「先看剪贴板」。
- 改动范围：`ReviewStore.swift` / `MotionStore.swift`、`UIReviewApp.swift`、`MotionWorkspace.swift`，以及粘贴分发测试。
- 屏幕适配：无布局影响，窄屏/宽屏行为一致。

#### 方案二：参考视频粘贴失败后回退到 `pasteImage()`
**做法：** 在 `pasteReferenceVideo()` 找不到视频文件时调用 `pasteImage()`，而不是直接报「请先复制一个 MP4 或 MOV」。
- 优点：改动最小，能覆盖本 bug。
- 缺点：失败提示可能错位（既不是视频也不是图片时，会显示「剪贴板中没有图片」）；分发规则仍藏在参考视频函数里，后续难扩展。
- 改动范围：主要是 `MotionStore.swift`。
- 屏幕适配：无布局影响。

#### 方案三：⌘V 永远粘贴图片，参考视频只用按钮/文件选择
**做法：** 动画画布和播放器的 `onPaste` 改为 `pasteImage()`；参考视频只走「添加参考视频」。
- 优点：与 V1 PRD「⌘V 导入剪贴板图片」完全一致，心智负担最低。
- 缺点：失去在视频画布 ⌘V 粘贴参考视频的能力。
- 改动范围：`MotionWorkspace.swift`、相关测试。
- 屏幕适配：无布局影响。

### 推荐理由
方案一同时保住两条真实工作流：先导入录屏再贴截图（本次 bug），以及在当前动画上贴一个参考视频。内容分发比焦点分发更符合「复制了什么就粘贴什么」，也不用牺牲已有参考视频快捷键。
