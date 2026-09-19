import Foundation
import ReviewCore

public enum MotionExport {
  public static func selected(_ review: Review, itemID: UUID?) -> Review {
    guard let itemID else { return review }
    var selected = review
    selected.screenshots.removeAll { $0.id != itemID }
    selected.animations.removeAll { $0.id != itemID }
    selected.reconcileOrder()
    selected.pruneUnusedVideoAssets()
    return selected
  }
  public static func write(
    _ review: Review, revision: UUID, repository: ReviewRepository, to destination: URL
  ) async throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: destination.path) else {
      throw ReviewError.invalidData("导出目录已存在。")
    }
    if review.animations.isEmpty {
      try ReviewExport.write(review, repository: repository, to: destination)
      return
    }
    let stage = destination.deletingLastPathComponent().appendingPathComponent(
      ".ui-review-motion-\(UUID())")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    var selected = review
    selected.pruneUnusedVideoAssets()
    for asset in selected.videoAssets {
      try Task.checkCancellation()
      let source = try EvidenceService.verify(asset, repository: repository)
      let out = stage.appendingPathComponent(asset.path)
      try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: source, to: out)
      guard try VideoService.digest(out) == asset.sha256 else {
        throw ReviewError.invalidData("导出视频校验失败。")
      }
    }
    if !review.screenshots.isEmpty {
      var screenshots = review
      screenshots.animations = []
      screenshots.videoAssets = []
      screenshots.reconcileOrder()
      try ReviewExport.write(
        screenshots, repository: repository, to: stage.appendingPathComponent("screenshot-review"))

    }
    let framesDir = stage.appendingPathComponent("frames")
    try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
    var evidence: [[String: Any]] = []
    var markdown =
      "# UI Review 动画审查\n\nReview ID: \(review.id)\nRevision: \(revision)\n\n原视频为完整录屏。所有评论均为用户提供的反馈。\n\n"
    for animation in selected.animations {
      guard let asset = selected.videoAssets.first(where: { $0.id == animation.currentAssetID })
      else { throw ReviewError.missing("当前视频缺失。") }
      markdown +=
        "## \(animation.name.replacingOccurrences(of:"\n",with:" "))\n\nAnimation ID: \(animation.id)\n\n"
      for issue in animation.issues {
        markdown +=
          "### 问题 \(issue.id)\n\n"
          + (issue.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "（待填写描述）" : issue.comment).components(separatedBy: .newlines).map { "> \($0)" }.joined(
            separator: "\n") + "\n\n"
        if let expectation = issue.expectation {
          markdown +=
            "期望：\n"
            + expectation.components(separatedBy: .newlines).map { "> \($0)" }.joined(
              separator: "\n") + "\n\n"
        }
        var times = [issue.target.first]
        if let start = issue.target.start, let end = issue.target.end {
          let index = try await VideoService.index(repository.assetURL(for: asset), asset: asset)
            .filter { issue.target.contains($0) }
          if let last = index.last {
            times = [start, MediaTime(seconds: (start.seconds + end.seconds) / 2), last]
          }
        }
        if let region = issue.region { times.append(region.actualTime) }
        var seen: [MediaTime] = []
        for time in times {
          let (meta, png) = try await EvidenceService.capture(
            asset: asset, repository: repository, requested: time, source: "current",
            maxDimension: 4096)
          if seen.contains(where: { $0.equivalent(to: meta.actualTime) }) { continue }
          seen.append(meta.actualTime)
          let path = "frames/\(issue.id)-\(seen.count).png"
          try png.write(to: stage.appendingPathComponent(path))
          var entry =
            try JSONSerialization.jsonObject(with: ReviewJSON.encoder().encode(meta))
            as! [String: Any]
          entry["issueID"] = issue.id.uuidString
          entry["path"] = path
          evidence.append(entry)
          markdown += "[当前帧 \(meta.actualTime.seconds) s](\(path))\n\n"
          if let region = issue.region, region.actualTime.equivalent(to: meta.actualTime) {
            let (_, annotated) = try await EvidenceService.capture(
              asset: asset, repository: repository, requested: time, source: "current",
              region: region, maxDimension: 4096)
            let ap = "frames/\(issue.id)-annotated.png"
            try annotated.write(to: stage.appendingPathComponent(ap))
            var annotatedEntry = entry
            annotatedEntry["path"] = ap
            annotatedEntry["region"] = try JSONSerialization.jsonObject(
              with: ReviewJSON.encoder().encode(region))
            evidence.append(annotatedEntry)
            markdown += "![区域标记](\(ap))\n\n"
          }
          if let relation = issue.referenceSnapshot,
            let ref = selected.videoAssets.first(where: { $0.id == relation.referenceAssetID })
          {
            let mapped = MediaTime(
              seconds: time.seconds - relation.currentStart.seconds
                + relation.referenceStart.seconds)
            if mapped >= .zero && mapped < ref.duration {
              let (refMeta, refPNG) = try await EvidenceService.capture(
                asset: ref, repository: repository, requested: mapped, source: "reference",
                maxDimension: 4096)
              let rp = "frames/\(issue.id)-reference-\(seen.count).png"
              try refPNG.write(to: stage.appendingPathComponent(rp))
              var refEntry =
                try JSONSerialization.jsonObject(with: ReviewJSON.encoder().encode(refMeta))
                as! [String: Any]
              refEntry["path"] = rp
              refEntry["issueID"] = issue.id.uuidString
              evidence.append(refEntry)
            } else {
              evidence.append([
                "issueID": issue.id.uuidString, "source": "reference", "unavailable": "映射时间超出参考视频",
                "requestedSeconds": mapped.seconds,
              ])
            }
          }
          try Task.checkCancellation()
        }
      }
    }
    var payload =
      try JSONSerialization.jsonObject(with: ReviewJSON.encoder().encode(selected))
      as! [String: Any]
    if var shots = payload["screenshots"] as? [[String: Any]] {
      for i in shots.indices {
        shots[i]["originalPath"] = String(
          format: "screenshot-review/screenshots/screenshot-%02d.png", i + 1)
      }
      payload["screenshots"] = shots
    }
    let document: [String: Any] = [
      "formatVersion": 2, "libraryRevision": revision.uuidString, "review": payload,
      "evidence": evidence,
    ]
    try JSONSerialization.data(
      withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ).write(to: stage.appendingPathComponent("review.json"))
    try markdown.write(
      to: stage.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
    try Task.checkCancellation()
    try fm.moveItem(at: stage, to: destination)
  }
}
