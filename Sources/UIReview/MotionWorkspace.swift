import AVFoundation
import AppKit
import ReviewCore
import ReviewMedia
import SwiftUI

struct MotionWorkspace: View {
  @Bindable var store: ReviewStore
  let animation: ReviewCore.Animation
  @State private var session = MotionSession()
  @State private var startDragArmed = false
  private var selection: AlignmentSelection? {
    store.motionIssue.map { AlignmentSelection(snapshot: $0.referenceSnapshot) }
  }
  private var presentation: AlignmentPresentation {
    store.alignmentEditor.presentation(selected: selection)
  }
  private var transportSide: AlignmentSide {
    if case .focused(let side) = presentation.controls { return side }
    return .current
  }
  private var playbackActive: Bool { session.playing || session.referencePlaying }
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack {
          Text(animation.name).lineLimit(1)
          Picker("工具", selection: $store.tool) {
            Text("选择 V").tag(CanvasTool.select)
            Text("框选 R").tag(CanvasTool.rectangle)
          }
          .pickerStyle(.segmented).frame(width: 155).disabled(session.loading)
          Spacer()
          if animation.resolvedReferenceAssetID != nil {
            Button("移除参考") { store.removeReference() }
          } else {
            Button("添加参考视频") { store.chooseReference() }.disabled(store.isBusy)
          }
        }.padding(12).background(.bar)
        HStack(alignment: .top, spacing: 8) {
          if presentation.placeholder != nil || presentation.showsReferenceTimeline {
            referenceColumn
          }
          currentColumn
        }.padding(.horizontal, 8).frame(maxHeight: .infinity)
          .background(Color(nsColor: .windowBackgroundColor))
        transport
      }.frame(minWidth: 500, maxWidth: .infinity)
      Divider()
      MotionIssuePanel(store: store, session: session).frame(width: 300)
    }
    .task(id: configurationID) {
      let initial = session.asset == nil
      let resume = initial ? nil : session.time
      guard let review = store.currentReview else { return }
      await session.configure(
        animation, review: review, repository: store.repository,
        referenceAssetID: presentation.referenceAssetID, alignment: displayedAlignment,
        resume: resume)
      if let issue = store.motionIssue, initial || !presentation.markersEditable {
        if let start = issue.target.start, let end = issue.target.end {
          session.rangeStart = start.seconds
          session.rangeEnd = end.seconds
          session.useRange = true
        }
        session.seek(issue.target.first)
      }
    }
    .onAppear {
      store.syncAlignmentEditor()
      store.motionKeyAction = { key in
        if key == 49 { session.transportToggle(transportSide) }
        else { session.transportStep(key == 123 ? -1 : 1, side: transportSide) }
      }
    }
    .onDisappear { session.stop(); store.motionKeyAction = nil }
    .onChange(of: store.tool) { _, tool in
      if tool == .rectangle && session.playing { session.seek(session.time) }
    }
    .onChange(of: store.selectedIssueID) { _, id in
      guard let issue = store.motionIssue, id == issue.id else { return }
      session.seek(issue.target.first)
    }
  }
  private var configurationID: String {
    let saved = store.alignmentEditor.saved?.alignmentID.uuidString ?? "none"
    let reference = presentation.referenceAssetID?.uuidString ?? "none"
    let inspected = presentation.markersEditable ? "edit" : "inspect-\(store.motionIssue?.id.uuidString ?? "none")"
    return "\(animation.id)-\(reference)-\(saved)-\(inspected)"
  }
  private var displayedAlignment: ReferenceAlignment? {
    if !presentation.markersEditable { return store.motionIssue?.referenceSnapshot }
    return store.alignmentEditor.saved
  }
  private var referenceColumn: some View {
    VStack(spacing: 8) {
      if let placeholder = presentation.placeholder {
        ContentUnavailableView(placeholder, systemImage: "video.slash")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text("参考 · \(referenceClock)").font(.caption).foregroundStyle(.secondary)
        referencePicture.frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onTapGesture { store.focusAlignment(.reference) }
        if let status = session.referenceStatus {
          Text(status).font(.caption).foregroundStyle(.orange)
        }
        if presentation.showsReferenceTimeline, let asset = session.reference {
          timeline(
            asset: asset, frames: session.referenceFrames, time: referencePlayhead,
            side: .reference, showsIssues: false, showsRange: false)
        }
      }
    }.frame(maxWidth: .infinity).padding(8)
      .overlay(focusBorder(transportSide == .reference && presentation.controls != .current))
  }
  @ViewBuilder private var referencePicture: some View {
    if session.referencePlaying || (session.playing && session.alignment != nil) {
      MotionPlayerView(player: session.referencePlayer, onPointerDown: { store.focusAlignment(.reference) })
        .disabled(true)
    } else if let image = session.referenceImage {
      Image(nsImage: image).resizable().scaledToFit().padding(24)
    } else if session.loading {
      ProgressView()
    } else {
      ContentUnavailableView("此时间无画面", systemImage: "video.slash")
    }
  }
  private var currentColumn: some View {
    VStack(spacing: 8) {
      Text("当前实现 · \(session.time.seconds, specifier: "%.3f") s").font(.caption).foregroundStyle(.secondary)
      Group {
        if session.playing {
          MotionPlayerView(
            player: session.player, onPaste: { store.pasteClipboard() },
            onPointerDown: { store.focusAlignment(.current) })
        } else if !session.loading, let asset = session.asset, let image = session.image {
          MotionCanvas(
            store: store, asset: asset, time: session.time, image: image, target: session.target)
        } else if session.loading {
          ProgressView("正在加载当前帧…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text(session.message ?? "暂无画面").foregroundStyle(.secondary).frame(
            maxWidth: .infinity, maxHeight: .infinity)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      if let asset = session.asset {
        timeline(
          asset: asset, frames: session.frames, time: session.time, side: .current,
          showsIssues: true, showsRange: true)
      }
    }.frame(maxWidth: .infinity).padding(8)
      .overlay(focusBorder(transportSide == .current && presentation.controls != .current))
  }
  private var transport: some View {
    VStack(spacing: 12) {
      HStack {
        Button("上一帧") { session.transportStep(-1, side: transportSide) }
        Button(playTitle) { session.transportToggle(transportSide) }.buttonStyle(.borderedProminent)
        Button("下一帧") { session.transportStep(1, side: transportSide) }
        Picker("倍速", selection: $session.speed) {
          ForEach([Float(0.25), 0.5, 1, 2], id: \.self) {
            Text("\($0, specifier: "%.2g")×").tag($0)
          }
        }.frame(width: 90)
        Spacer()
        Text(bottomClock).monospacedDigit()
      }
      HStack {
        Toggle("时间段", isOn: $session.useRange).toggleStyle(.checkbox)
        if session.useRange {
          TextField("开始", value: $session.rangeStart, format: .number.precision(.fractionLength(3)))
            .frame(width: 65)
          Text("–")
          TextField("结束", value: $session.rangeEnd, format: .number.precision(.fractionLength(3)))
            .frame(width: 65)
          Text("秒").foregroundStyle(.secondary)
        } else {
          Text("当前帧时间点").foregroundStyle(.secondary)
        }
        Spacer()
      }.textFieldStyle(.roundedBorder)
    }.font(.caption).padding(16).background(.background).disabled(session.frames.isEmpty)
  }
  private var playTitle: String {
    if playbackActive { return "暂停" }
    if transportSide == .current && session.useRange { return "播放此段" }
    return "播放"
  }
  private var bottomClock: String {
    if let caption = store.alignmentEditor.relativeCaption(currentSeconds: session.time.seconds) {
      return caption
    }
    if transportSide == .reference { return clock(session.referenceTime) }
    return String(format: "%.3f s", session.time.seconds)
  }
  private var referenceClock: String {
    guard let mapping = presentation.mapping else { return clock(session.referenceTime) }
    let seconds = mapping.referenceSeconds(forCurrent: session.time.seconds)
    return seconds < 0 ? "—" : String(format: "%.3f s", seconds)
  }
  private var referencePlayhead: MediaTime {
    guard let mapping = presentation.mapping else { return session.referenceTime ?? .zero }
    return session.nearestReference(mapping.referenceSeconds(forCurrent: session.time.seconds))
  }
  private func clock(_ time: MediaTime?) -> String {
    time.map { String(format: "%.3f s", $0.seconds) } ?? "—"
  }
  private func focusBorder(_ active: Bool) -> some View {
    RoundedRectangle(cornerRadius: 10).stroke(active ? Color.accentColor : .clear, lineWidth: 2)
  }
  private func timeline(
    asset: VideoAsset, frames: [MediaTime], time: MediaTime, side: AlignmentSide,
    showsIssues: Bool, showsRange: Bool
  ) -> some View {
    MotionTimelineStrip(
      asset: asset, repository: store.repository, frames: frames, time: time,
      issues: store.animation?.issues ?? [], showsIssues: showsIssues, showsRange: showsRange,
      useRange: $session.useRange, rangeStart: $session.rangeStart, rangeEnd: $session.rangeEnd,
      startMarker: side == .reference ? presentation.referenceStart : presentation.currentStart,
      startEditable: presentation.markersEditable && !playbackActive,
      emptyStartLabel: presentation.emptyTrackLabel(for: side),
      onSeek: { seek($0, side: side) },
      onPlaceStart: { place($0, side: side) },
      onUpdateStart: { updateStart($0, side: side) },
      onEndStart: endStart,
      onCancelStart: cancelStart
    ).disabled(frames.isEmpty)
  }
  private func seek(_ time: MediaTime, side: AlignmentSide) {
    store.focusAlignment(side)
    if let mapping = presentation.mapping, side == .reference {
      session.seekCurrent(forReferenceTime: time, mapping: mapping)
    } else if side == .reference {
      session.seekReference(time)
    } else {
      session.seek(time)
    }
  }
  private func place(_ time: MediaTime, side: AlignmentSide) {
    store.placeAlignmentMarker(side, at: time, playing: playbackActive)
    refreshReferencePreview()
  }
  private func updateStart(_ time: MediaTime, side: AlignmentSide) {
    if !startDragArmed {
      startDragArmed = store.beginAlignmentDrag(side, playing: playbackActive)
    }
    guard startDragArmed else { return }
    store.updateAlignmentDrag(to: time)
    refreshReferencePreview()
  }
  private func endStart() {
    store.endAlignmentDrag()
    startDragArmed = false
    refreshReferencePreview()
  }
  private func cancelStart() {
    store.cancelAlignmentDrag()
    startDragArmed = false
    refreshReferencePreview()
  }
  private func refreshReferencePreview() {
    if let mapping = store.alignmentEditor.presentation(selected: selection).mapping {
      session.previewMapping(mapping)
    }
  }
}

struct MotionCanvas: NSViewRepresentable {
  let store: ReviewStore
  let asset: VideoAsset
  let time: MediaTime
  let image: NSImage
  let target: TemporalTarget
  func makeNSView(context: Context) -> CanvasView { CanvasView() }
  func updateNSView(_ view: CanvasView, context: Context) {
    let regions = (store.animation?.issues ?? []).filter {
      $0.region?.actualTime.equivalent(to: time) == true
    }
    let shot = Screenshot(
      id: asset.id, name: asset.originalName, pixelWidth: asset.displayWidth,
      pixelHeight: asset.displayHeight, originalPath: "",
      issues: regions.compactMap { issue in
        guard let r = issue.region else { return nil }
        return Issue(
          id: issue.id, region: r.pixelRect, comment: issue.comment, imageWidth: r.frameWidth,
          imageHeight: r.frameHeight)
      })
    if view.screenshot?.id != shot.id || view.image !== image { view.cancelDrag() }
    view.screenshot = shot
    view.image = image
    view.selectedID = store.selectedIssueID
    view.tool = store.tool
    view.zoom = 0
    view.onSelect = { id in if let id { store.selectedIssueID = id } }
    view.onCreate = { rect in
      store.applyMotionBoxSelection(rect, asset: asset, time: time, target: target)
    }
    view.onUpdate = { id, rect in
      store.updateMotionIssue(id) {
        $0.region = FrameRegion(
          assetID: asset.id, actualTime: time, frameWidth: asset.displayWidth,
          frameHeight: asset.displayHeight, pixelRect: rect)
      }
    }
    view.onDelete = {
      if let id = store.motionIssue?.id {
        store.mutateAnimation("删除问题") { $0.issues.removeAll { $0.id == id } }
      }
    }
    view.onEscape = {
      store.replacingMotionRegion = false
      store.tool = .select
    }
    view.issueNumbers = Dictionary(
      uniqueKeysWithValues: (store.animation?.issues ?? []).enumerated().map {
        ($0.element.id, $0.offset + 1)
      })
    view.onTool = { store.tool = $0 }
    view.onPaste = { store.pasteClipboard() }
    view.onPointerDown = { store.focusAlignment(.current) }
    view.needsDisplay = true
  }
}

struct MotionIssuePanel: View {
  @Bindable var store: ReviewStore
  @Bindable var session: MotionSession
  @FocusState private var commentFocused: Bool
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("问题  \(store.animation?.issues.count ?? 0)").font(.headline)
        ForEach(Array((store.animation?.issues ?? []).enumerated()), id: \.element.id) { n, issue in
          Button {
            if store.clickMotionIssue(issue.id) == .select { session.seek(issue.target.first) }
          } label: {
            Text("\(n+1)  \(issue.comment.isEmpty ? "待填写描述" : issue.comment)").lineLimit(2).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(10).background(
              store.selectedIssueID == issue.id
                ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)
            ).clipShape(.rect(cornerRadius: 8))
          }.buttonStyle(.plain)
        }
        if let issue = store.motionIssue {
          Text("问题描述").font(.caption)
          TextEditor(
            text: Binding(
              get: { store.motionIssue?.comment ?? "" },
              set: { value in
                store.updateMotionIssue(issue.id, key: "motion-comment-\(issue.id)") {
                  $0.comment = value
                }
              })
          ).frame(height: 100).focused($commentFocused).overlay(
            RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
          Text("期望（可选）").font(.caption)
          TextField(
            "希望怎样调整",
            text: Binding(
              get: { store.motionIssue?.expectation ?? "" },
              set: { value in
                store.updateMotionIssue(issue.id, key: "expectation-\(issue.id)") {
                  $0.expectation = value
                }
              }), axis: .vertical
          ).lineLimit(3...5)
          Button("将当前选择应用为问题时间") {
            store.updateMotionIssue(issue.id) { $0.target = session.target }
          }.disabled(session.loading || session.playing)
          Text(store.hasUnsavedChanges ? "尚未保存" : "已自动保存").font(.caption2).foregroundStyle(
            .secondary)
          Divider()
          if let region = issue.region {
            Text("区域标记 · 当前实现").font(.subheadline)
            Text(
              String(
                format: "%.3f s · %d × %d px\nx %.0f · y %.0f · w %.0f · h %.0f",
                region.actualTime.seconds, region.frameWidth, region.frameHeight,
                region.pixelRect.x, region.pixelRect.y, region.pixelRect.width,
                region.pixelRect.height)
            ).font(.caption).monospacedDigit()
            Button("查看标注帧") { session.seek(region.actualTime) }
            HStack {
              Button("重新框选") {
                session.seek(region.actualTime)
                store.replacingMotionRegion = true
                store.tool = .rectangle
              }
              Button("移除区域") { store.updateMotionIssue(issue.id) { $0.region = nil } }
            }
          } else {
            Button("在当前帧框选") {
              store.replacingMotionRegion = true
              store.tool = .rectangle
            }
          }
          if let action = store.alignmentEditor.presentation(
            selected: AlignmentSelection(snapshot: issue.referenceSnapshot)).noticeAction
          {
            Text(
              issue.referenceSnapshot == nil ? "此问题还没有参考对齐" : "此问题使用之前的参考关系"
            ).font(.caption).foregroundStyle(.orange)
            Button(action) { store.adoptCurrentAlignment() }
          }
          DisclosureGroup("更多信息") {
            TextField(
              "组件（可选）",
              text: Binding(
                get: { store.motionIssue?.component ?? "" },
                set: { v in store.updateMotionIssue(issue.id) { $0.component = v } }))
            Picker(
              "分类",
              selection: Binding(
                get: { store.motionIssue?.category ?? "" },
                set: { v in store.updateMotionIssue(issue.id) { $0.category = v.isEmpty ? nil : v }
                })
            ) {
              Text("未分类").tag("")
              Text("位移").tag("position")
              Text("缩放").tag("scale")
              Text("透明度").tag("opacity")
              Text("速度与节奏").tag("timing")
              Text("延迟").tag("delay")
              Text("其他").tag("other")
            }
          }
          Button("删除问题", role: .destructive) {
            store.mutateAnimation("删除问题") { $0.issues.removeAll { $0.id == issue.id } }
          }
        } else {
          Text("框选当前帧即可新增问题，然后填写修改要求。").foregroundStyle(.secondary)
        }
      }.padding(20)
    }.background(.background).textFieldStyle(.roundedBorder)
      .onChange(of: store.selectedIssueID) { _, id in if id != nil { commentFocused = true } }
  }
}
