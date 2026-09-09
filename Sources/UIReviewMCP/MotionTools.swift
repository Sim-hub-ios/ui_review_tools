import CoreFoundation
import Foundation
import ReviewCore
import ReviewMedia

let motionDefinitions: [(String, String, [String: Any], [String])] = [
  (
    "list_animations", "列出动画与问题数量；通过 get_animation 获取详情。",
    [
      "review_id": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 100],
      "cursor": ["type": "string"],
    ], []
  ),
  (
    "get_animation", "读取动画、视频元数据、问题与参考快照。",
    [
      "review_id": ["type": "string"], "animation_id": ["type": "string"],
      "expected_revision": ["type": "string"],
    ], ["review_id", "animation_id"]
  ),
  (
    "get_animation_frame", "读取一个实际视频帧，标注图必须提供含区域的 issue_id。",
    [
      "review_id": ["type": "string"], "animation_id": ["type": "string"],
      "issue_id": ["type": "string"],
      "time": [
        "type": "object",
        "properties": ["value": ["type": "integer"], "timescale": ["type": "integer"]],
        "required": ["value", "timescale"], "additionalProperties": false,
      ], "source": ["type": "string", "enum": ["current", "reference"]],
      "variant": ["type": "string", "enum": ["original", "annotated"]],
      "max_dimension": ["type": "integer", "minimum": 256, "maximum": 2048],
      "expected_revision": ["type": "string"],
    ], ["review_id", "animation_id"]
  ),
  (
    "get_animation_frames", "获取时间段内有限关键帧及实际时间，重复帧去重。",
    [
      "review_id": ["type": "string"], "animation_id": ["type": "string"],
      "issue_id": ["type": "string"],
      "source": ["type": "string", "enum": ["current", "reference"]],
      "count": ["type": "integer", "minimum": 2, "maximum": 8],
      "max_dimension": ["type": "integer", "minimum": 256, "maximum": 1280],
      "expected_revision": ["type": "string"],
    ], ["review_id", "animation_id", "issue_id"]
  ),
]
func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
  guard let value else { return fallback }
  guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
    n.doubleValue.rounded() == n.doubleValue, range.contains(n.intValue)
  else { throw ReviewError.invalidData("INVALID_ARGUMENT: 数值参数无效。") }
  return n.intValue
}
func motionTool(_ name: String, args: [String: Any], repository: ReviewRepository) async throws
  -> [String: Any]
{
  guard let def = motionDefinitions.first(where: { $0.0 == name }) else {
    throw ReviewError.invalidData("未知工具。")
  }
  for (key, value) in args {
    guard let prop = def.2[key] as? [String: Any] else {
      throw ReviewError.invalidData("INVALID_ARGUMENT: 未知参数 \(key)")
    }
    if prop["type"] as? String == "string", !(value is String) {
      throw ReviewError.invalidData("INVALID_ARGUMENT: 参数必须为字符串。")
    }
  }
  for key in def.3 where args[key] == nil {
    throw ReviewError.invalidData("INVALID_ARGUMENT: 缺少 \(key)")
  }
  let library = try repository.load()
  let review = try resolveReview(args, library: library, required: name != "list_animations")
  let revision = library.revision.uuidString
  if let expected = args["expected_revision"] as? String, expected != revision {
    throw ReviewError.invalidData("STALE_REVIEW: Review 已变化，请重新读取。")
  }
  if name == "list_animations" {
    let limit = try integer(args["limit"], default: 20, range: 1...100)
    var offset = 0
    if let raw = args["cursor"] as? String {
      guard let data = Data(base64Encoded: raw),
        let cursor = try JSONSerialization.jsonObject(with: data) as? [String: String],
        cursor["revision"] == revision, cursor["review"] == review.id.uuidString,
        let last = cursor["last"],
        let i = review.animations.firstIndex(where: { $0.id.uuidString == last })
      else { throw ReviewError.invalidData("STALE_REVIEW: 分页已失效。") }
      offset = i + 1
    }
    let page = Array(review.animations.dropFirst(offset).prefix(limit))
    let next: Any =
      offset + page.count < review.animations.count && !page.isEmpty
      ? try JSONSerialization.data(withJSONObject: [
        "revision": revision, "review": review.id.uuidString, "last": page.last!.id.uuidString,
      ]).base64EncodedString() : NSNull()
    return [
      "content": [
        try textContent([
          "reviewID": review.id.uuidString, "libraryRevision": revision,
          "animations": page.map {
            [
              "id": $0.id.uuidString, "name": $0.name, "issueCount": $0.issues.count,
              "hasReference": $0.activeReference != nil,
            ] as [String: Any]
          }, "nextCursor": next,
        ])
      ], "isError": false,
    ]
  }
  guard let raw = args["animation_id"] as? String, let id = UUID(uuidString: raw),
    let animation = review.animations.first(where: { $0.id == id })
  else { throw ReviewError.missing("NOT_FOUND: 动画不存在。") }
  guard let current = review.videoAssets.first(where: { $0.id == animation.currentAssetID }) else {
    throw ReviewError.missing("NOT_FOUND: 当前视频不存在。")
  }
  if name == "get_animation" {
    let ids = Set(
      [current.id] + [animation.activeReference?.referenceAssetID].compactMap { $0 }
        + animation.issues.compactMap { $0.referenceSnapshot?.referenceAssetID })
    let assets = review.videoAssets.filter { ids.contains($0.id) }
    let availability = assets.map { asset -> [String: Any] in
      [
        "assetID": asset.id.uuidString,
        "available": (try? EvidenceService.verify(asset, repository: repository)) != nil,
      ]
    }
    return [
      "content": [
        try textContent([
          "libraryRevision": revision, "animation": try object(animation),
          "assets": try object(assets), "availability": availability,
        ])
      ], "isError": false,
    ]
  }
  let issue: AnimationIssue?
  if let raw = args["issue_id"] as? String {
    guard let id = UUID(uuidString: raw), let found = animation.issues.first(where: { $0.id == id })
    else { throw ReviewError.missing("NOT_FOUND: 问题不存在。") }
    issue = found
  } else {
    issue = nil
  }
  let source = args["source"] as? String ?? "current"
  let variant = args["variant"] as? String ?? "original"
  guard ["current", "reference"].contains(source), ["original", "annotated"].contains(variant)
  else { throw ReviewError.invalidData("INVALID_ARGUMENT: source 或 variant 无效。") }
  let relation = issue == nil ? animation.activeReference : issue?.referenceSnapshot
  let asset: VideoAsset
  if source == "reference" {
    guard let r = relation, let a = review.videoAssets.first(where: { $0.id == r.referenceAssetID })
    else { throw ReviewError.missing("NOT_FOUND: 未配置参考视频。") }
    asset = a
  } else {
    asset = current
  }
  var requests: [MediaTime] = []
  if name == "get_animation_frames" {
    guard let issue, issue.target.kind == .range, let start = issue.target.start,
      let end = issue.target.end
    else { throw ReviewError.invalidData("USE_SINGLE_FRAME: 时间点请使用单帧工具。") }
    let count = try integer(args["count"], default: 3, range: 2...8)
    let currentIndex = try await VideoService.index(
      EvidenceService.verify(current, repository: repository), asset: current)
    let inside = currentIndex.filter { issue.target.contains($0) }
    guard let last = inside.last else { throw ReviewError.missing("NO_FRAME: 时间段没有画面。") }
    requests = (0..<count).map {
      MediaTime(
        seconds: start.seconds + (min(end.seconds, last.seconds) - start.seconds) * Double($0)
          / Double(count - 1))
    }
  } else {
    guard (issue != nil) != (args["time"] != nil) else {
      throw ReviewError.invalidData("INVALID_ARGUMENT: issue_id 与 time 必须二选一。")
    }
    if let issue {
      requests = [issue.region?.actualTime ?? issue.target.first]
    } else {
      guard let obj = args["time"] as? [String: Any], Set(obj.keys) == Set(["value", "timescale"])
      else { throw ReviewError.invalidData("INVALID_ARGUMENT: time 无效。") }
      let value = try integer(obj["value"], default: 0, range: 0...9_007_199_254_740_991)
      let scale = try integer(obj["timescale"], default: 1, range: 1...Int(Int32.max))
      requests = [MediaTime(value: Int64(value), timescale: Int32(scale))]
    }
  }
  if source == "reference", issue != nil, let relation {
    requests = requests.map {
      MediaTime(
        seconds: $0.seconds - relation.currentStart.seconds + relation.referenceStart.seconds)
    }
  }
  if variant == "annotated" && (issue?.region == nil || source != "current") {
    throw ReviewError.invalidData("INVALID_ARGUMENT: 标注图需要当前视频的区域问题。")
  }
  let maxDimension = try integer(
    args["max_dimension"], default: name == "get_animation_frame" ? 1280 : 1024,
    range: 256...(name == "get_animation_frame" ? 2048 : 1280))
  var images: [[String: Any]] = []
  var metadata: [[String: Any]] = []
  var failures: [[String: Any]] = []
  var seen: [MediaTime] = []
  var bytes = 0
  for requested in requests {
    do {
      var (info, png) = try await EvidenceService.capture(
        asset: asset, repository: repository, requested: requested, source: source,
        region: variant == "annotated" ? issue?.region : nil, maxDimension: maxDimension)
      if seen.contains(where: { $0.equivalent(to: info.actualTime) }) { continue }
      var dim = maxDimension
      while png.count > 4_000_000 && dim > 256 {
        dim = max(256, dim / 2)
        let image = try ImageFiles.decode(png).image
        let small = try EvidenceService.resize(image, maxDimension: dim)
        png = try ImageFiles.png(small)
        info.renderedWidth = small.width
        info.renderedHeight = small.height
      }
      guard png.count <= 4_000_000, bytes + png.count * 4 / 3 < 11_500_000 else {
        throw ReviewError.invalidData("RESPONSE_TOO_LARGE: 帧证据超出响应预算。")
      }
      var entry = try object(info) as! [String: Any]
      entry["contentIndex"] = images.count + 1
      metadata.append(entry)
      images.append(["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()])
      bytes += png.count * 4 / 3
      seen.append(info.actualTime)
    } catch {
      if name == "get_animation_frame" { throw error }
      failures.append(["requestedTime": try object(requested), "error": error.localizedDescription])
    }
  }
  guard !images.isEmpty else { throw ReviewError.missing("NO_FRAME: 未取得可用证据。") }
  guard try repository.load().revision == library.revision else {
    throw ReviewError.invalidData("STALE_REVIEW: 取帧期间 Review 已变化。")
  }
  return [
    "content": [
      try textContent([
        "libraryRevision": revision, "frames": metadata, "requestedCount": requests.count,
        "returnedCount": images.count, "failedFrames": failures,
        "warnings": seen.count < requests.count ? ["部分候选帧重复、缺失或超出预算，结果已去重或省略。"] : [],
      ])
    ] + images, "isError": false,
  ]
}
