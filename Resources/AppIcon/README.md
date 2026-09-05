# UI Review App Icon

蓝色主版来自 Figma 节点 20:5：
https://www.figma.com/design/HXkzr0N4y3qGg4rryDdTaC?node-id=20-5

`AppIcon-1024.png` 为带透明边距的 1024px 原图。
更新原图后，在 macOS 上运行 `bash scripts/build-icon.sh` 生成
`Resources/AppIcon.icns`，包含标准和 Retina 尺寸。
`scripts/build-app.sh` 会将 ICNS 复制到 App 包并签名。
