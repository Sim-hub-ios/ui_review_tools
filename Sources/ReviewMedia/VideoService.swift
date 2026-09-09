import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ReviewCore

extension MediaTime {
  public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
  public init(_ time: CMTime) throws {
    guard time.isNumeric, time.epoch == 0 else { throw ReviewError.invalidData("媒体时间无效。") }
    self.init(value: time.value, timescale: time.timescale)
    guard isValid else { throw ReviewError.invalidData("媒体时间超出精度范围。") }
  }
}
public struct VideoInspection: Sendable {
  public var asset: VideoAsset
  public var frames: [MediaTime]
}
public struct VideoFrame: @unchecked Sendable {
  public let image: CGImage
  public let requestedTime: MediaTime
  public let actualTime: MediaTime
}
public enum VideoService {
  private static func cacheKey(_ url: URL, asset: VideoAsset) throws -> String {
    let v = try url.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
    ])
    return
      "\(url.path)|\(asset.sha256)|\(v.fileSize ?? -1)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: v.fileResourceIdentifier))"
  }
  public static func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
      try Task.checkCancellation()
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func inspect(_ url: URL, id: UUID = UUID()) async throws -> VideoInspection {
    let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard info.isRegularFile == true, let bytes = info.fileSize, bytes > 0, bytes <= 500_000_000
    else { throw ReviewError.invalidData("请选择不超过 500 MB 的视频。") }
    let container = url.pathExtension.lowercased()
    guard ["mp4", "mov"].contains(container) else {
      throw ReviewError.invalidData("请选择 MP4 或 MOV 视频。")
    }
    let source = AVURLAsset(url: url)
    guard try await !source.load(.hasProtectedContent) else {
      throw ReviewError.invalidData("不支持受保护视频。")
    }
    let tracks = try await source.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
      throw ReviewError.invalidData("仅支持包含单个视频轨道的素材。")
    }
    let formats = try await track.load(.formatDescriptions)
    guard let format = formats.first else { throw ReviewError.invalidData("视频格式缺失。") }
    let codecID = CMFormatDescriptionGetMediaSubType(format)
    guard codecID == kCMVideoCodecType_H264 || codecID == kCMVideoCodecType_HEVC else {
      throw ReviewError.invalidData("当前支持 H.264 / HEVC 视频。")
    }
    let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
    if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
      transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    {
      throw ReviewError.invalidData("HDR 录屏尚未通过色彩验证，请导出 SDR 视频后导入。")
    }
    if let aspect = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
      let horizontal = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing]
        as? NSNumber,
      let vertical = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber,
      horizontal != vertical
    {
      throw ReviewError.invalidData("暂不支持非正方形像素视频。")
    }
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let values = [transform.a, transform.b, transform.c, transform.d]
    guard values.allSatisfy({ $0.isFinite && abs($0.rounded() - $0) < 0.00001 }),
      abs(transform.a * transform.a + transform.b * transform.b - 1) < 0.00001,
      abs(transform.c * transform.c + transform.d * transform.d - 1) < 0.00001,
      abs(transform.a * transform.c + transform.b * transform.d) < 0.00001,
      transform.tx.isFinite, transform.ty.isFinite
    else { throw ReviewError.invalidData("暂不支持此视频方向变换。") }
    let visible = CGRect(origin: .zero, size: size).applying(transform).standardized.size
    guard visible.width > 0, visible.height > 0, max(visible.width, visible.height) <= 4096 else {
      throw ReviewError.invalidData("视频边长最多 4096 像素。")
    }
    let range = try await track.load(.timeRange)
    guard range.duration.isNumeric, range.duration.seconds > 0, range.duration.seconds <= 120 else {
      throw ReviewError.invalidData("视频时长最多 120 秒。")
    }
    let fps = try await track.load(.nominalFrameRate)
    let origin = try MediaTime(range.start)
    let duration = try MediaTime(range.duration)
    let asset = VideoAsset(
      id: id, originalName: url.lastPathComponent,
      path: "assets/videos/\(id.uuidString).\(container)", sha256: try digest(url),
      byteLength: Int64(bytes), container: container,
      codec: codecID == kCMVideoCodecType_H264 ? "h264" : "hevc", trackID: track.trackID,
      timelineOrigin: origin, duration: duration, encodedWidth: Int(size.width),
      encodedHeight: Int(size.height), displayWidth: Int(visible.width.rounded()),
      displayHeight: Int(visible.height.rounded()),
      preferredTransform: VideoTransform(
        a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx,
        ty: transform.ty), nominalFrameRate: Double(fps))
    let frames = try await index(url, asset: asset)
    guard !frames.isEmpty else { throw ReviewError.invalidData("视频中没有可解码画面。") }
    let first = try await frame(url, asset: asset, at: frames[0])
    guard first.image.width == asset.displayWidth, first.image.height == asset.displayHeight else {
      throw ReviewError.invalidData("视频裁切尺寸或像素比例暂不支持。")
    }
    return VideoInspection(asset: asset, frames: frames)
  }
  public static func index(_ url: URL, asset: VideoAsset) async throws -> [MediaTime] {
    let key = try cacheKey(url, asset: asset)
    if let cached = await MediaCache.shared.index(key) { return cached }
    let source = AVURLAsset(url: url)
    guard
      let track = try await source.loadTracks(withMediaType: .video).first(where: {
        $0.trackID == asset.trackID
      })
    else { throw ReviewError.missing("视频轨道不存在。") }
    let reader = try AVAssetReader(asset: source)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ReviewError.invalidData("视频轨道无法解码。") }
    reader.add(output)
    let result: [MediaTime] = try await withTaskCancellationHandler(
      operation: {
        guard reader.startReading() else {
          throw reader.error ?? ReviewError.invalidData("无法读取视频。")
        }
        defer { reader.cancelReading() }
        var frames: [MediaTime] = []
        let deadline = Date().addingTimeInterval(30)
        while let sample = output.copyNextSampleBuffer() {
          try Task.checkCancellation()
          guard Date() < deadline, frames.count < 36_000 else {
            throw ReviewError.invalidData("视频索引超出时间或帧数限制。")
          }
          guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
          guard CVPixelBufferGetWidth(buffer) == asset.encodedWidth,
            CVPixelBufferGetHeight(buffer) == asset.encodedHeight
          else { throw ReviewError.invalidData("视频画面尺寸发生变化，暂不支持。") }
          let t = try MediaTime(
            CMTimeSubtract(
              CMSampleBufferGetPresentationTimeStamp(sample), asset.timelineOrigin.cmTime))
          if t >= .zero && t < asset.duration { frames.append(t) }
        }
        guard reader.status == .completed else {
          throw reader.error ?? ReviewError.invalidData("视频未完整解码。")
        }
        return frames.sorted().reduce(into: []) { result, t in
          if result.last?.equivalent(to: t) != true { result.append(t) }
        }
      }, onCancel: { reader.cancelReading() })
    await MediaCache.shared.saveIndex(result, key: key)
    return result
  }
  public static func frame(
    _ url: URL, asset: VideoAsset, at time: MediaTime, maxDimension: Int = 4096
  ) async throws -> VideoFrame {
    guard time.isValid, time >= .zero, time < asset.duration else {
      throw ReviewError.invalidData("取帧时间超出视频。")
    }
    let key = try cacheKey(url, asset: asset) + "|\(time.value)/\(time.timescale)|\(maxDimension)"
    if let cached = await MediaCache.shared.frame(key) { return cached }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    let frame = try await withTaskCancellationHandler(
      operation: {
        let result = try await generator.image(
          at: CMTimeAdd(time.cmTime, asset.timelineOrigin.cmTime))
        try Task.checkCancellation()
        let actual = try MediaTime(CMTimeSubtract(result.actualTime, asset.timelineOrigin.cmTime))
        return VideoFrame(image: result.image, requestedTime: time, actualTime: actual)
      }, onCancel: { generator.cancelAllCGImageGeneration() })
    await MediaCache.shared.saveFrame(frame, key: key)
    return frame
  }
  public static func importVideo(_ source: URL, repository: ReviewRepository) async throws
    -> VideoInspection
  {
    // Inspect the immutable staging copy so edits to the source cannot mix metadata and bytes.
    let directory = repository.root.appendingPathComponent("assets/videos")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard
      directory.resolvingSymlinksInPath()
        == repository.root.resolvingSymlinksInPath().appendingPathComponent("assets/videos")
    else { throw ReviewError.invalidData("视频目录不能指向外部。") }
    let id = UUID()
    let target = directory.appendingPathComponent(
      "\(UUID()).staging.\(source.pathExtension.lowercased())")
    defer { try? FileManager.default.removeItem(at: target) }
    let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 500_000_000 else {
      throw ReviewError.invalidData("请选择不超过 500 MB 的视频。")
    }
    try Data().write(to: target, options: .withoutOverwriting)
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: target)
    do {
      var total = 0
      while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
        try Task.checkCancellation()
        total += data.count
        guard total <= 500_000_000 else { throw ReviewError.invalidData("视频复制期间超出 500 MB 限制。") }
        try output.write(contentsOf: data)
      }
      try output.synchronize()
      try output.close()
      try input.close()
    } catch {
      try? input.close()
      try? output.close()
      throw error
    }
    var result = try await inspect(target, id: id)
    result.asset.originalName = source.lastPathComponent
    try Task.checkCancellation()
    let destination = try repository.assetURL(for: result.asset)
    try FileManager.default.moveItem(at: target, to: destination)
    return result
  }
}
