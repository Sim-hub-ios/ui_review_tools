import AppKit
import ReviewCore
import XCTest
@testable import UIReview

final class ClipboardPasteTests: XCTestCase {
    func testImageContentBeatsSelectedAnimation() {
        let image = URL(fileURLWithPath: "/tmp/shot.png")
        let video = URL(fileURLWithPath: "/tmp/clip.mp4")
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [], hasImageData: true, hasSelectedAnimation: true),
            .materials)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [image], hasImageData: false, hasSelectedAnimation: true),
            .materials)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [image, video], hasImageData: false, hasSelectedAnimation: true),
            .materials)
    }

    func testVideoFileUsesReferenceOnlyWhenAnimationIsSelected() {
        let video = URL(fileURLWithPath: "/tmp/clip.mp4")
        let other = URL(fileURLWithPath: "/tmp/clip.MOV")
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [video], hasImageData: false, hasSelectedAnimation: true),
            .referenceVideo)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [other], hasImageData: true, hasSelectedAnimation: true),
            .referenceVideo)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [video], hasImageData: false, hasSelectedAnimation: false),
            .materials)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [video, other], hasImageData: false, hasSelectedAnimation: true),
            .referenceVideo)
    }

    func testEmptyClipboard() {
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [], hasImageData: false, hasSelectedAnimation: true),
            .empty)
        XCTAssertEqual(
            ClipboardPaste.action(fileURLs: [], hasImageData: false, hasSelectedAnimation: false),
            .empty)
    }

    @MainActor
    func testPasteClipboardImportsBitmapWhileAnimationSelected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-image-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try animationStore(root: root)
        XCTAssertNotNil(store.animation)
        XCTAssertNil(store.screenshot)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(try pngData(), forType: .png)

        store.pasteClipboard(from: board)

        XCTAssertEqual(store.currentReview?.screenshots.count, 1)
        XCTAssertEqual(store.currentReview?.animations.count, 1)
        XCTAssertNotNil(store.screenshot)
        XCTAssertNil(store.selectedAnimationID)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testPasteClipboardKeepsReferenceVideoWhenOnlyVideoCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-video-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try animationStore(root: root)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/missing-reference.mp4") as NSURL])

        store.pasteClipboard(from: board)

        XCTAssertEqual(store.currentReview?.screenshots.count, 0)
        XCTAssertEqual(store.currentReview?.animations.count, 1)
        XCTAssertNotNil(store.animation)
        XCTAssertNotEqual(store.status, "剪贴板中没有图片")
    }
}

private extension ClipboardPasteTests {
    func pngData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try ImageFiles.png(XCTUnwrap(context.makeImage()))
    }

    @MainActor
    func animationStore(root: URL) throws -> ReviewStore {
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
        return ReviewStore(repository: repo)
    }
}
