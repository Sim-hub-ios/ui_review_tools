import AVFoundation
import AppKit
import Observation
import ReviewCore
import ReviewMedia

@MainActor @Observable final class MotionSession {
  var player = AVPlayer()
  var referencePlayer = AVPlayer()
  var asset: VideoAsset?
  var reference: VideoAsset?
  var frames: [MediaTime] = []
  var referenceFrames: [MediaTime] = []
  var time = MediaTime.zero
  var image: NSImage?
  var referenceImage: NSImage?
  var loading = false
  var playing = false
  var speed: Float = 0.5
  var rangeStart = 0.0
  var rangeEnd = 0.0
  var useRange = false
  var message: String?
  var referenceStatus: String?
  var referenceTime: MediaTime?
  var referencePlaying = false
  var alignment: ReferenceAlignment?
  @ObservationIgnored private var token: Any?
  @ObservationIgnored private var referenceToken: Any?
  @ObservationIgnored private var referenceSeekTask: Task<Void, Never>?
  @ObservationIgnored private var referenceSeekID = UUID()
  @ObservationIgnored private var seekTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var seekGeneration = UUID()
  @ObservationIgnored private var resumeAfterSeek = false
  @ObservationIgnored private var resumeReferenceAfterSeek = false
  @ObservationIgnored private var repository: ReviewRepository?

  func configure(_ animation: Animation, review: Review, repository: ReviewRepository) async {
    await configure(
      animation, review: review, repository: repository,
      referenceAssetID: animation.resolvedReferenceAssetID, alignment: animation.activeReference,
      resume: nil)
  }

  func configure(
    _ animation: Animation, review: Review, repository: ReviewRepository,
    referenceAssetID: UUID?, alignment requestedAlignment: ReferenceAlignment?, resume: MediaTime?
  ) async {
    let resumeTime = resume
    stop()
    let current = UUID()
    generation = current
    self.repository = repository
    guard let asset = review.videoAssets.first(where: { $0.id == animation.currentAssetID }) else {
      return
    }
    self.asset = asset
    image = nil
    referenceImage = nil
    frames = []
    message = nil
    loading = true
    reference = review.videoAssets.first { $0.id == referenceAssetID }
    alignment =
      requestedAlignment?.referenceAssetID == reference?.id ? requestedAlignment : nil
    do {
      let url = try repository.assetURL(for: asset)
      let index = try await VideoService.index(url, asset: asset)
      guard generation == current, !Task.isCancelled else { return }
      frames = index
      rangeStart = index.first?.seconds ?? 0
      rangeEnd = min(asset.duration.seconds, rangeStart + 0.3)
      player.replaceCurrentItem(with: AVPlayerItem(url: url))
      player.isMuted = true
      try await waitUntilReady(player, generation: current)
      if let reference {
        let refURL = try repository.assetURL(for: reference)
        referenceFrames = try await VideoService.index(refURL, asset: reference)
        guard generation == current, !Task.isCancelled else { return }
        referencePlayer.replaceCurrentItem(with: AVPlayerItem(url: refURL))
        referencePlayer.isMuted = true
        try await waitUntilReady(referencePlayer, generation: current)
        referenceToken = referencePlayer.addPeriodicTimeObserver(
          forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] raw in
          Task { @MainActor in guard self?.generation == current else { return }; self?.tickReference(raw) }
        }
      }
      token = player.addPeriodicTimeObserver(
        forInterval: CMTime(value: 1, timescale: 30), queue: .main
      ) { [weak self] raw in
        Task { @MainActor in guard self?.generation == current else { return }; self?.tick(raw) }
      }
      seek(resumeTime.map { nearest($0.seconds) } ?? index.first ?? .zero)
      if alignment == nil, let first = referenceFrames.first { seekReference(first) }
    } catch {
      if generation == current {
        message = error.localizedDescription
        loading = false
      }
    }
  }
  private func waitUntilReady(_ player: AVPlayer, generation expected: UUID) async throws {
    let deadline = Date().addingTimeInterval(15)
    while player.status != .readyToPlay {
      try Task.checkCancellation()
      guard generation == expected else { throw CancellationError() }
      if player.status == .failed { throw player.error ?? ReviewError.invalidData("播放器无法加载视频。") }
      guard Date() < deadline else { throw ReviewError.invalidData("播放器加载超时，请重新选择素材。") }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  func stop() {
    generation = UUID()
    seekGeneration = UUID()
    resumeAfterSeek = false
    resumeReferenceAfterSeek = false
    seekTask?.cancel()
    seekTask = nil
    referenceFrames = []
    referenceImage = nil
    referenceTime = nil
    referenceStatus = nil
    referencePlaying = false
    useRange = false
    player.pause()
    referencePlayer.pause()
    playing = false
    referenceSeekTask?.cancel()
    if let token {
      player.removeTimeObserver(token)
      self.token = nil
    }
    if let referenceToken {
      referencePlayer.removeTimeObserver(referenceToken)
      self.referenceToken = nil
    }
    player.replaceCurrentItem(with: nil)
    referencePlayer.replaceCurrentItem(with: nil)
  }
  func nearestReference(_ seconds: Double) -> MediaTime {
    guard seconds.isFinite else { return referenceTime ?? .zero }
    return referenceFrames.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .zero
  }
  func nearest(_ seconds: Double) -> MediaTime {
    guard seconds.isFinite else { return time }
    return frames.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .zero
  }
  func seek(_ requested: MediaTime, resume: Bool = false) {
    resumeAfterSeek = resume
    guard let asset, let repository, !frames.isEmpty else { return }
    player.pause()
    playing = false
    if alignment != nil {
      referencePlayer.pause()
      referencePlaying = false
    }
    loading = true
    image = nil
    seekTask?.cancel()
    seekGeneration = UUID()
    let request = seekGeneration
    let current = generation
    let target = nearest(requested.seconds)
    seekTask = Task {
      do {
        let frame = try await VideoService.frame(
          repository.assetURL(for: asset), asset: asset, at: target)
        try Task.checkCancellation()
        guard generation == current, seekGeneration == request else { return }
        time = frame.actualTime
        image = NSImage(
          cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
        await player.seek(
          to: CMTimeAdd(target.cmTime, asset.timelineOrigin.cmTime), toleranceBefore: .zero,
          toleranceAfter: .zero)
        try Task.checkCancellation()
        guard generation == current, seekGeneration == request else { return }
        referenceStatus = nil
        if let reference, let alignment {
          let mapped =
            target.seconds - alignment.currentStart.seconds + alignment.referenceStart.seconds
          referenceStatus =
            mapped < 0 ? "此时间无画面" : mapped >= reference.duration.seconds ? "视频已结束" : nil
          if mapped < 0 {
            referenceImage = nil
            referenceTime = nil
          } else if let t = referenceFrames.min(by: {
            abs($0.seconds - mapped) < abs($1.seconds - mapped)
          }) {
            let ref = try await VideoService.frame(
              repository.assetURL(for: reference), asset: reference, at: t)
            try Task.checkCancellation()
            guard generation == current, seekGeneration == request else { return }
            referenceTime = ref.actualTime
            referenceImage = NSImage(
              cgImage: ref.image, size: NSSize(width: ref.image.width, height: ref.image.height))
            await referencePlayer.seek(
              to: CMTimeAdd(t.cmTime, reference.timelineOrigin.cmTime), toleranceBefore: .zero,
              toleranceAfter: .zero)
          }
        }
        try Task.checkCancellation()
        guard generation == current, seekGeneration == request else { return }
        loading = false
        if resumeAfterSeek {
          resumeAfterSeek = false
          toggle()
        }
      } catch is CancellationError {} catch {
        if generation == current, seekGeneration == request {
          message = error.localizedDescription
          loading = false
        }
      }
    }
  }
  func step(_ amount: Int) {
    guard let index = frames.firstIndex(where: { $0.equivalent(to: time) }) else {
      seek(nearest(time.seconds))
      return
    }
    seek(frames[min(max(0, index + amount), frames.count - 1)])
  }
  func toggle() {
    if playing {
      resumeAfterSeek = false
      seek(nearest(time.seconds))
      return
    }
    guard !loading, !frames.isEmpty else { return }
    if useRange {
      guard rangeStart.isFinite, rangeEnd.isFinite, rangeStart < rangeEnd,
        frames.contains(where: { $0.seconds >= rangeStart && $0.seconds < rangeEnd })
      else {
        message = "选段中没有可播放画面。"
        return
      }
    }
    if let restart = Self.restartTime(
      time: time, frames: frames, useRange: useRange, rangeStart: rangeStart, rangeEnd: rangeEnd)
    {
      seek(restart, resume: true)
      return
    }
    guard player.status == .readyToPlay,
      reference == nil || referenceStatus != nil || referencePlayer.status == .readyToPlay
    else { message = "播放器尚未就绪，请稍后重试。"; return }
    playing = true
    player.automaticallyWaitsToMinimizeStalling = false
    referencePlayer.automaticallyWaitsToMinimizeStalling = false
    let host = CMTimeAdd(
      CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.1, preferredTimescale: 1_000_000)
    )
    player.setRate(speed, time: player.currentTime(), atHostTime: host)
    if alignment != nil, reference != nil, referenceStatus == nil {
      referencePlayer.setRate(speed, time: referencePlayer.currentTime(), atHostTime: host)
    }
  }
  func transportToggle(_ side: AlignmentSide) {
    if alignment != nil || side == .current {
      referencePlaying = false
      referencePlayer.pause()
      toggle()
    } else {
      if playing { seek(time) }
      toggleReference()
    }
  }
  func transportStep(_ amount: Int, side: AlignmentSide) {
    if alignment != nil || side == .current {
      step(amount)
      return
    }
    guard let index = referenceFrames.firstIndex(where: { $0.equivalent(to: referenceTime ?? .zero) }) else {
      if let first = referenceFrames.first { seekReference(first) }
      return
    }
    seekReference(referenceFrames[min(max(0, index + amount), referenceFrames.count - 1)])
  }
  func seekCurrent(forReferenceTime time: MediaTime, mapping: TimeMapping) {
    seek(nearest(time.seconds - mapping.referenceStart.seconds + mapping.currentStart.seconds))
  }
  func previewMapping(_ mapping: TimeMapping) {
    showReference(at: mapping.referenceSeconds(forCurrent: time.seconds))
  }
  func seekReference(_ requested: MediaTime, resume: Bool = false) {
    guard alignment == nil else { return }
    referencePlaying = false
    referencePlayer.pause()
    resumeReferenceAfterSeek = resume
    showReference(at: nearestReference(requested.seconds).seconds)
  }
  static func restartTime(
    time: MediaTime, frames: [MediaTime], useRange: Bool, rangeStart: Double, rangeEnd: Double
  ) -> MediaTime? {
    guard let last = frames.last else { return nil }
    let atEnd = time.equivalent(to: last) || time.seconds >= last.seconds
    if useRange {
      guard time.seconds < rangeStart || time.seconds >= rangeEnd || atEnd else { return nil }
      return frames.first { $0.seconds >= rangeStart && $0.seconds < rangeEnd }
    }
    return atEnd ? frames.first : nil
  }
  private func toggleReference() {
    if referencePlaying {
      referencePlaying = false
      if let referenceTime { seekReference(referenceTime) }
      return
    }
    guard alignment == nil, !loading, !referenceFrames.isEmpty, referencePlayer.status == .readyToPlay
    else { return }
    if let restart = Self.restartTime(
      time: referenceTime ?? .zero, frames: referenceFrames, useRange: false, rangeStart: 0,
      rangeEnd: 0)
    {
      seekReference(restart, resume: true)
      return
    }
    referencePlaying = true
    referencePlayer.automaticallyWaitsToMinimizeStalling = false
    referencePlayer.rate = speed
  }
  private func tickReference(_ raw: CMTime) {
    guard referencePlaying, alignment == nil, let reference else { return }
    let seconds = raw.seconds - reference.timelineOrigin.seconds
    guard seconds.isFinite else { return }
    referenceTime = nearestReference(seconds)
    if seconds >= (referenceFrames.last?.seconds ?? reference.duration.seconds) {
      seekReference(referenceFrames.last ?? .zero)
    }
  }
  private func showReference(at seconds: Double) {
    guard let reference, let repository else { return }
    referencePlayer.pause()
    referenceStatus = seconds < 0 ? "此时间无画面" : seconds >= reference.duration.seconds ? "视频已结束" : nil
    guard seconds >= 0 else {
      referenceImage = nil
      referenceTime = nil
      return
    }
    let target = nearestReference(seconds)
    referenceSeekTask?.cancel()
    referenceSeekID = UUID()
    let request = referenceSeekID
    let current = generation
    referenceSeekTask = Task {
      do {
        let frame = try await VideoService.frame(
          repository.assetURL(for: reference), asset: reference, at: target)
        try Task.checkCancellation()
        guard generation == current, referenceSeekID == request else { return }
        referenceTime = frame.actualTime
        referenceImage = NSImage(
          cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
        referenceStatus = seconds >= reference.duration.seconds ? "视频已结束" : nil
        await referencePlayer.seek(
          to: CMTimeAdd(target.cmTime, reference.timelineOrigin.cmTime), toleranceBefore: .zero,
          toleranceAfter: .zero)
        guard generation == current, referenceSeekID == request else { return }
        if resumeReferenceAfterSeek {
          resumeReferenceAfterSeek = false
          referencePlaying = true
          referencePlayer.automaticallyWaitsToMinimizeStalling = false
          referencePlayer.rate = speed
        }
      } catch is CancellationError {} catch {
        if generation == current, referenceSeekID == request { message = error.localizedDescription }
      }
    }
  }
  private func tick(_ raw: CMTime) {
    guard playing, let asset else { return }
    let seconds = raw.seconds - asset.timelineOrigin.seconds
    guard seconds.isFinite else { return }
    time = nearest(seconds)
    if useRange && seconds >= rangeEnd {
      if let first = frames.first(where: { $0.seconds >= rangeStart && $0.seconds < rangeEnd }) {
        seek(first, resume: true)
      } else {
        seek(time)
      }
      return
    }
    if seconds >= (frames.last?.seconds ?? asset.duration.seconds) {
      seek(frames.last ?? .zero)
      return
    }
    if let reference, let alignment {
      let mapped = seconds - alignment.currentStart.seconds + alignment.referenceStart.seconds
      if mapped < 0 {
        referenceStatus = "此时间无画面"
        referencePlayer.pause()
      } else if mapped >= reference.duration.seconds {
        referenceStatus = "视频已结束"
        referencePlayer.pause()
      } else {
        referenceStatus = nil
        let actual = referencePlayer.currentTime().seconds - reference.timelineOrigin.seconds
        if abs(actual - mapped) > 0.1 {
          message = "同步偏差超过 100 ms，正在重新对齐。"
          seek(time, resume: true)
          return
        }
        referencePlayer.rate = speed
      }
    }
  }
  var target: TemporalTarget {
    useRange ? .range(MediaTime(seconds: rangeStart), MediaTime(seconds: rangeEnd)) : .point(time)
  }
}
