import AppKit
import ReviewCore
import ReviewMedia

extension ReviewStore {
  var animation: Animation? { currentReview?.animations.first { $0.id == selectedAnimationID } }
  var motionIssue: AnimationIssue? { animation?.issues.first { $0.id == selectedIssueID } }
  func selectAnimation(_ id: UUID) {
    replacingMotionRegion = false
    pendingReferenceID = nil
    selectedAnimationID = id
    selectedScreenshotID = nil
    selectedIssueID = nil
    tool = .select
  }
  func mutateAnimation(_ name: String, key: String? = nil, _ change: (inout Animation) -> Void) {
    let reviewID = library.currentReviewID
    let animationID = selectedAnimationID
    commit(name, coalescing: key) { lib in
      guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }),
        let a = lib.reviews[r].animations.firstIndex(where: { $0.id == animationID })
      else { return }
      change(&lib.reviews[r].animations[a])
      lib.reviews[r].animations[a].updatedAt = Date()
      lib.reviews[r].updatedAt = Date()
    }
  }
  func importVideos(_ urls: [URL], asReference: Bool = false) {
    guard !isBusy, !loadFailed else { return }
    let reviewID = library.currentReviewID
    let animationID = selectedAnimationID
    isBusy = true
    importTask = Task {
      defer {
        isBusy = false
        importTask = nil
      }
      var targetReviewID = reviewID
      for url in urls {
        if Task.isCancelled { break }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        status = "正在导入 \(url.lastPathComponent)…"
        do {
          let result = try await VideoService.importVideo(url, repository: repository)
          try Task.checkCancellation()
          guard library.currentReviewID == targetReviewID else {
            throw ReviewError.invalidData("Review 已切换，请重新导入。")
          }
          if asReference {
            guard selectedAnimationID == animationID, animation != nil else {
              throw ReviewError.invalidData("当前动画已切换。")
            }
            // Import keeps the reference unlinked until both starts are explicitly confirmed.
            commit("导入参考视频") { lib in
              guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }) else { return }
              lib.reviews[r].videoAssets.append(result.asset)
            }
            pendingReferenceID = result.asset.id
          } else {
            let animation = Animation(name: url.lastPathComponent, currentAssetID: result.asset.id)
            commit("导入动画") { lib in
              if lib.currentReviewID == nil {
                let review = Review(
                  title: "Review · " + Date().formatted(date: .abbreviated, time: .shortened))
                lib.reviews.insert(review, at: 0)
                lib.currentReviewID = review.id
              }
              guard let r = lib.reviews.firstIndex(where: { $0.id == lib.currentReviewID }) else {
                return
              }
              lib.reviews[r].videoAssets.append(result.asset)
              lib.reviews[r].animations.append(animation)
            }
            targetReviewID = library.currentReviewID
            selectAnimation(animation.id)
          }
        } catch is CancellationError { status = "已取消导入" } catch {
          errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
        }
      }
    }
  }
  /// Import one MP4/MOV as the current animation's unlinked reference.
  func pasteReferenceVideo(from board: NSPasteboard = .general) {
    guard let animation, !isBusy, !loadFailed, pendingReferenceID == nil else { return }
    guard animation.activeReference == nil else {
      status = "已有参考视频，请先移除参考后再添加。"
      return
    }
    let urls = (board.readObjects(forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
      .filter { $0.isFileURL && ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
    guard urls.count == 1, let url = urls.first else {
      status = urls.isEmpty ? "请先复制一个 MP4 或 MOV 视频文件。" : "请一次只粘贴一个参考视频。"
      return
    }
    importVideos([url], asReference: true)
  }

  func chooseReference() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
    panel.prompt = "添加参考视频"
    if panel.runModal() == .OK, let url = panel.url { importVideos([url], asReference: true) }
  }
  func addMotionIssue(target: TemporalTarget) {
    guard let animation else { return }
    let issue = AnimationIssue(target: target, referenceSnapshot: animation.activeReference)
    mutateAnimation("添加动画问题") { $0.issues.append(issue) }
    selectedIssueID = issue.id
  }
  func applyMotionBoxSelection(
    _ rect: Region, asset: VideoAsset, time: MediaTime, target: TemporalTarget
  ) {
    if replacingMotionRegion, let issue = motionIssue {
      guard issue.target.contains(time) else {
        errorMessage = "当前帧不在问题时间内，请查看标注帧或返回问题范围。"
        return
      }
      updateMotionIssue(issue.id) {
        $0.region = FrameRegion(
          assetID: asset.id, actualTime: time, frameWidth: asset.displayWidth,
          frameHeight: asset.displayHeight, pixelRect: rect)
      }
      replacingMotionRegion = false
      tool = .select
      return
    }
    addMotionIssue(target: target.contains(time) ? target : .point(time))
    guard let issue = motionIssue else { return }
    updateMotionIssue(issue.id) {
      $0.region = FrameRegion(
        assetID: asset.id, actualTime: time, frameWidth: asset.displayWidth,
        frameHeight: asset.displayHeight, pixelRect: rect)
    }
    replacingMotionRegion = false
    tool = .select
  }
  func updateMotionIssue(_ id: UUID, key: String? = nil, _ change: (inout AnimationIssue) -> Void) {
    mutateAnimation("编辑动画问题", key: key) { animation in
      guard let i = animation.issues.firstIndex(where: { $0.id == id }) else { return }
      change(&animation.issues[i])
    }
  }
  func renameAnimation(_ id: UUID, name: String) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let reviewID = library.currentReviewID
    commit("重命名动画") { lib in
      guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }),
        let a = lib.reviews[r].animations.firstIndex(where: { $0.id == id })
      else { return }
      lib.reviews[r].animations[a].name = name
    }
  }
  func deleteAnimation(_ id: UUID) {
    let rID = library.currentReviewID
    let deletingSelected = selectedAnimationID == id
    let keepPending = deletingSelected ? nil : pendingReferenceID
    commit("删除动画") { lib in
      guard let r = lib.reviews.firstIndex(where: { $0.id == rID }) else { return }
      lib.reviews[r].animations.removeAll { $0.id == id }
      lib.reviews[r].pruneUnusedVideoAssets(keeping: keepPending)
      lib.reviews[r].updatedAt = Date()
    }
    if deletingSelected { pendingReferenceID = nil }
  }
}
