import ReviewCore
import ReviewMedia
import XCTest

@testable import UIReview

final class MotionBoxSelectionTests: XCTestCase {
  @MainActor func testBoxSelectionCreatesIssueWithoutAddButton() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    let time = MediaTime(seconds: 0.1)
    env.store.applyMotionBoxSelection(
      Region(x: 10, y: 20, width: 30, height: 40),
      asset: env.asset, time: time, target: .point(time))
    XCTAssertEqual(env.store.animation?.issues.count, 1)
    XCTAssertEqual(env.store.motionIssue?.region?.pixelRect.width, 30)
    XCTAssertEqual(env.store.tool, .select)
  }

  @MainActor func testBoxSelectionCreatesAnotherIssueWhenOneAlreadyExists() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    let time = MediaTime(seconds: 0.1)
    let rect = Region(x: 10, y: 20, width: 30, height: 40)
    env.store.applyMotionBoxSelection(rect, asset: env.asset, time: time, target: .point(time))
    let firstID = try XCTUnwrap(env.store.motionIssue?.id)
    env.store.applyMotionBoxSelection(
      Region(x: 50, y: 60, width: 40, height: 50),
      asset: env.asset, time: time, target: .point(time))
    XCTAssertEqual(env.store.animation?.issues.count, 2)
    XCTAssertNotEqual(env.store.motionIssue?.id, firstID)
    XCTAssertEqual(env.store.motionIssue?.region?.pixelRect.x, 50)
    XCTAssertNil(env.store.errorMessage)
  }

  @MainActor func testBoxSelectionCreatesNewIssueEvenIfSelectedIssueHasNoRegion() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    env.store.addMotionIssue(target: .point(MediaTime(seconds: 0.1)))
    let emptyID = try XCTUnwrap(env.store.motionIssue?.id)
    let time = MediaTime(seconds: 0.2)
    env.store.applyMotionBoxSelection(
      Region(x: 8, y: 8, width: 16, height: 16),
      asset: env.asset, time: time, target: .point(time))
    XCTAssertEqual(env.store.animation?.issues.count, 2)
    XCTAssertNotEqual(env.store.motionIssue?.id, emptyID)
    XCTAssertNil(env.store.animation?.issues.first { $0.id == emptyID }?.region)
  }

  @MainActor func testReplaceMotionRegionUpdatesExistingIssue() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    let time = MediaTime(seconds: 0.1)
    env.store.applyMotionBoxSelection(
      Region(x: 10, y: 20, width: 30, height: 40),
      asset: env.asset, time: time, target: .point(time))
    let issueID = try XCTUnwrap(env.store.motionIssue?.id)
    env.store.replacingMotionRegion = true
    env.store.applyMotionBoxSelection(
      Region(x: 1, y: 2, width: 12, height: 14),
      asset: env.asset, time: time, target: .point(time))
    XCTAssertEqual(env.store.animation?.issues.count, 1)
    XCTAssertEqual(env.store.motionIssue?.id, issueID)
    XCTAssertEqual(env.store.motionIssue?.region?.pixelRect.width, 12)
    XCTAssertFalse(env.store.replacingMotionRegion)
  }

  @MainActor func testReplaceMotionRegionRejectsFrameOutsideIssueTime() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    let time = MediaTime(seconds: 0.1)
    env.store.applyMotionBoxSelection(
      Region(x: 10, y: 20, width: 30, height: 40),
      asset: env.asset, time: time, target: .point(time))
    env.store.replacingMotionRegion = true
    env.store.applyMotionBoxSelection(
      Region(x: 1, y: 2, width: 12, height: 14),
      asset: env.asset, time: MediaTime(seconds: 0.5), target: .point(MediaTime(seconds: 0.5)))
    XCTAssertEqual(env.store.animation?.issues.count, 1)
    XCTAssertEqual(env.store.motionIssue?.region?.pixelRect.width, 30)
    XCTAssertEqual(env.store.errorMessage, "当前帧不在问题时间内，请查看标注帧或返回问题范围。")
    XCTAssertTrue(env.store.replacingMotionRegion)
  }

  @MainActor func testBoxSelectionUsesRangeWhenCurrentFrameIsInside() throws {
    let env = try MotionBoxSelectionHarness()
    defer { env.cleanup() }
    let time = MediaTime(seconds: 0.2)
    let target = TemporalTarget.range(MediaTime(seconds: 0.1), MediaTime(seconds: 0.4))
    env.store.applyMotionBoxSelection(
      Region(x: 10, y: 10, width: 20, height: 20),
      asset: env.asset, time: time, target: target)
    XCTAssertEqual(env.store.motionIssue?.target, target)
  }
}

@MainActor
private struct MotionBoxSelectionHarness {
  let root: URL
  let store: ReviewStore
  let asset: VideoAsset

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = ReviewRepository(root: root)
    let id = UUID()
    asset = VideoAsset(
      id: id, originalName: "test.mov", path: "assets/videos/\(id).mov",
      sha256: String(repeating: "a", count: 64), byteLength: 100, container: "mov", codec: "h264",
      trackID: 1, timelineOrigin: .zero, duration: MediaTime(seconds: 1), encodedWidth: 100,
      encodedHeight: 200, displayWidth: 100, displayHeight: 200,
      preferredTransform: VideoTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0), nominalFrameRate: 30
    )
    var review = Review(title: "动画")
    review.animations = [ReviewCore.Animation(name: "test", currentAssetID: id)]
    review.videoAssets = [asset]
    review.reconcileOrder()
    try repo.save(ReviewLibrary(currentReviewID: review.id, reviews: [review]))
    store = ReviewStore(repository: repo)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
