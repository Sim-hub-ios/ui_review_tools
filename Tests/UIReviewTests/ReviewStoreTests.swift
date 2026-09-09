import XCTest
import Observation
import CoreGraphics
import ReviewCore
@testable import UIReview

final class ReviewStoreTests: XCTestCase {
    @MainActor
    func testDeleteHistoryReviewPreservesCurrentAndSupportsUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-delete-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = ReviewRepository(root: root)
        let store = ReviewStore(repository: repo)
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = try ImageFiles.png(XCTUnwrap(context.makeImage()))
        try store.importImage(data, name: "history.png")
        let historyID = try XCTUnwrap(store.currentReview?.id)
        store.newReview()
        try store.importImage(data, name: "current.png")
        let currentID = try XCTUnwrap(store.currentReview?.id)
        let shot = try XCTUnwrap(store.screenshot)
        store.deleteReview(historyID)
        XCTAssertEqual(store.library.reviews.map(\.id), [currentID])
        XCTAssertEqual(store.screenshot?.id, shot.id)
        let reloaded = try repo.load()
        XCTAssertEqual(reloaded.reviews.map(\.id), [currentID])
        XCTAssertEqual(reloaded.currentReviewID, currentID)
        XCTAssertEqual(reloaded.currentReview?.screenshots.first?.id, shot.id)
        store.undo()
        XCTAssertEqual(store.library.reviews.count, 2)
        store.deleteReview(currentID)
        XCTAssertNil(store.currentReview)
        XCTAssertNil(store.selectedScreenshotID)
        XCTAssertNil(store.selectedIssueID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try repo.assetURL(for: shot).path))
        store.undo()
        XCTAssertEqual(store.currentReview?.id, currentID)
        XCTAssertEqual(store.screenshot?.id, shot.id)
        store.redo()
        XCTAssertNil(store.currentReview)
        store.deleteReview(historyID)
        XCTAssertTrue(store.library.reviews.isEmpty)
        XCTAssertTrue(try repo.load().reviews.isEmpty)
    }

    @MainActor
    func testLoadingThumbnailCacheDoesNotInvalidateViewObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-cache-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ReviewRepository(root: root)
        let setup = ReviewStore(repository: repository)
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = try ImageFiles.png(XCTUnwrap(context.makeImage()))
        try setup.importImage(data, name: "first.png")
        try setup.importImage(data, name: "second.png")
        let restored = ReviewStore(repository: repository)
        let shots = try XCTUnwrap(restored.currentReview?.screenshots)
        var invalidated = false
        withObservationTracking {
            XCTAssertNotNil(restored.image(for: shots[0]))
        } onChange: {
            invalidated = true
        }
        XCTAssertNotNil(restored.image(for: shots[1]))
        XCTAssertFalse(invalidated, "Loading another thumbnail must not invalidate a rendering view")
    }

    @MainActor
    func testImportEditDeleteUndoRedoAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-store-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = ReviewRepository(root: root)
        let store = ReviewStore(repository: repo)
        XCTAssertNil(store.currentReview)
        let ctx = CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try store.importImage(ImageFiles.png(ctx.makeImage()!), name: "test.png")
        let shotID = try XCTUnwrap(store.screenshot?.id)
        let reviewID = try XCTUnwrap(store.currentReview?.id)
        store.addIssue(Region(x: 20, y: 40, width: 50, height: 80))
        let issueID = try XCTUnwrap(store.issue?.id)
        store.updateComment(issueID, comment: "减少留白")
        store.updateRegion(issueID, region: Region(x: 30, y: 40, width: 60, height: 80))
        store.undo()
        XCTAssertEqual(store.issue?.region.x, 20)
        store.redo()
        XCTAssertEqual(store.issue?.region.x, 30)
        store.deleteIssue(issueID)
        XCTAssertEqual(store.screenshot?.issues.count, 0)
        store.undo()
        XCTAssertEqual(store.screenshot?.issues.first?.comment, "减少留白")
        store.deleteScreenshot(shotID)
        XCTAssertEqual(store.currentReview?.screenshots.count, 0)
        store.undo()
        XCTAssertEqual(store.currentReview?.screenshots.count, 1)
        let reloaded = ReviewStore(repository: repo)
        XCTAssertEqual(reloaded.currentReview?.id, reviewID)
        XCTAssertEqual(reloaded.screenshot?.issues.first?.region.x, 30)
        XCTAssertFalse(reloaded.canUndo)
        store.newReview()
        XCTAssertNil(store.currentReview)
        XCTAssertEqual(store.library.reviews.count, 1)
        store.openReview(reviewID)
        XCTAssertEqual(store.currentReview?.id, reviewID)
    }

    @MainActor
    func testCorruptionDisablesWritesAndPreservesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-store-bad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json"), data = Data("{broken".utf8)
        try data.write(to: url)
        let store = ReviewStore(repository: ReviewRepository(root: root))
        XCTAssertTrue(store.loadFailed)
        store.newReview()
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}

extension ReviewStoreTests {
    @MainActor func testFailedSaveRetainsCommentAndRetryDoesNotOverwriteExternalData() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repo=ReviewRepository(root:root),store=ReviewStore(repository:repo)
        let context=try XCTUnwrap(CGContext(data:nil,width:20,height:40,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        try store.importImage(ImageFiles.png(XCTUnwrap(context.makeImage()!)),name:"test.png")
        store.addIssue(Region(x:2,y:2,width:10,height:10))
        let id=try XCTUnwrap(store.issue?.id)
        var external=try repo.load();external.revision=UUID();try repo.save(external)
        store.updateComment(id,comment:"保留我的输入")
        XCTAssertEqual(store.issue?.comment,"保留我的输入");XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(store.retrySave());XCTAssertEqual(try repo.load(),external)
    }
}
