import XCTest

@testable import ReviewCore

final class AlignmentEditorTests: XCTestCase {
  private let referenceID = UUID()
  private let otherReferenceID = UUID()

  func testFirstMarkerStaysUnsavedUntilTheOtherSideIsPlaced() {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    XCTAssertNil(editor.place(.current, at: frame(1.0), playing: false))
    XCTAssertEqual(editor.marker(.current), frame(1.0))
    XCTAssertNil(editor.marker(.reference))
    XCTAssertNil(editor.saved)

    let saved = editor.place(.reference, at: frame(2.5), playing: false)
    XCTAssertEqual(saved?.currentStart, frame(1.0))
    XCTAssertEqual(saved?.referenceStart, frame(2.5))
    XCTAssertEqual(saved?.referenceAssetID, referenceID)
    XCTAssertEqual(editor.saved, saved)
  }

  func testMovingTheOnlyMarkerDoesNotWrite() {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    editor.place(.reference, at: frame(1), playing: false)
    XCTAssertTrue(editor.beginDrag(.reference, playing: false))
    editor.updateDrag(to: frame(1.5))
    XCTAssertNil(editor.endDrag())
    XCTAssertEqual(editor.marker(.reference), frame(1.5))
    XCTAssertNil(editor.saved)
  }

  func testSameFrameDoesNotReplaceTheAlignmentIdentity() {
    var editor = alignedEditor()
    let identity = editor.saved?.alignmentID
    XCTAssertNil(editor.place(.current, at: frame(1), playing: false))
    XCTAssertEqual(editor.saved?.alignmentID, identity)

    XCTAssertTrue(editor.beginDrag(.reference, playing: false))
    editor.updateDrag(to: frame(2))
    XCTAssertNil(editor.endDrag())
    XCTAssertEqual(editor.saved?.alignmentID, identity)
  }

  func testChangedMarkerWritesANewAlignmentAndUndoKeepsTheFirstMarker() {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    editor.place(.current, at: frame(1), playing: false)
    let created = editor.place(.reference, at: frame(2), playing: false)
    editor.noteExternalSave(referenceAssetID: referenceID, saved: nil)
    XCTAssertNil(editor.saved)
    XCTAssertEqual(editor.marker(.current), frame(1))
    XCTAssertNil(editor.marker(.reference))
    XCTAssertEqual(created?.referenceAssetID, referenceID)

    let again = editor.place(.reference, at: frame(3), playing: false)
    XCTAssertNotEqual(again?.alignmentID, created?.alignmentID)
    let moved = editor.place(.current, at: frame(1.25), playing: false)
    XCTAssertEqual(moved?.referenceStart, frame(3))
    XCTAssertNotEqual(moved?.alignmentID, again?.alignmentID)
    editor.noteExternalSave(referenceAssetID: referenceID, saved: again)
    XCTAssertEqual(editor.saved, again)
    XCTAssertEqual(editor.marker(.current), frame(1))
    XCTAssertEqual(editor.marker(.reference), frame(3))
  }

  func testDragPreviewsTheMappingAndCancelRestoresIt() {
    var editor = alignedEditor()
    let identity = editor.saved?.alignmentID
    XCTAssertTrue(editor.beginDrag(.reference, playing: false))
    editor.updateDrag(to: frame(4))
    let preview = editor.presentation(selected: nil)
    XCTAssertEqual(preview.mapping?.referenceStart, frame(4))
    XCTAssertEqual(preview.mapping?.currentStart, frame(1))
    XCTAssertEqual(editor.saved?.alignmentID, identity)
    editor.cancelDrag()
    XCTAssertEqual(editor.marker(.reference), frame(2))
    XCTAssertEqual(editor.saved?.alignmentID, identity)
  }

  func testPlayingAndInspectionIgnoreMarkerEdits() {
    var editor = alignedEditor()
    XCTAssertNil(editor.place(.current, at: frame(3), playing: true))
    XCTAssertFalse(editor.beginDrag(.current, playing: true))
    XCTAssertEqual(editor.marker(.current), frame(1))

    let snapshot = ReferenceAlignment(
      referenceAssetID: otherReferenceID, currentStart: frame(0.2), referenceStart: frame(0.4))
    XCTAssertEqual(editor.clickIssue(snapshot: snapshot, alreadySelected: false), .select)
    XCTAssertNil(editor.place(.reference, at: frame(5), playing: false))
    XCTAssertFalse(editor.beginDrag(.reference, playing: false))
    XCTAssertEqual(editor.marker(.reference), frame(0.4))
  }

  func testRemovingTheAttachmentClearsMarkers() {
    var editor = alignedEditor()
    editor.noteExternalSave(referenceAssetID: nil, saved: nil)
    XCTAssertNil(editor.saved)
    XCTAssertNil(editor.marker(.current))
    XCTAssertNil(editor.marker(.reference))
    let presentation = editor.presentation(selected: nil)
    XCTAssertNil(presentation.referenceAssetID)
    XCTAssertFalse(presentation.showsReferenceTimeline)
  }

  func testIncompleteAlignmentStaysEditableWhileAnIssueIsSelected() {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    editor.place(.current, at: frame(1), playing: false)
    let snapshot = ReferenceAlignment(
      referenceAssetID: otherReferenceID, currentStart: frame(0.2), referenceStart: frame(0.4))
    XCTAssertEqual(editor.clickIssue(snapshot: snapshot, alreadySelected: false), .select)
    let presentation = editor.presentation(selected: AlignmentSelection(snapshot: snapshot))
    XCTAssertEqual(presentation.referenceAssetID, referenceID)
    XCTAssertTrue(presentation.showsReferenceTimeline)
    XCTAssertTrue(presentation.markersEditable)
    XCTAssertEqual(presentation.currentStart, frame(1))
    XCTAssertNil(presentation.referenceStart)
    XCTAssertNil(presentation.mapping)
    XCTAssertEqual(presentation.notice, .previousRelationship)
    XCTAssertEqual(presentation.controls, .focused(.current))
    XCTAssertEqual(editor.focusedSide, .current)
  }

  func testCommittingAlignmentDoesNotEnterInspectionUntilTheIssueIsClickedAgain() {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    let snapshot = ReferenceAlignment(
      referenceAssetID: referenceID, currentStart: frame(0.2), referenceStart: frame(0.4))
    editor.clickIssue(snapshot: snapshot, alreadySelected: false)
    _ = editor.place(.current, at: frame(1), playing: false)
    _ = editor.place(.reference, at: frame(2), playing: false)
    let during = editor.presentation(selected: AlignmentSelection(snapshot: snapshot))
    XCTAssertTrue(during.markersEditable)
    XCTAssertEqual(during.mapping?.currentStart, frame(1))
    XCTAssertEqual(during.notice, .previousRelationship)
    XCTAssertNil(during.placeholder)

    XCTAssertEqual(editor.clickIssue(snapshot: snapshot, alreadySelected: true), .select)
    let inspecting = editor.presentation(selected: AlignmentSelection(snapshot: snapshot))
    XCTAssertFalse(inspecting.markersEditable)
    XCTAssertEqual(inspecting.referenceAssetID, referenceID)
    XCTAssertEqual(inspecting.currentStart, frame(0.2))
    XCTAssertEqual(inspecting.referenceStart, frame(0.4))
    XCTAssertEqual(inspecting.controls, .current)

    XCTAssertEqual(editor.clickIssue(snapshot: snapshot, alreadySelected: true), .deselect)
    let restored = editor.presentation(selected: nil)
    XCTAssertTrue(restored.markersEditable)
    XCTAssertEqual(restored.currentStart, frame(1))
    XCTAssertEqual(restored.referenceStart, frame(2))
  }

  func testMissingSnapshotInspectionHidesTheReferenceColumn() {
    var editor = alignedEditor()
    XCTAssertEqual(editor.clickIssue(snapshot: nil, alreadySelected: false), .select)
    let presentation = editor.presentation(selected: AlignmentSelection(snapshot: nil))
    XCTAssertNil(presentation.referenceAssetID)
    XCTAssertFalse(presentation.showsReferenceTimeline)
    XCTAssertFalse(presentation.showsStartMarkers)
    XCTAssertEqual(presentation.placeholder, "此问题没有参考对齐")
    XCTAssertEqual(presentation.notice, .missingReference)
    XCTAssertEqual(presentation.noticeAction, "使用当前对齐")
    XCTAssertNil(presentation.mapping)
    XCTAssertEqual(presentation.controls, .current)
  }

  func testAdoptingTheCurrentAlignmentLeavesInspection() {
    var editor = alignedEditor()
    editor.clickIssue(snapshot: nil, alreadySelected: false)
    editor.adoptCurrentAlignment()
    let presentation = editor.presentation(
      selected: AlignmentSelection(snapshot: editor.saved))
    XCTAssertTrue(presentation.markersEditable)
    XCTAssertEqual(presentation.notice, .none)
    XCTAssertEqual(presentation.referenceAssetID, referenceID)
    XCTAssertTrue(presentation.showsReferenceTimeline)
  }

  func testMatchedIssueStaysSelectedAndEmptyTrackPromptsForAStart() {
    var editor = alignedEditor()
    let snapshot = editor.saved
    XCTAssertEqual(editor.clickIssue(snapshot: snapshot, alreadySelected: true), .select)
    XCTAssertEqual(editor.presentation(selected: AlignmentSelection(snapshot: snapshot)).notice, .none)

    var fresh = AlignmentEditor(referenceAssetID: referenceID)
    XCTAssertEqual(fresh.presentation(selected: nil).emptyTrackLabel(for: .reference), "点击设置起点")
    fresh.place(.reference, at: frame(1), playing: false)
    XCTAssertNil(fresh.presentation(selected: nil).emptyTrackLabel(for: .reference))
    XCTAssertEqual(fresh.presentation(selected: nil).emptyTrackLabel(for: .current), "点击设置起点")
  }

  func testRelativeCaptionUsesTheMappingOnScreen() {
    var editor = alignedEditor()
    XCTAssertEqual(editor.relativeCaption(currentSeconds: 1.668), "起点后 668 ms")
    XCTAssertEqual(editor.relativeCaption(currentSeconds: 0.4), "起点前 600 ms")
    editor.clickIssue(
      snapshot: ReferenceAlignment(
        referenceAssetID: referenceID, currentStart: frame(0.5), referenceStart: frame(0.5)),
      alreadySelected: false)
    XCTAssertEqual(editor.relativeCaption(currentSeconds: 0.2), "起点前 300 ms")

    var unaligned = AlignmentEditor(referenceAssetID: referenceID)
    XCTAssertNil(unaligned.relativeCaption(currentSeconds: 1))
  }

  func testDetachedReferenceIsKeptAndLegacyAlignmentStillResolves() throws {
    let current = asset()
    let reference = asset()
    var animation = Animation(name: "clip", currentAssetID: current.id)
    animation.referenceAssetID = reference.id
    var review = Review(title: "保留参考")
    review.animations = [animation]
    review.videoAssets = [current, reference]
    review.pruneUnusedVideoAssets()
    XCTAssertEqual(Set(review.videoAssets.map(\.id)), [current.id, reference.id])

    let encoded = try JSONEncoder().encode(animation)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let decoded = try JSONDecoder().decode(Animation.self, from: encoded)
    XCTAssertEqual(decoded.referenceAssetID, reference.id)
    XCTAssertEqual(decoded.resolvedReferenceAssetID, reference.id)

    animation.referenceAssetID = nil
    animation.activeReference = ReferenceAlignment(
      referenceAssetID: reference.id, currentStart: frame(0), referenceStart: frame(0))
    let legacyEncoded = try JSONEncoder().encode(animation)
    object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyEncoded) as? [String: Any])
    object.removeValue(forKey: "referenceAssetID")
    let legacy = try JSONDecoder().decode(
      Animation.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.referenceAssetID)
    XCTAssertEqual(legacy.resolvedReferenceAssetID, reference.id)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var libraryReview = review
    libraryReview.animations = [animation]
    libraryReview.reconcileOrder()
    let repo = ReviewRepository(root: root)
    XCTAssertNoThrow(try repo.validate(ReviewLibrary(currentReviewID: libraryReview.id, reviews: [libraryReview])))
    libraryReview.animations[0].referenceAssetID = UUID()
    XCTAssertThrowsError(
      try repo.validate(ReviewLibrary(currentReviewID: libraryReview.id, reviews: [libraryReview])))
  }

  private func alignedEditor() -> AlignmentEditor {
    var editor = AlignmentEditor(referenceAssetID: referenceID)
    editor.place(.current, at: frame(1), playing: false)
    _ = editor.place(.reference, at: frame(2), playing: false)
    return editor
  }

  private func frame(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

  private func asset() -> VideoAsset {
    let id = UUID()
    return VideoAsset(
      id: id, originalName: "\(id).mov", path: "assets/videos/\(id).mov",
      sha256: String(repeating: "ab", count: 32), byteLength: 100, container: "mov", codec: "h264",
      trackID: 1, timelineOrigin: .zero, duration: MediaTime(seconds: 8), encodedWidth: 100,
      encodedHeight: 200, displayWidth: 100, displayHeight: 200,
      preferredTransform: VideoTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0), nominalFrameRate: 30)
  }
}
