import AppKit
import CoreGraphics
import ReviewCore
import XCTest

@testable import UIReview

final class HandoffPromptTests: XCTestCase {
    func testDisabledWhenReviewMissingOrHasNoMaterials() {
        XCTAssertFalse(HandoffPrompt.isEnabled(nil))
        XCTAssertFalse(HandoffPrompt.isEnabled(Review(title: "空")))
    }

    func testEnabledForScreenshotOnlyAnimationOnlyOrMixed() {
        XCTAssertTrue(HandoffPrompt.isEnabled(mixedReview().review))
        XCTAssertTrue(HandoffPrompt.isEnabled(screenshotOnlyReview().review))
        XCTAssertTrue(HandoffPrompt.isEnabled(animationOnlyReview().review))
    }

    func testEnabledWhenSelectedItemHasZeroIssues() {
        let shot = Screenshot(id: UUID(), name: "blank.png", pixelWidth: 10, pixelHeight: 10, originalPath: "assets/a.png")
        XCTAssertTrue(shot.issues.isEmpty)
        XCTAssertTrue(HandoffPrompt.isEnabled(Review(title: "无问题", screenshots: [shot])))
    }

    func testCurrentItemProjectionKeepsOnlySelectedScreenshot() {
        let fixture = mixedReview()
        let projected = HandoffPrompt.projected(fixture.review, itemID: fixture.shotA.id, scope: .currentItem)
        XCTAssertEqual(projected.screenshots.map(\.id), [fixture.shotA.id])
        XCTAssertTrue(projected.animations.isEmpty)
        XCTAssertTrue(projected.videoAssets.isEmpty)
        XCTAssertEqual(projected.itemOrder.map(\.id), [fixture.shotA.id])
    }

    func testCurrentItemProjectionKeepsSelectedAnimationAndItsAssets() {
        let fixture = mixedReview()
        let projected = HandoffPrompt.projected(fixture.review, itemID: fixture.animA.id, scope: .currentItem)
        XCTAssertTrue(projected.screenshots.isEmpty)
        XCTAssertEqual(projected.animations.map(\.id), [fixture.animA.id])
        XCTAssertEqual(Set(projected.videoAssets.map(\.id)), [fixture.assetA.id, fixture.refAsset.id])
        XCTAssertFalse(projected.videoAssets.contains { $0.id == fixture.unusedAsset.id })
        XCTAssertFalse(projected.videoAssets.contains { $0.id == fixture.assetB.id })
    }

    func testWholeReviewProjectionKeepsMixedScreenshotsAndAnimations() {
        let fixture = mixedReview()
        let projected = HandoffPrompt.projected(fixture.review, itemID: fixture.shotA.id, scope: .wholeReview)
        XCTAssertEqual(projected.screenshots.map(\.id), [fixture.shotA.id, fixture.shotB.id])
        XCTAssertEqual(projected.animations.map(\.id), [fixture.animA.id, fixture.animB.id])
        XCTAssertEqual(
            Set(projected.videoAssets.map(\.id)),
            [fixture.assetA.id, fixture.assetB.id, fixture.refAsset.id])
        XCTAssertFalse(projected.videoAssets.contains { $0.id == fixture.unusedAsset.id })
    }

    func testPromptForCurrentItemUsesSelectedIDsAndPendingCount() {
        let fixture = mixedReview()
        let projected = HandoffPrompt.projected(fixture.review, itemID: fixture.shotA.id, scope: .currentItem)
        let revision = UUID()
        let text = HandoffPrompt.text(review: projected, revision: revision, scope: .currentItem)
        XCTAssertEqual(
            text,
            expectedPrompt(
                reviewID: fixture.review.id, scope: "当前素材",
                shotIDs: [fixture.shotA.id], animIDs: [], revision: revision, pending: 1))
        XCTAssertEqual(HandoffPrompt.pendingCount(projected), 1)
    }

    func testPromptForWholeReviewListsAllIDsAndPendingComments() {
        let fixture = mixedReview()
        let revision = UUID()
        let text = HandoffPrompt.text(review: fixture.review, revision: revision, scope: .wholeReview)
        XCTAssertEqual(
            text,
            expectedPrompt(
                reviewID: fixture.review.id, scope: "整个 Review",
                shotIDs: [fixture.shotA.id, fixture.shotB.id],
                animIDs: [fixture.animA.id, fixture.animB.id],
                revision: revision, pending: 2))
        XCTAssertEqual(HandoffPrompt.pendingCount(fixture.review), 2)
    }

    func testCopyStatusDistinguishesScope() {
        XCTAssertEqual(HandoffPrompt.copyStatus(for: .currentItem), "已复制当前素材交接提示词")
        XCTAssertEqual(HandoffPrompt.copyStatus(for: .wholeReview), "已复制整个 Review 交接提示词")
    }

    func testExportWarningUsesFullRecordingCopy() {
        let bytes: Int64 = 12_345_678
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        XCTAssertEqual(
            HandoffPrompt.exportWarning(byteLength: bytes),
            "将导出完整录屏，约 \(size)，另加图片与证据文件")
        XCTAssertTrue(HandoffPrompt.needsVideoExportConfirmation(mixedReview().review))
        XCTAssertFalse(HandoffPrompt.needsVideoExportConfirmation(screenshotOnlyReview().review))
    }

    @MainActor
    func testCopyCurrentItemWritesPromptAndStatus() throws {
        let store = try screenshotStore()
        let shotID = try XCTUnwrap(store.selectedScreenshotID)
        let review = try XCTUnwrap(store.currentReview)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        store.copyHandoff(.currentItem, to: board)

        XCTAssertEqual(store.status, "已复制当前素材交接提示词")
        XCTAssertEqual(
            board.string(forType: .string),
            HandoffPrompt.text(review: review, revision: store.library.revision, scope: .currentItem))
        XCTAssertEqual(shotID, review.screenshots[0].id)
    }

    @MainActor
    func testCopyWholeReviewWritesPromptAndStatus() throws {
        let store = try screenshotStore()
        let review = try XCTUnwrap(store.currentReview)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        store.copyHandoff(.wholeReview, to: board)

        XCTAssertEqual(store.status, "已复制整个 Review 交接提示词")
        XCTAssertEqual(
            board.string(forType: .string),
            HandoffPrompt.text(review: review, revision: store.library.revision, scope: .wholeReview))
    }
}

private extension HandoffPromptTests {
    struct MixedFixture {
        var review: Review
        var shotA: Screenshot
        var shotB: Screenshot
        var animA: ReviewCore.Animation
        var animB: ReviewCore.Animation
        var assetA: VideoAsset
        var assetB: VideoAsset
        var refAsset: VideoAsset
        var unusedAsset: VideoAsset
    }

    func videoAsset(_ id: UUID) -> VideoAsset {
        VideoAsset(
            id: id, originalName: "\(id).mp4", path: "assets/videos/\(id).mp4",
            sha256: String(repeating: "a", count: 64), byteLength: 2048, container: "mp4",
            codec: "h264", trackID: 1, timelineOrigin: .zero, duration: MediaTime(seconds: 2),
            encodedWidth: 100, encodedHeight: 200, displayWidth: 100, displayHeight: 200,
            preferredTransform: VideoTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
            nominalFrameRate: 30)
    }

    func mixedReview() -> MixedFixture {
        let shotA = Screenshot(
            id: UUID(), name: "a.png", pixelWidth: 10, pixelHeight: 10, originalPath: "assets/a.png",
            issues: [Issue(region: Region(x: 1, y: 1, width: 4, height: 4), comment: "   ", imageWidth: 10, imageHeight: 10)])
        let shotB = Screenshot(
            id: UUID(), name: "b.png", pixelWidth: 10, pixelHeight: 10, originalPath: "assets/b.png",
            issues: [Issue(region: Region(x: 1, y: 1, width: 4, height: 4), comment: "按钮太大", imageWidth: 10, imageHeight: 10)])
        let assetA = videoAsset(UUID())
        let assetB = videoAsset(UUID())
        let refAsset = videoAsset(UUID())
        let unusedAsset = videoAsset(UUID())
        var animA = ReviewCore.Animation(name: "anim-a", currentAssetID: assetA.id)
        var pending = AnimationIssue(target: .point(MediaTime(seconds: 0.2)))
        pending.comment = ""
        pending.referenceSnapshot = ReferenceAlignment(
            referenceAssetID: refAsset.id, currentStart: .zero, referenceStart: .zero)
        animA.issues = [pending]
        var animB = ReviewCore.Animation(name: "anim-b", currentAssetID: assetB.id)
        var filled = AnimationIssue(target: .point(MediaTime(seconds: 0.4)))
        filled.comment = "停顿太久"
        animB.issues = [filled]
        var review = Review(title: "混合", screenshots: [shotA, shotB])
        review.animations = [animA, animB]
        review.videoAssets = [assetA, assetB, refAsset, unusedAsset]
        review.reconcileOrder()
        return MixedFixture(
            review: review, shotA: shotA, shotB: shotB, animA: animA, animB: animB,
            assetA: assetA, assetB: assetB, refAsset: refAsset, unusedAsset: unusedAsset)
    }

    func screenshotOnlyReview() -> MixedFixture {
        var fixture = mixedReview()
        fixture.review.animations = []
        fixture.review.videoAssets = []
        fixture.review.reconcileOrder()
        return fixture
    }

    func animationOnlyReview() -> MixedFixture {
        var fixture = mixedReview()
        fixture.review.screenshots = []
        fixture.review.reconcileOrder()
        return fixture
    }

    func expectedPrompt(
        reviewID: UUID, scope: String, shotIDs: [UUID], animIDs: [UUID], revision: UUID, pending: Int
    ) -> String {
        let shots = shotIDs.map(\.uuidString).joined(separator: ", ")
        let ids = animIDs.map(\.uuidString).joined(separator: ", ")
        return "请立刻修复 ui-review MCP 中 Review \(reviewID.uuidString) 记录的问题，并直接修改当前项目代码。范围：\(scope)；截图 ID：[\(shots)]；动画 ID：[\(ids)]。已保存 revision：\(revision.uuidString)。先读取证据再改：截图用 get_review/get_screenshot；动画用 get_animation（expected_revision 为上述 revision）、get_animation_frame/get_animation_frames 获取原帧、区域图和参考证据。按每条原始评论逐项修改，不要只总结或等待确认。\(pending) 项描述待填写，这些先跳过。缺失证据或 revision 变化的条目说明原因后继续处理其余问题，不猜测动画参数。"
    }

    @MainActor
    func screenshotStore() throws -> ReviewStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-prompt-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ReviewStore(repository: ReviewRepository(root: root))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try store.importImage(ImageFiles.png(XCTUnwrap(context.makeImage())), name: "shot.png")
        return store
    }
}
