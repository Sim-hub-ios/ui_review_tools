import Foundation

public enum AlignmentSide: String, Equatable, Sendable {
  case reference
  case current
}

public enum IssueClick: Equatable, Sendable {
  case select
  case deselect
}

public enum AlignmentNotice: Equatable, Sendable {
  case none
  case missingReference
  case previousRelationship
}

public enum AlignmentControls: Equatable, Sendable {
  case current
  case focused(AlignmentSide)
}

public struct TimeMapping: Equatable, Sendable {
  public var currentStart: MediaTime
  public var referenceStart: MediaTime
  public init(currentStart: MediaTime, referenceStart: MediaTime) {
    self.currentStart = currentStart
    self.referenceStart = referenceStart
  }
  public func referenceSeconds(forCurrent seconds: Double) -> Double {
    seconds - currentStart.seconds + referenceStart.seconds
  }
}

public struct AlignmentSelection: Equatable, Sendable {
  public var snapshot: ReferenceAlignment?
  public init(snapshot: ReferenceAlignment?) { self.snapshot = snapshot }
}

public struct AlignmentPresentation: Equatable, Sendable {
  public var referenceAssetID: UUID?
  public var showsReferenceTimeline: Bool
  public var showsStartMarkers: Bool
  public var markersEditable: Bool
  public var referenceStart: MediaTime?
  public var currentStart: MediaTime?
  public var mapping: TimeMapping?
  public var notice: AlignmentNotice
  public var noticeAction: String?
  public var placeholder: String?
  public var controls: AlignmentControls
  public func emptyTrackLabel(for side: AlignmentSide) -> String? {
    guard markersEditable else { return nil }
    let missing = side == .reference ? referenceStart == nil : currentStart == nil
    return missing ? "点击设置起点" : nil
  }
}

public struct AlignmentEditor: Sendable {
  public internal(set) var referenceAssetID: UUID?
  public internal(set) var saved: ReferenceAlignment?
  public internal(set) var focusedSide = AlignmentSide.current
  private var draftCurrent: MediaTime?
  private var draftReference: MediaTime?
  private var firstSide: AlignmentSide?
  private var inspecting = false
  private var inspectedSnapshot: ReferenceAlignment?
  private var drag: Drag?

  private struct Drag {
    var side: AlignmentSide
    var origin: MediaTime
    var time: MediaTime
  }

  public init(referenceAssetID: UUID?) {
    self.referenceAssetID = referenceAssetID
  }

  public func marker(_ side: AlignmentSide) -> MediaTime? {
    if inspecting {
      guard let inspectedSnapshot else { return nil }
      return side == .current ? inspectedSnapshot.currentStart : inspectedSnapshot.referenceStart
    }
    if let drag, drag.side == side { return drag.time }
    return side == .current ? draftCurrent : draftReference
  }

  @discardableResult
  public mutating func place(_ side: AlignmentSide, at time: MediaTime, playing: Bool)
    -> ReferenceAlignment?
  {
    guard !playing, !inspecting else { return nil }
    if let existing = marker(side), existing.equivalent(to: time) { return nil }
    let hadMarker = draftCurrent != nil || draftReference != nil
    assign(side, time)
    if !hadMarker { firstSide = side }
    return commitIfBothPresent()
  }

  public mutating func beginDrag(_ side: AlignmentSide, playing: Bool) -> Bool {
    guard !playing, !inspecting, let origin = marker(side) else { return false }
    drag = Drag(side: side, origin: origin, time: origin)
    return true
  }

  public mutating func updateDrag(to time: MediaTime) {
    drag?.time = time
  }

  @discardableResult
  public mutating func endDrag() -> ReferenceAlignment? {
    guard let drag else { return nil }
    self.drag = nil
    if drag.time.equivalent(to: drag.origin) { return nil }
    assign(drag.side, drag.time)
    return commitIfBothPresent()
  }

  public mutating func cancelDrag() { drag = nil }

  public mutating func focus(_ side: AlignmentSide) {
    guard saved == nil, !inspecting, referenceAssetID != nil else { return }
    focusedSide = side
  }

  @discardableResult
  public mutating func clickIssue(snapshot: ReferenceAlignment?, alreadySelected: Bool) -> IssueClick {
    guard saved != nil else {
      inspecting = false
      inspectedSnapshot = nil
      focusedSide = .current
      return .select
    }
    if snapshot == saved {
      inspecting = false
      inspectedSnapshot = nil
      return .select
    }
    if inspecting && alreadySelected {
      inspecting = false
      inspectedSnapshot = nil
      return .deselect
    }
    inspecting = true
    inspectedSnapshot = snapshot
    return .select
  }

  public mutating func adoptCurrentAlignment() {
    inspecting = false
    inspectedSnapshot = nil
  }

  public mutating func clearInspection() {
    inspecting = false
    inspectedSnapshot = nil
  }

  public mutating func noteExternalSave(referenceAssetID: UUID?, saved: ReferenceAlignment?) {
    drag = nil
    if saved == nil, let previous = self.saved, let firstSide, referenceAssetID != nil {
      switch firstSide {
      case .current:
        draftCurrent = previous.currentStart
        draftReference = nil
      case .reference:
        draftReference = previous.referenceStart
        draftCurrent = nil
      }
      self.saved = nil
      self.referenceAssetID = referenceAssetID
      inspecting = false
      inspectedSnapshot = nil
      return
    }
    if saved == nil, self.saved == nil, referenceAssetID != nil {
      self.referenceAssetID = referenceAssetID
      return
    }
    self.referenceAssetID = referenceAssetID ?? saved?.referenceAssetID
    self.saved = saved
    if let saved {
      draftCurrent = saved.currentStart
      draftReference = saved.referenceStart
      if firstSide == nil { firstSide = .current }
    } else {
      draftCurrent = nil
      draftReference = nil
      firstSide = nil
      inspecting = false
      inspectedSnapshot = nil
      focusedSide = .current
    }
  }

  public func presentation(selected: AlignmentSelection?) -> AlignmentPresentation {
    let notice = notice(for: selected)
    if inspecting, let selected {
      if let snapshot = selected.snapshot {
        return AlignmentPresentation(
          referenceAssetID: snapshot.referenceAssetID, showsReferenceTimeline: true,
          showsStartMarkers: true, markersEditable: false, referenceStart: snapshot.referenceStart,
          currentStart: snapshot.currentStart,
          mapping: TimeMapping(
            currentStart: snapshot.currentStart, referenceStart: snapshot.referenceStart),
          notice: notice.kind, noticeAction: notice.action, placeholder: nil, controls: .current)
      }
      return AlignmentPresentation(
        referenceAssetID: nil, showsReferenceTimeline: false, showsStartMarkers: false,
        markersEditable: false, referenceStart: nil, currentStart: nil, mapping: nil,
        notice: notice.kind, noticeAction: notice.action, placeholder: "此问题没有参考对齐",
        controls: .current)
    }
    let currentStart = marker(.current)
    let referenceStart = marker(.reference)
    let mapping =
      referenceAssetID != nil
      ? currentStart.flatMap { current in
        referenceStart.map { TimeMapping(currentStart: current, referenceStart: $0) }
      } : nil
    let visible = referenceAssetID != nil
    return AlignmentPresentation(
      referenceAssetID: visible ? referenceAssetID : nil, showsReferenceTimeline: visible,
      showsStartMarkers: visible, markersEditable: visible,
      referenceStart: visible ? referenceStart : nil, currentStart: visible ? currentStart : nil,
      mapping: mapping, notice: notice.kind, noticeAction: notice.action, placeholder: nil,
      controls: visible && saved == nil ? .focused(focusedSide) : .current)
  }

  public func relativeCaption(currentSeconds: Double) -> String? {
    let mapping = presentation(
      selected: inspecting ? AlignmentSelection(snapshot: inspectedSnapshot) : nil
    ).mapping
    guard let mapping else { return nil }
    let milliseconds = Int(((currentSeconds - mapping.currentStart.seconds) * 1000).rounded())
    if milliseconds < 0 { return "起点前 \(-milliseconds) ms" }
    return "起点后 \(milliseconds) ms"
  }

  private mutating func assign(_ side: AlignmentSide, _ time: MediaTime) {
    switch side {
    case .current: draftCurrent = time
    case .reference: draftReference = time
    }
  }

  private mutating func commitIfBothPresent() -> ReferenceAlignment? {
    guard let referenceAssetID, let draftCurrent, let draftReference else { return nil }
    let alignment = ReferenceAlignment(
      referenceAssetID: referenceAssetID, currentStart: draftCurrent, referenceStart: draftReference)
    saved = alignment
    return alignment
  }

  private func notice(for selected: AlignmentSelection?) -> (kind: AlignmentNotice, action: String?) {
    guard let selected, selected.snapshot != saved else { return (.none, nil) }
    if selected.snapshot == nil { return (.missingReference, "使用当前对齐") }
    return (.previousRelationship, "使用新的对齐方式")
  }
}
