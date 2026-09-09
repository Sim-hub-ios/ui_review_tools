import ReviewCore
import SwiftUI
import AVFoundation

struct AlignmentSheet: View {
  @Bindable var store: ReviewStore
  let animation: ReviewCore.Animation
  @Environment(\.dismiss) private var dismiss
  @State private var current = MotionSession()
  @State private var reference = MotionSession()
  @State private var currentStart: MediaTime?
  @State private var referenceStart: MediaTime?
  private var referenceID: UUID? {
    store.pendingReferenceID ?? animation.activeReference?.referenceAssetID
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("设置对齐起点").font(.title2.bold())
      Text("分别定位动画开始的画面。只调整开始位置，保留各自速度与时长。").foregroundStyle(.secondary)
      HStack(spacing: 20) {
        card("参考视频", session: reference, selected: referenceStart) {
          referenceStart = reference.time
        }
        card("当前实现", session: current, selected: currentStart) { currentStart = current.time }
      }
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("确认对齐") {
          if let id = referenceID, let a = currentStart, let b = referenceStart {
            store.mutateAnimation("设置参考对齐") {
              $0.activeReference = ReferenceAlignment(
                referenceAssetID: id, currentStart: a, referenceStart: b)
            }
            dismiss()
          }
        }.buttonStyle(.borderedProminent).disabled(currentStart == nil || referenceStart == nil)
      }
    }.padding(28).frame(width: 850, height: 650)
      .task {
        guard let review = store.currentReview, let id = referenceID else { return }
        var single = animation
        single.activeReference = nil
        await current.configure(single, review: review, repository: store.repository)
        await reference.configure(
          ReviewCore.Animation(name: "参考", currentAssetID: id), review: review,
          repository: store.repository)
      }.onDisappear {
        current.stop()
        reference.stop()
      }
  }
  private func card(
    _ title: String, session: MotionSession, selected: MediaTime?, set: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 12) {
      Text(title).font(.headline)
      if session.playing {
        MotionPlayerView(player: session.player).disabled(true).frame(maxHeight: .infinity)
      } else if let image = session.image {
        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: .infinity)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Slider(
        value: Binding(get: { session.time.seconds }, set: { session.seek(session.nearest($0)) }),
        in: 0...max(0.001, session.asset?.duration.seconds ?? 1))
      HStack {
        Button("上一帧") { session.step(-1) }
        Button(session.playing ? "暂停" : "播放") { session.toggle() }
        Text("\(session.time.seconds,specifier:"%.3f") s").monospacedDigit()
        Button("下一帧") { session.step(1) }
      }
      Button("设为起点", action: set).disabled(session.loading || session.frames.isEmpty || session.playing)
      Text(selected.map { String(format: "已设置 %.3f s", $0.seconds) } ?? "尚未设置起点").font(.caption)
        .foregroundStyle(selected == nil ? Color.secondary : Color.green)
      if let message = session.message { Text(message).font(.caption).foregroundStyle(.red) }
    }.padding(16).frame(maxWidth: .infinity).background(
      .background, in: RoundedRectangle(cornerRadius: 12))
  }
}
