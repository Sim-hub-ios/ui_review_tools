import AVFoundation
import AppKit
import ReviewCore
import ReviewMedia
import SwiftUI

struct MotionWorkspace: View {
  @Bindable var store: ReviewStore
  let animation: ReviewCore.Animation
  @State private var session = MotionSession()
  @State private var align = false
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
          if animation.activeReference != nil {
            Button("重新对齐") { align = true }
            Menu {
              Button("移除参考") { store.mutateAnimation("移除参考") { $0.activeReference = nil } }
            } label: {
              Image(systemName: "ellipsis")
            }
          } else {
            Button("添加参考视频") { store.chooseReference() }.disabled(store.isBusy)
          }
        }.padding(12).background(.bar)
        HStack(spacing: 8) {
          if session.reference != nil {
            VStack {
              Text("参考 · \(referenceTime)").font(.caption).foregroundStyle(.secondary)
              if session.playing {
                MotionPlayerView(player: session.referencePlayer).disabled(true)
              } else if let image = session.referenceImage {
                Image(nsImage: image).resizable().scaledToFit().padding(24)
              } else {
                ContentUnavailableView("此时间无画面", systemImage: "video.slash")
              }
              if let status = session.referenceStatus {
                Text(status).font(.caption).foregroundStyle(.orange)
              }
            }.frame(maxWidth: .infinity)
          }
          VStack {
            Text("当前实现 · \(session.time.seconds, specifier: "%.3f") s").font(.caption)
              .foregroundStyle(.secondary)
            if session.playing {
              MotionPlayerView(player: session.player, onPaste: { store.pasteReferenceVideo() })
            } else if !session.loading, let asset = session.asset, let image = session.image {
              MotionCanvas(
                store: store, asset: asset, time: session.time, image: image, target: session.target
              )
            } else if session.loading {
              ProgressView("正在加载当前帧…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              Text(session.message ?? "暂无画面").foregroundStyle(.secondary).frame(
                maxWidth: .infinity, maxHeight: .infinity)
            }
          }.frame(maxWidth: .infinity)
        }.frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        timeline
      }.frame(minWidth: 500, maxWidth: .infinity)
      Divider()
      MotionIssuePanel(store: store, session: session).frame(width: 300)
    }
    .task(
      id:
        "\(animation.id)-\(store.selectedIssueID?.uuidString ?? "none")-\((store.motionIssue?.referenceSnapshot ?? animation.activeReference)?.alignmentID.uuidString ?? "none")"
    ) {
      if let review = store.currentReview {
        var displayed = animation
        if let issue = store.motionIssue { displayed.activeReference = issue.referenceSnapshot }
        await session.configure(displayed, review: review, repository: store.repository)
        if let issue = store.motionIssue {
          if let start = issue.target.start, let end = issue.target.end {
            session.rangeStart = start.seconds
            session.rangeEnd = end.seconds
            session.useRange = true
          }
          session.seek(issue.target.first)
        }
      }
    }
    .onAppear { store.motionKeyAction = { key in if key == 49 { session.toggle() } else { session.step(key == 123 ? -1 : 1) } } }
    .onDisappear { session.stop(); store.motionKeyAction = nil }
    .onChange(of: store.tool) { _, tool in
      if tool == .rectangle && session.playing { session.seek(session.time) }
    }
    .onChange(of: store.pendingReferenceID) { _, id in if id != nil { align = true } }
    .sheet(isPresented: $align, onDismiss: { store.pendingReferenceID = nil }) {
      AlignmentSheet(store: store, animation: animation)
    }
  }
  private var referenceTime: String {
    if !session.playing {
      return session.referenceTime.map { String(format: "%.3f s", $0.seconds) } ?? "—"
    }
    guard let a = session.alignment else { return "—" }
    return String(
      format: "%.3f s", session.time.seconds - a.currentStart.seconds + a.referenceStart.seconds)
  }
  private var timeline: some View {
    VStack(spacing: 12) {
      HStack {
        Button("上一帧") { session.step(-1) }
        Button(session.playing ? "暂停" : session.useRange ? "播放此段" : "播放") { session.toggle() }
          .buttonStyle(.borderedProminent)
        Button("下一帧") { session.step(1) }
        Picker("倍速", selection: $session.speed) {
          ForEach([Float(0.25), 0.5, 1, 2], id: \.self) {
            Text("\($0, specifier: "%.2g")×").tag($0)
          }
        }.frame(width: 90)
        Spacer()
        Text(
          session.alignment == nil
            ? String(format: "%.3f s", session.time.seconds)
            : String(
              format: "起点后 %.0f ms",
              (session.time.seconds - (session.alignment?.currentStart.seconds ?? 0)) * 1000)
        ).monospacedDigit()
      }
      MotionTimelineStrip(
        session: session, repository: store.repository, issues: store.animation?.issues ?? [])
      Slider(
        value: Binding(get: { session.time.seconds }, set: { session.seek(session.nearest($0)) }),
        in: 0...max(0.001, session.asset?.duration.seconds ?? 1))
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
        Button("＋ 添加问题") { store.addMotionIssue(target: session.target) }.disabled(
          session.loading || session.playing || !validTarget)
      }.textFieldStyle(.roundedBorder)
    }.font(.caption).padding(16).background(.background).disabled(session.frames.isEmpty)
  }
  private var validTarget: Bool {
    guard let asset = session.asset else { return false }
    return (try? session.target.validate(duration: asset.duration)) != nil
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
      if store.motionIssue == nil {
        store.addMotionIssue(target: target.contains(time) ? target : .point(time))
      }
      guard let issue = store.motionIssue else { return }
      guard issue.target.contains(time) else {
        store.errorMessage = "当前帧不在问题时间内，请查看标注帧或返回问题范围。"
        return
      }
      if issue.region != nil && !store.replacingMotionRegion {
        store.errorMessage = "已有区域，请使用右侧的重新框选。"
        return
      }
      store.updateMotionIssue(issue.id) {
        $0.region = FrameRegion(
          assetID: asset.id, actualTime: time, frameWidth: asset.displayWidth,
          frameHeight: asset.displayHeight, pixelRect: rect)
      }
      store.replacingMotionRegion = false
      store.tool = .select
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
    view.onPaste = { store.pasteReferenceVideo() }
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
            store.selectedIssueID = issue.id
            session.seek(issue.target.first)
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
            Button("在当前帧框选") { store.tool = .rectangle }
          }
          if issue.referenceSnapshot != store.animation?.activeReference {
            Text("此问题使用之前的参考关系").font(.caption).foregroundStyle(.orange)
            Button("使用新的对齐方式") {
              let relation = store.animation?.activeReference
              store.updateMotionIssue(issue.id) { $0.referenceSnapshot = relation }
            }
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
          Text("选择时间段或框选当前帧，然后填写修改要求。").foregroundStyle(.secondary)
        }
      }.padding(20)
    }.background(.background).textFieldStyle(.roundedBorder)
      .onChange(of: store.selectedIssueID) { _, id in if id != nil { commentFocused = true } }
  }
}
