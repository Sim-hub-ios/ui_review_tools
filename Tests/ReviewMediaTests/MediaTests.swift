import ReviewCore
import XCTest

@testable import ReviewMedia

final class MediaTests: XCTestCase {
  func fixtures() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["UI_REVIEW_MEDIA_FIXTURES"] else {
      throw XCTSkip("Set UI_REVIEW_MEDIA_FIXTURES to the T0 fixture directory")
    }
    return URL(fileURLWithPath: path)
  }
  func testPTSOrientationAndEvidenceExport() async throws {
    let source = try fixtures()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "motion-media-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    for name in ["cfr30", "vfr", "rotated90", "benchmark60"] {
      let result = try await VideoService.importVideo(
        source.appendingPathComponent(name + ".mp4"), repository: repo)
      XCTAssertFalse(result.frames.isEmpty)
      let frame = try await VideoService.frame(
        repo.assetURL(for: result.asset), asset: result.asset, at: result.frames[3])
      XCTAssertTrue(frame.actualTime.equivalent(to: result.frames[3]))
      XCTAssertEqual(frame.image.width, result.asset.displayWidth)
      XCTAssertEqual(frame.image.height, result.asset.displayHeight)
      if name == "rotated90" {
        XCTAssertEqual(frame.image.width, 360)
        XCTAssertEqual(frame.image.height, 640)
      }
      if name == "vfr" {
        let deltas = zip(result.frames, result.frames.dropFirst()).map {
          Int((($1.seconds - $0.seconds) * 1000).rounded())
        }
        XCTAssertGreaterThan(Set(deltas).count, 1)
      }
      var animation = ReviewCore.Animation(name: name, currentAssetID: result.asset.id)
      var issue = AnimationIssue(target: .range(result.frames[1], result.frames[10]))
      issue.comment = "减少突然停止"
      issue.region = FrameRegion(
        assetID: result.asset.id, actualTime: result.frames[3],
        frameWidth: result.asset.displayWidth, frameHeight: result.asset.displayHeight,
        pixelRect: Region(x: 20, y: 30, width: 100, height: 80))
      animation.issues = [issue]
      var review = Review(title: "Media integration")
      review.animations = [animation]
      review.videoAssets = [result.asset]
      review.reconcileOrder()
      let library = ReviewLibrary(currentReviewID: review.id, reviews: [review])
      try repo.save(library)
      let (metadata, png) = try await EvidenceService.capture(
        asset: result.asset, repository: repo, requested: result.frames[3], source: "current",
        region: issue.region, maxDimension: 320)
      XCTAssertNotNil(metadata.region)
      XCTAssertEqual(max(metadata.renderedWidth, metadata.renderedHeight), 320)
      XCTAssertFalse(png.isEmpty)
      if name == "cfr30" {
        let destination = root.appendingPathComponent("export")
        try await MotionExport.write(
          review, revision: library.revision, repository: repo, to: destination)
        let json =
          try JSONSerialization.jsonObject(
            with: Data(contentsOf: destination.appendingPathComponent("review.json")))
          as! [String: Any]
        XCTAssertEqual(json["formatVersion"] as? Int, 2)
        let evidence = json["evidence"] as! [[String: Any]]
        XCTAssertTrue(evidence.contains { $0["region"] != nil })
        for item in evidence {
          if let path = item["path"] as? String {
            XCTAssertTrue(
              FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
          }
        }
        if let output = ProcessInfo.processInfo.environment["UI_REVIEW_TEST_ARTIFACTS"] {
          let out = URL(fileURLWithPath: output)
          try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
          let fixture = out.appendingPathComponent("library")
          try FileManager.default.copyItem(at: root, to: fixture)
        }
      }
    }
  }
  func testHEVCSDRCanBeDecoded() async throws {
    guard let path = ProcessInfo.processInfo.environment["UI_REVIEW_HEVC_FIXTURE"] else {
      throw XCTSkip("Set UI_REVIEW_HEVC_FIXTURE")
    }
    let result = try await VideoService.inspect(URL(fileURLWithPath: path))
    XCTAssertEqual(result.asset.codec, "hevc")
    XCTAssertEqual(result.frames.count, 30)
    let frame = try await VideoService.frame(
      URL(fileURLWithPath: path), asset: result.asset, at: result.frames[10])
    XCTAssertTrue(frame.actualTime.equivalent(to: result.frames[10]))
  }
  func testInvalidTimeRejectedBeforeDecoder() async throws {
    let source = try fixtures()
    let result = try await VideoService.inspect(source.appendingPathComponent("cfr30.mp4"))
    do {
      _ = try await VideoService.frame(
        source.appendingPathComponent("cfr30.mp4"), asset: result.asset, at: result.asset.duration)
      XCTFail("accepted end-exclusive timestamp")
    } catch { XCTAssertTrue(error.localizedDescription.contains("时间")) }
  }
}
