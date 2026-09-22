import Foundation

extension ReviewRepository {
  public func assetURL(for asset: VideoAsset) throws -> URL {
    guard ["mp4", "mov"].contains(asset.container),
      asset.path == "assets/videos/\(asset.id.uuidString).\(asset.container)"
    else {
      throw ReviewError.invalidData("视频路径不合法。")
    }
    let url = root.appendingPathComponent(asset.path).resolvingSymlinksInPath()
    let base = root.resolvingSymlinksInPath().appendingPathComponent("assets/videos").path + "/"
    guard url.path.hasPrefix(base) else { throw ReviewError.invalidData("视频路径超出数据目录。") }
    return url
  }
  func validateMotion(_ review: Review) throws {
    func require(_ valid: Bool, _ message: String) throws {
      if !valid { throw ReviewError.invalidData(message) }
    }
    let items =
      review.screenshots.map { ReviewItem(kind: .screenshot, id: $0.id) }
      + review.animations.map { ReviewItem(kind: .animation, id: $0.id) }
    try require(
      Set(review.itemOrder) == Set(items) && review.itemOrder.count == items.count, "素材顺序不完整或重复。")
    try require(Set(review.animations.map(\.id)).count == review.animations.count, "动画 ID 重复。")
    try require(Set(review.videoAssets.map(\.id)).count == review.videoAssets.count, "视频资产 ID 重复。")
    for a in review.videoAssets {
      _ = try assetURL(for: a)
      try require(
        a.duration.isValid && a.duration > .zero && a.duration.seconds <= 120
          && a.timelineOrigin.isValid, "视频时长无效或超过 120 秒。")
      try require(a.byteLength > 0 && a.byteLength <= 500_000_000, "视频文件超过 500 MB。")
      try require(
        a.displayWidth > 0 && a.displayHeight > 0 && max(a.displayWidth, a.displayHeight) <= 4096
          && a.encodedWidth > 0 && a.encodedHeight > 0, "视频尺寸无效。")
      try require(a.sha256.count == 64 && a.sha256.allSatisfy { $0.isHexDigit }, "视频摘要无效。")
      try require(
        ["h264", "hevc"].contains(a.codec) && a.colorPolicy == "sdr-srgb-v1", "视频格式不受支持。")
      let t = a.preferredTransform
      try require([t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite), "视频方向无效。")
      if let fps = a.nominalFrameRate { try require(fps.isFinite && fps >= 0, "视频帧率无效。") }
    }
    for animation in review.animations {
      guard let current = review.videoAssets.first(where: { $0.id == animation.currentAssetID })
      else { throw ReviewError.invalidData("动画缺少当前视频。") }
      if let referenceAssetID = animation.referenceAssetID,
        review.videoAssets.contains(where: { $0.id == referenceAssetID }) == false
      {
        throw ReviewError.invalidData("参考视频不存在。")
      }
      if let active = animation.activeReference, let referenceAssetID = animation.referenceAssetID,
        active.referenceAssetID != referenceAssetID
      {
        throw ReviewError.invalidData("参考视频不存在。")
      }
      func alignment(_ relation: ReferenceAlignment?) throws {
        guard let relation else { return }
        guard let ref = review.videoAssets.first(where: { $0.id == relation.referenceAssetID })
        else { throw ReviewError.invalidData("参考视频不存在。") }
        try require(
          relation.currentStart.isValid && relation.referenceStart.isValid
            && relation.currentStart >= .zero && relation.currentStart < current.duration
            && relation.referenceStart >= .zero && relation.referenceStart < ref.duration,
          "对齐起点超出视频。")
      }
      try alignment(animation.activeReference)
      try require(Set(animation.issues.map(\.id)).count == animation.issues.count, "动画问题 ID 重复。")
      for issue in animation.issues {
        try issue.target.validate(duration: current.duration)
        try alignment(issue.referenceSnapshot)
        if let c = issue.category {
          try require(
            ["position", "scale", "opacity", "timing", "delay", "other"].contains(c), "问题分类无效。")
        }
        guard let r = issue.region else { continue }
        try require(
          r.assetID == current.id && r.actualTime.isValid && issue.target.contains(r.actualTime),
          "标注帧不属于该问题。")
        try require(
          r.frameWidth == current.displayWidth && r.frameHeight == current.displayHeight,
          "标注帧尺寸不一致。")
        let p = r.pixelRect
        try require(
          p.isValid && p.width >= 2 && p.height >= 2 && p.x + p.width <= Double(r.frameWidth)
            && p.y + p.height <= Double(r.frameHeight), "区域超出标注帧。")
        let n = p.normalized(width: r.frameWidth, height: r.frameHeight)
        let actual = r.normalizedRect
        try require(
          zip([n.x, n.y, n.width, n.height], [actual.x, actual.y, actual.width, actual.height])
            .allSatisfy { abs($0 - $1) < 0.000001 }, "区域归一化坐标不一致。")
      }
    }
  }
}
