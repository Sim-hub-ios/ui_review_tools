import AppKit
import ReviewCore
import ReviewMedia
import SwiftUI

struct HandoffView: View {
  @Bindable var store: ReviewStore
  @Environment(\.dismiss) private var dismiss
  @State private var wholeReview = false
  @State private var exporting = false
  @State private var thumbnails: [UUID: NSImage] = [:]
  @State private var evidenceErrors: [UUID: String] = [:]
  @State private var exportTask: Task<Void, Never>?
  private var selected: Review? {
    store.currentReview.map {
      MotionExport.selected(
        $0, itemID: wholeReview ? nil : store.selectedAnimationID ?? store.selectedScreenshotID)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("交给 Coding Agent").font(.title2.bold())
      Picker("交接范围", selection: $wholeReview) {
        Text("当前素材").tag(false)
        Text("整个 Review").tag(true)
      }.pickerStyle(.segmented).frame(width: 280)
      if let review = selected {
        Text("\(review.issueCount) 个问题 · \(pending(review)) 个待填写").foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 24) {
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              ForEach(review.animations) { animation in
                Text(animation.name).font(.headline)
                ForEach(animation.issues) { issue in
                  Text(issue.comment.isEmpty ? "待填写描述" : issue.comment)
                  if let image = thumbnails[issue.id] {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 130)
                  }
                  if let error = evidenceErrors[issue.id] {
                    Text("证据不可用：" + error).font(.caption).foregroundStyle(.red)
                  }
                  Text(timeLabel(issue)).font(.caption).foregroundStyle(.secondary)
                  if let r = issue.region {
                    Text(
                      "区域帧 \(r.actualTime.seconds,specifier:"%.3f") s · \(r.frameWidth) × \(r.frameHeight) px"
                    ).font(.caption)
                  }
                  Text(issue.referenceSnapshot == nil ? "无参考视频" : "包含该问题的参考对齐快照").font(.caption)
                    .foregroundStyle(.secondary)
                  Divider()
                }
              }
              ForEach(review.screenshots) { shot in
                Text(shot.name).font(.headline)
                ForEach(shot.issues) { Text($0.comment.isEmpty ? "待填写描述" : $0.comment) }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(width: 450)
          VStack(alignment: .leading, spacing: 16) {
            Text("通过 MCP 读取").font(.headline)
            Text("复制后粘贴到项目会话，由你发送给 Agent。").foregroundStyle(.secondary)
            Button("复制交接提示词") { copy(review) }.buttonStyle(.borderedProminent)
            Divider()
            Text("文件导出").font(.headline)
            Text("包含完整录屏、问题说明、原帧与区域标注图。")
            Text(
              "视频 \(ByteCountFormatter.string(fromByteCount:review.videoAssets.reduce(0){$0+$1.byteLength},countStyle:.file))，另加图片与证据文件"
            ).font(.caption).foregroundStyle(.secondary)
            Button(exporting ? "取消导出" : "导出文件夹") {
              if exporting { exportTask?.cancel() } else { export(review) }
            }
            if exporting { ProgressView() }
          }.frame(width: 270)
        }
      }
      HStack {
        Spacer()
        Button("返回编辑") { dismiss() }.disabled(exporting)
      }
    }.padding(28).frame(width: 830, height: 620).interactiveDismissDisabled(exporting)
      .task(id: "\(wholeReview)-\(store.library.revision)") { await loadEvidence() }
  }
  private func loadEvidence() async {
    thumbnails = [:]
    evidenceErrors = [:]
    guard let review = selected else { return }
    for animation in review.animations {
      guard let asset = review.videoAssets.first(where: { $0.id == animation.currentAssetID })
      else { continue }
      for issue in animation.issues {
        do {
          let (_, png) = try await EvidenceService.capture(
            asset: asset, repository: store.repository,
            requested: issue.region?.actualTime ?? issue.target.first, source: "current",
            region: issue.region, maxDimension: 480)
          try Task.checkCancellation()
          thumbnails[issue.id] = NSImage(data: png)
        } catch is CancellationError { return } catch {
          evidenceErrors[issue.id] = error.localizedDescription
        }
      }
    }
  }
  private func pending(_ review: Review) -> Int {
    review.animations.flatMap(\.issues).filter {
      $0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.count
      + review.screenshots.flatMap(\.issues).filter {
        $0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }.count
  }
  private func timeLabel(_ issue: AnimationIssue) -> String {
    if let s = issue.target.start, let e = issue.target.end {
      return String(format: "当前原视频 %.3f–%.3f s", s.seconds, e.seconds)
    }
    return String(format: "时间点 %.3f s", issue.target.first.seconds)
  }
  private func copy(_ review: Review) {
    guard store.retrySave() else { return }
    let ids = review.animations.map { $0.id.uuidString }.joined(separator: ", ")
    let shots = review.screenshots.map { $0.id.uuidString }.joined(separator: ", ")
    let text =
      "请通过 ui-review MCP 审查 Review \(review.id.uuidString)。范围：\(wholeReview ? "整个 Review":"当前素材")；截图 ID：[\(shots)]；动画 ID：[\(ids)]。已保存 revision：\(store.library.revision.uuidString)。截图使用 get_review/get_screenshot；动画使用 get_animation（expected_revision 为上述 revision）、get_animation_frame/get_animation_frames 获取原帧、区域图和参考证据。逐项理解原始评论；\(pending(review)) 项描述待填写。缺失证据或 revision 变化时先报告，不猜测动画参数。"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    store.status = "已复制交接提示词"
  }
  private func export(_ review: Review) {
    guard store.retrySave() else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.prompt = "导出到此处"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    let out = folder.appendingPathComponent("review-\(UUID().uuidString.prefix(8))")
    let revision = store.library.revision
    exporting = true
    exportTask = Task {
      defer { exporting = false }
      do {
        try await MotionExport.write(
          review, revision: revision, repository: store.repository, to: out)
        store.status = "导出完成"
        NSWorkspace.shared.activateFileViewerSelecting([out])
      } catch is CancellationError { store.status = "已取消导出" } catch {
        store.errorMessage = error.localizedDescription
      }
    }
  }
}
