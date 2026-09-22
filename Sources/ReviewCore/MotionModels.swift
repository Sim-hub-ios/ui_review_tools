import Foundation

public struct MediaTime: Codable, Hashable, Comparable, Sendable {
  public var value: Int64
  public var timescale: Int32
  public init(value: Int64, timescale: Int32) {
    self.value = value
    self.timescale = timescale
  }
  public init(seconds: Double) {
    timescale = 1_000_000
    value =
      seconds.isFinite && abs(seconds) < 9_000_000_000
      ? Int64((seconds * 1_000_000).rounded()) : Int64.max
  }
  public var seconds: Double { Double(value) / Double(timescale) }
  public var isValid: Bool {
    timescale > 0 && value >= -9_007_199_254_740_991 && value <= 9_007_199_254_740_991
  }
  public static let zero = MediaTime(value: 0, timescale: 1)
  public static func < (lhs: Self, rhs: Self) -> Bool {
    let a = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
    let b = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
    return a.high == b.high ? a.low < b.low : a.high < b.high
  }
  public func equivalent(to other: Self) -> Bool { !(self < other) && !(other < self) }
}

public struct TemporalTarget: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case point, range }
  public var kind: Kind
  public var at: MediaTime?
  public var start: MediaTime?
  public var end: MediaTime?
  public static func point(_ time: MediaTime) -> Self { Self(kind: .point, at: time) }
  public static func range(_ start: MediaTime, _ end: MediaTime) -> Self {
    Self(kind: .range, start: start, end: end)
  }
  public var first: MediaTime { at ?? start ?? .zero }
  public func contains(_ time: MediaTime) -> Bool {
    if kind == .point { return at?.equivalent(to: time) == true }
    guard let start, let end else { return false }
    return time >= start && time < end
  }
  public func validate(duration: MediaTime) throws {
    switch kind {
    case .point:
      guard let at, at.isValid, at >= .zero, at < duration, start == nil, end == nil else {
        throw ReviewError.invalidData("时间点无效。")
      }
    case .range:
      guard at == nil, let start, let end, start.isValid, end.isValid, start >= .zero, start < end,
        end <= duration
      else { throw ReviewError.invalidData("时间段必须在视频内且起点早于终点。") }
    }
  }
}

public struct VideoTransform: Codable, Equatable, Sendable {
  public var a, b, c, d, tx, ty: Double
  public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.tx = tx
    self.ty = ty
  }
}

public struct VideoAsset: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var originalName: String
  public var path: String
  public var sha256: String
  public var byteLength: Int64
  public var container: String
  public var codec: String
  public var trackID: Int32
  public var timelineOrigin: MediaTime
  public var duration: MediaTime
  public var encodedWidth: Int
  public var encodedHeight: Int
  public var displayWidth: Int
  public var displayHeight: Int
  public var preferredTransform: VideoTransform
  public var nominalFrameRate: Double?
  public var colorPolicy = "sdr-srgb-v1"
  public var createdAt = Date()
  public init(
    id: UUID, originalName: String, path: String, sha256: String, byteLength: Int64,
    container: String, codec: String, trackID: Int32, timelineOrigin: MediaTime,
    duration: MediaTime,
    encodedWidth: Int, encodedHeight: Int, displayWidth: Int, displayHeight: Int,
    preferredTransform: VideoTransform, nominalFrameRate: Double?
  ) {
    self.id = id
    self.originalName = originalName
    self.path = path
    self.sha256 = sha256
    self.byteLength = byteLength
    self.container = container
    self.codec = codec
    self.trackID = trackID
    self.timelineOrigin = timelineOrigin
    self.duration = duration
    self.encodedWidth = encodedWidth
    self.encodedHeight = encodedHeight
    self.displayWidth = displayWidth
    self.displayHeight = displayHeight
    self.preferredTransform = preferredTransform
    self.nominalFrameRate = nominalFrameRate
  }
}

public struct ReferenceAlignment: Codable, Equatable, Sendable {
  public var referenceAssetID: UUID
  public var currentStart: MediaTime
  public var referenceStart: MediaTime
  public var alignmentID: UUID
  public init(
    referenceAssetID: UUID, currentStart: MediaTime, referenceStart: MediaTime,
    alignmentID: UUID = UUID()
  ) {
    self.referenceAssetID = referenceAssetID
    self.currentStart = currentStart
    self.referenceStart = referenceStart
    self.alignmentID = alignmentID
  }
}
public struct FrameRegion: Codable, Equatable, Sendable {
  public var assetID: UUID
  public var actualTime: MediaTime
  public var frameWidth: Int
  public var frameHeight: Int
  public var pixelRect: Region
  public var normalizedRect: Region
  public init(
    assetID: UUID, actualTime: MediaTime, frameWidth: Int, frameHeight: Int, pixelRect: Region
  ) {
    self.assetID = assetID
    self.actualTime = actualTime
    self.frameWidth = frameWidth
    self.frameHeight = frameHeight
    self.pixelRect = pixelRect
    self.normalizedRect = pixelRect.normalized(width: frameWidth, height: frameHeight)
  }
}
public struct AnimationIssue: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var target: TemporalTarget
  public var comment = ""
  public var expectation: String?
  public var component: String?
  public var category: String?
  public var region: FrameRegion?
  public var referenceSnapshot: ReferenceAlignment?
  public init(target: TemporalTarget, referenceSnapshot: ReferenceAlignment? = nil) {
    self.target = target
    self.referenceSnapshot = referenceSnapshot
  }
}
public struct Animation: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var name: String
  public var createdAt = Date()
  public var updatedAt = Date()
  public var currentAssetID: UUID
  public var referenceAssetID: UUID? = nil
  public var activeReference: ReferenceAlignment?
  public var issues: [AnimationIssue] = []
  public var resolvedReferenceAssetID: UUID? { referenceAssetID ?? activeReference?.referenceAssetID }
  public init(name: String, currentAssetID: UUID) {
    self.name = name
    self.currentAssetID = currentAssetID
  }
}
public struct ReviewItem: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case screenshot, animation }
  public var kind: Kind
  public var id: UUID
  public init(kind: Kind, id: UUID) {
    self.kind = kind
    self.id = id
  }
}
