# Motion T0 第一轮媒体验证

日期：2026-09-08。状态：合成样本取帧与方向验证通过；T0 尚未全部完成。

## 环境与复现

MacBook Air M4 / 32 GB，macOS 26.6.1，Swift 6.2.4，FFmpeg 8.0.1。FFmpeg 只用于生成测试素材与独立比对，不是 App 运行依赖。

生成与运行入口：`python3 scripts/experiments/run_motion_probe.py`。脚本创建独立临时目录，不读取或修改 UI Review 用户库。实验代码与生产模块隔离。

本次在执行沙箱中访问 macOS 视频解码服务失败（AVFoundation -11821，底层 -12911）；在获得执行授权后，同一程序在沙箱外完成最终验证，退出码 0。该结果不是 UI Review App 沙箱能力测试。

本轮生成脚本执行后，对实验程序和旋转素材做了修正，并在同一素材目录重新编译和运行最终探针；没有再从头重复完整生成脚本。

## 最终通过项

| 合成样本 | 有效帧数 | 精确请求数 | 返回时间最大误差 | 新建生成器 P95 |
| --- | --- | --- | --- | --- |
| 640×360 / 30 fps | 60 | 30 | 0 | 13.58 ms |
| 640×360 / VFR | 60 | 30 | 0 | 13.77 ms |
| 90° 轨道旋转，输出 360×640 | 60 | 30 | 0 | 14.31 ms |
| 1920×1080 / 60 fps / 10 s | 600 | 30 | 0 | 48.88 ms |

每次请求新建 AVURLAsset 和 AVAssetImageGenerator，前后容差为 zero；没有清空系统文件缓存，不可称为冷磁盘耗时。计时仅覆盖 image(at:)，不包含帧索引构建、导入、PNG 输出、MCP 编码或 UI 显示。

- 解码后的帧 PTS 与独立 ffprobe 展示帧索引一致；参考文本小数精度带来的最大差约 0.000000334 s。
- VFR 的实际帧间隔包含 33.333、66.667、100 ms，证明不能用 nominalFrameRate 等间隔推算。
- 真正的旋转样本具有 `[0,-1,1,0,0,0]` 轨道矩阵；输出尺寸交换，四角非对称颜色标记身份与 FFmpeg 自动旋转结果一致。
- 使用非对称矩形对设计中的留白/缩放坐标公式往返计算，误差为 0。这只验证数学公式，不是实际鼠标框选或已实现画布测试。

## 发现及方案修正

1. **压缩样本不能直接当展示帧。** 初版 AVAssetReaderTrackOutput(outputSettings:nil) 在 cfr30 样本得到 64 项而非 60 帧，包含重复/无效 PTS，起始时间还发生偏移。仅排序不够。最终探针改为解码输出，过滤无 imageBuffer 或无效时间项，得到与 ffprobe 一致的展示帧。未在此轮完全归因到具体编辑列表或压缩标记机制。
2. **色彩数值不一致尚未解决。** 两个解码链路的角落 RGB 最大分量差可达 63（8-bit）。最终测试只按红/绿/蓝/黄标记身份判断方向，明确不再把它作为颜色保真测试。正式证据导出需单独验证色彩元数据与转换策略，不能宣称像素一致。
3. **旋转素材也需要验证。** 初始 `rotate=90` 元数据写法没有产生实际轨道矩阵，不能算旋转通过。修正为 FFmpeg display_rotation 输入选项，并在探针中强制检查矩阵后才纳入最终结果。

Apple 说明压缩读取按解码顺序、解码输出按展示顺序；本轮结果支持先使用解码有效样本作为正确性基线。[AVAssetReader 输出设置](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput/outputsettings)

最终精确抽帧采用异步 image(at:)，同时核对返回的 actualTime。[Apple 异步取帧接口](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/image(at:))

## 仍需验证

- 用户真实录屏、macOS 14、HEVC/HDR 拒绝策略、180/270° 与镜像。
- 非零时间原点、复杂 edit list、重复 PTS 的生产拒绝/映射规则。
- 双 AVPlayer 实时同步、stall、取消与过期回调；本轮未启动播放器。
- 索引构建耗时、缓存命中、120 秒/4K 上限、内存与反复切换。
- 实际鼠标自由绘制/移动/缩放，以及区域图经 MCP/导出后的端到端对应关系。
- SDR 色彩一致性；需区分缺失色彩标签、矩阵解释和输出转换差异。

结论：可以继续构建媒体基础模块，但不能把 D0/T0 或完整 PRD 验收标为完成，也不能据本轮提高媒体资源上限。

原始数据：[结果 JSON](test-results/motion-t0-2026-09-08/results.json)、[样本大小与校验值](test-results/motion-t0-2026-09-08/fixtures.json)。素材保留在本次系统临时目录，可通过脚本重新生成；临时文件不保证长期保留。
