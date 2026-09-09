import ReviewCore
import ReviewMedia
import XCTest
import SwiftUI
import AppKit

@testable import UIReview

final class MotionStateTests: XCTestCase {
  @MainActor func testAnimationOnlyReviewRestoresAndUndoRecoversSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    let id = UUID()
    let asset = VideoAsset(
      id: id, originalName: "test.mov", path: "assets/videos/\(id).mov",
      sha256: String(repeating: "a", count: 64), byteLength: 100, container: "mov", codec: "h264",
      trackID: 1, timelineOrigin: .zero, duration: MediaTime(seconds: 1), encodedWidth: 100,
      encodedHeight: 200, displayWidth: 100, displayHeight: 200,
      preferredTransform: VideoTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0), nominalFrameRate: 30
    )
    var review = Review(title: "动画")
    let animation = ReviewCore.Animation(name: "test", currentAssetID: id)
    review.animations = [animation]
    review.videoAssets = [asset]
    review.reconcileOrder()
    try repo.save(ReviewLibrary(currentReviewID: review.id, reviews: [review]))
    let store = ReviewStore(repository: repo)
    XCTAssertEqual(store.selectedAnimationID, animation.id)
    XCTAssertNil(store.screenshot)
    store.addMotionIssue(target: .point(MediaTime(seconds: 0.1)))
    let issueID = try XCTUnwrap(store.motionIssue?.id)
    store.updateMotionIssue(issueID) { $0.comment = "修复位置" }
    func deletion(repeatKey: Bool = false) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}",
        charactersIgnoringModifiers: "\u{7f}", isARepeat: repeatKey, keyCode: 51))
    }
    XCTAssertFalse(store.handleMaterialDeletion(try deletion(), isEditingText: true))
    XCTAssertEqual(store.animation?.id, animation.id)
    XCTAssertTrue(store.handleMaterialDeletion(try deletion(repeatKey: true), isEditingText: false))
    XCTAssertEqual(store.animation?.id, animation.id)
    XCTAssertTrue(store.handleMaterialDeletion(try deletion(), isEditingText: false))
    XCTAssertNil(store.animation)
    XCTAssertTrue(try repo.load().currentReview?.animations.isEmpty == true)
    store.undo()
    XCTAssertEqual(store.animation?.id, animation.id)
    XCTAssertEqual(store.motionIssue?.comment, "修复位置")
    store.newReview()
    store.openReview(review.id)
    XCTAssertEqual(store.animation?.id, animation.id)
  }
  @MainActor func testLoopRejectsRangeWithoutFramesInsteadOfSeekingForever() {
    let session = MotionSession()
    session.frames = [MediaTime(seconds: 0), MediaTime(seconds: 0.033), MediaTime(seconds: 0.066)]
    session.useRange = true
    session.rangeStart = 0.01
    session.rangeEnd = 0.02
    session.toggle()
    XCTAssertFalse(session.playing)
    XCTAssertEqual(session.message, "选段中没有可播放画面。")
    session.stop()
    XCTAssertFalse(session.useRange)
  }
  @MainActor func testLateCommentSaveDoesNotClearNewerDirtyRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    let review = Review(title: "初始")
    try repo.save(ReviewLibrary(currentReviewID: review.id, reviews: [review]))
    let store = ReviewStore(repository: repo)
    store.renameReview("第一次")
    store.renameReview("最新")
    XCTAssertTrue(store.hasUnsavedChanges)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(try repo.load().currentReview?.title, "最新")
    XCTAssertFalse(store.hasUnsavedChanges)
  }
}

extension MotionStateTests {
  @MainActor func testRapidSeeksKeepNewestFrameAndDualPlaybackAdvances() async throws {
    guard let path = ProcessInfo.processInfo.environment["UI_REVIEW_MEDIA_FIXTURES"] else {
      throw XCTSkip("Requires media fixtures")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    let imported = try await ReviewMedia.VideoService.importVideo(
      URL(fileURLWithPath: path).appendingPathComponent("cfr30.mp4"), repository: repo)
    var animation = ReviewCore.Animation(name: "同步", currentAssetID: imported.asset.id)
    animation.activeReference = ReferenceAlignment(
      referenceAssetID: imported.asset.id, currentStart: .zero, referenceStart: .zero)
    var review = Review(title: "播放测试")
    review.animations = [animation]
    review.videoAssets = [imported.asset]
    review.reconcileOrder()
    let session = MotionSession()
    defer { session.stop() }
    await session.configure(animation, review: review, repository: repo)
    session.seek(imported.frames[4])
    session.seek(imported.frames[15])
    let deadline = Date().addingTimeInterval(5)
    while session.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(session.loading, session.message ?? "seek did not finish")
    XCTAssertTrue(session.time.equivalent(to: imported.frames[15]))
    XCTAssertTrue(session.referenceTime?.equivalent(to: imported.frames[15]) == true)
    session.toggle()
    let host = NSHostingView(rootView: HStack {
      MotionPlayerView(player: session.player)
      MotionPlayerView(player: session.referencePlayer)
    })
    host.frame = NSRect(x: 0, y: 0, width: 850, height: 400)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertGreaterThan(session.time.seconds, imported.frames[15].seconds)
    session.toggle()
    XCTAssertFalse(session.playing)
  }
}
