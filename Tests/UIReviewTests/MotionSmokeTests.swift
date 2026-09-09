import AppKit
import ReviewCore
import ReviewMedia
import XCTest
@testable import UIReview

final class MotionSmokeTests: XCTestCase {
  @MainActor func testImportMarkReopenAndExportWorkflow() async throws {
    guard let fixtures = ProcessInfo.processInfo.environment["UI_REVIEW_MEDIA_FIXTURES"] else {
      throw XCTSkip("Requires media fixtures")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-smoke-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    let store = ReviewStore(repository: repo)
    let source = URL(fileURLWithPath: fixtures).appendingPathComponent("cfr30.mp4")
    store.importVideos([source])
    await store.importTask?.value
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.isBusy)
    let animation = try XCTUnwrap(store.animation)
    let asset = try XCTUnwrap(store.currentReview?.videoAssets.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(for: asset).path))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("ordinary text", forType: .string)
    store.pasteReferenceVideo(from: board)
    XCTAssertNil(store.importTask)
    XCTAssertEqual(store.currentReview?.animations.count, 1)
    board.clearContents()
    board.writeObjects([source as NSURL, source.deletingLastPathComponent().appendingPathComponent("other.mov") as NSURL])
    store.pasteReferenceVideo(from: board)
    XCTAssertNil(store.importTask)
    board.clearContents()
    board.writeObjects([source as NSURL])
    store.pasteReferenceVideo(from: board)
    await store.importTask?.value
    XCTAssertEqual(store.currentReview?.animations.count, 1)
    XCTAssertEqual(store.animation?.currentAssetID, asset.id)
    XCTAssertEqual(store.currentReview?.videoAssets.count, 2)
    store.pasteReferenceVideo(from: board)
    XCTAssertNil(store.importTask) // alignment pending: repeat paste must not import again
    let referenceID = try XCTUnwrap(store.pendingReferenceID)
    XCTAssertNil(store.animation?.activeReference)
    let alignment = ReferenceAlignment(referenceAssetID: referenceID, currentStart: .zero, referenceStart: .zero)
    store.mutateAnimation("设置参考") { $0.activeReference = alignment }
    store.pendingReferenceID = nil
    store.pasteReferenceVideo(from: board)
    XCTAssertNil(store.importTask)
    XCTAssertEqual(store.animation?.activeReference, alignment)
    store.addMotionIssue(target: .point(MediaTime(seconds: 0.1)))
    let issueID = try XCTUnwrap(store.motionIssue?.id)
    store.updateMotionIssue(issueID) {
      $0.comment = "冒烟测试：按钮偏移"
      $0.region = FrameRegion(assetID: asset.id, actualTime: MediaTime(seconds: 0.1),
        frameWidth: asset.displayWidth, frameHeight: asset.displayHeight,
        pixelRect: Region(x: 20, y: 30, width: 100, height: 80))
    }
    XCTAssertFalse(store.hasUnsavedChanges)
    let reopened = ReviewStore(repository: repo)
    XCTAssertEqual(reopened.selectedAnimationID, animation.id)
    let issue = try XCTUnwrap(reopened.animation?.issues.first)
    XCTAssertEqual(issue.comment, "冒烟测试：按钮偏移")
    XCTAssertEqual(issue.region?.pixelRect.width, 100)
    XCTAssertEqual(issue.referenceSnapshot?.referenceAssetID, referenceID)
    let destination = root.appendingPathComponent("handoff")
    try await MotionExport.write(try XCTUnwrap(reopened.currentReview), revision: reopened.library.revision,
      repository: repo, to: destination)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
      destination.appendingPathComponent("review.json"))) as? [String: Any])
    XCTAssertEqual(json["formatVersion"] as? Int, 2)
    let evidence = try XCTUnwrap(json["evidence"] as? [[String: Any]])
    XCTAssertTrue(evidence.contains { $0["source"] as? String == "reference" })
    for item in evidence {
      let path = try XCTUnwrap(item["path"] as? String)
      XCTAssertGreaterThan(try Data(contentsOf: destination.appendingPathComponent(path)).count, 0)
    }
  }
}
