import CoreGraphics
import Foundation
import ReviewCore

public struct MotionEvidence: Codable, Sendable {
  public var assetID: UUID
  public var source: String
  public var requestedTime: MediaTime
  public var actualTime: MediaTime
  public var sourceWidth: Int
  public var sourceHeight: Int
  public var renderedWidth: Int
  public var renderedHeight: Int
  public var region: FrameRegion?
  public var coordinateSystem = "top-left oriented source pixels"
}
public enum EvidenceService {
  public static func verify(_ asset: VideoAsset, repository: ReviewRepository) throws -> URL {
    let url = try repository.assetURL(for: asset)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReviewError.missing("ASSET_MISSING: 视频文件缺失。")
    }
    let info = try url.resourceValues(forKeys: [.fileSizeKey])
    guard Int64(info.fileSize ?? -1) == asset.byteLength,
      try VideoService.digest(url) == asset.sha256
    else { throw ReviewError.invalidData("ASSET_CHANGED: 视频文件已变化。") }
    return url
  }
  public static func capture(
    asset: VideoAsset, repository: ReviewRepository, requested: MediaTime, source: String,
    region: FrameRegion? = nil, maxDimension: Int = 1280
  ) async throws -> (MotionEvidence, Data) {
    let url = try verify(asset, repository: repository)
    let index = try await VideoService.index(url, asset: asset)
    guard requested >= .zero, requested < asset.duration,
      let sample = index.last(where: { $0 <= requested }) ?? index.first
    else { throw ReviewError.missing("NO_FRAME: 此时间无画面。") }
    let frame = try await VideoService.frame(url, asset: asset, at: sample)
    var image = frame.image
    if let region {
      guard region.actualTime.equivalent(to: frame.actualTime) else {
        throw ReviewError.invalidData("NO_FRAME: 无法读取准确标注帧。")
      }
      let issue = Issue(
        region: region.pixelRect, imageWidth: asset.displayWidth, imageHeight: asset.displayHeight)
      image = try ImageFiles.decode(ImageFiles.annotated(image, issues: [issue])).image
    }
    if max(image.width, image.height) > maxDimension {
      image = try resize(image, maxDimension: maxDimension)
    }
    let metadata = MotionEvidence(
      assetID: asset.id, source: source, requestedTime: requested, actualTime: frame.actualTime,
      sourceWidth: asset.displayWidth, sourceHeight: asset.displayHeight,
      renderedWidth: image.width, renderedHeight: image.height, region: region)
    return (metadata, try ImageFiles.png(image))
  }
  public static func resize(_ image: CGImage, maxDimension: Int) throws -> CGImage {
    let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale))
    let h = max(1, Int(Double(image.height) * scale))
    guard
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ReviewError.invalidData("无法缩放画面。") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let output = context.makeImage() else { throw ReviewError.invalidData("无法缩放画面。") }
    return output
  }
}
