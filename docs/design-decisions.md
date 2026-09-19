# UI Review V1 — 设计决策

## 已确认

- macOS 原生应用：SwiftUI + AppKit。
- 交付 PRD 全部 P0，分阶段实现和验收。
- Current Review 自动保存，重启恢复；手动开始新的 Review，保留历史并允许重新编辑。
- 用户在 Codex / Claude Code 中主动读取 Review；App 提供只读 MCP、配置说明及交接提示词。
- 开发前先通过 Figma MCP 制作设计稿并评审。
- 已确认 Figma 初稿的三栏布局和浅色/深色视觉方向。
- 首版先交付本机运行的 App，暂不进行对外签名、公证、分发。
- 独立只读 stdio MCP 进程按需启动；App 退出后仍能读取保存数据。
- 撤销支持当前运行内的截图/问题/Review 删除、Review 切换、矩形调整与评论编辑；重启不恢复撤销历史。
- 首版一次导出完整文件夹，包括 Markdown、JSON、原图和标注图。

## Figma 初稿

文件：https://www.figma.com/design/HXkzr0N4y3qGg4rryDdTaC

- `1:2`：浅色标注编辑器，1280 × 820。
- `1:81`：首次打开与导入空状态，1280 × 820。
- `1:113`：深色标注编辑器，1280 × 820。

设计采用三栏结构：232px 截图栏、728px 画布、320px 问题栏。
稿内手机设置页是用于展示标注行为的虚构示例，并非真实导入截图。
当前交付是可编辑的视觉初稿，尚未配置可点击原型。

## 环境限制

macOS 26 组件库检索成功，但导入报 `Not permitted to upsert from library`。
因此初稿使用本地绘制的图层，不宣称已绑定远程组件库。
SF Pro 在 MCP 截图中未正常显示，设计稿改用 Noto Sans SC；原生应用仍应使用系统字体。

## V1 实现选择

- 最低 macOS 14，SwiftUI + AppKit，Swift Package，无第三方依赖。
- 系统选区截图使用 screencapture，全局快捷键 ⌃⌥⌘S。
- 模拟器截图列出已启动的 iOS 设备并由用户选择，不自动启动或重置设备。
- 空评论保留为待填写问题；最小矩形为 2 × 2 原图像素。
- 坐标以标准化方向的 PNG 原图左上角为原点；归一化坐标随矩形一起保存。
- 本地 JSON 原子写入，图片资产不可变；删除资产暂时保留以支持撤销。
- 首版有编辑器、空状态、历史记录、模拟器选择、Agent 集成说明。
- 历史记录双击整行打开，单击不切换；右键删除后可撤销。删除当前 Review 后返回空白工作区，不自动打开其他记录。
- 历史空状态使用固定顶部标题栏与居中提示，支持返回工作区及 Esc 关闭。
- Agent 面板支持 Codex / Claude Code 一键安装和状态检测；仅点击安装时写入客户端配置，修改前备份，遇到同名冲突不覆盖。

## 首次向导（2026-09-17）

- 首次打开空工作区时弹出三步向导弹窗：说明 → 安装 Codex / Claude Code / Cursor → 结果。可跳过。
- 主路径只引导安装 MCP；导入素材和复制交接提示词不进入向导。

## 交接工具栏（已锁定）

- 工具栏三个按钮始终显示，顺序为导出 Review、复制整个 Review、复制当前素材（现有 142×32 蓝钮）。
- 不再弹出 Handoff 预览，也不再按有无动画分叉交互。
- 两个复制直接写剪贴板；导出永远整份当前 Review，不含历史。
- 跳过或完成后不再自动弹出。「MCP · 只读访问」再次打开向导并停在安装步；菜单「Agent 集成…」仍打开完整设置面板。
- 未安装也可进入结果页。向导不新增写入范围，安装逻辑复用现有 Agent 安装与检测。
- Figma： [交互原型](https://www.figma.com/proto/HXkzr0N4y3qGg4rryDdTaC?node-id=85-36&starting-point-node-id=85%3A36)，[视觉稿](https://www.figma.com/design/HXkzr0N4y3qGg4rryDdTaC?node-id=86-124)。尚未实现。
- App 使用蓝色“框选 + 评论气泡”图标，PNG 源文件位于 `Resources/AppIcon/`，通过 `scripts/build-icon.sh` 生成 ICNS，由构建脚本装入 App 包。
