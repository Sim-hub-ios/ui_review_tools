import AppKit
import ReviewCore
import ReviewMedia
import SwiftUI

struct MotionTimelineStrip: View {
  let asset: VideoAsset?
  let repository: ReviewRepository
  let frames: [MediaTime]
  let time: MediaTime
  let issues: [AnimationIssue]
  var showsIssues = false
  var showsRange = false
  @Binding var useRange: Bool
  @Binding var rangeStart: Double
  @Binding var rangeEnd: Double
  var startMarker: MediaTime?
  var startEditable = false
  var emptyStartLabel: String?
  var onSeek: (MediaTime) -> Void
  var onPlaceStart: (MediaTime) -> Void
  var onUpdateStart: (MediaTime) -> Void
  var onEndStart: () -> Void
  var onCancelStart: () -> Void
  @State private var thumbnails: [NSImage] = []
  @State private var magnification = 1.0
  @State private var draggingStart = false
  @State private var suppressStartEnd = false
  @State private var escapeMonitor: Any?
  private var duration: Double { max(0.001, asset?.duration.seconds ?? 1) }
  private var span: Double { duration / magnification }
  private var windowStart: Double {
    max(0, min(duration - span, floor(time.seconds / span) * span))
  }
  var body: some View {
    VStack(spacing: 5) {
      HStack {
        Text(String(format: "%.3f–%.3f s", windowStart, windowStart + span)).foregroundStyle(.secondary)
        Spacer()
        Button("−") { magnification = max(1, magnification / 2) }.disabled(magnification == 1)
        Text("\(Int(magnification))×").monospacedDigit()
        Button("＋") { magnification = min(32, magnification * 2) }
      }
      if startMarker != nil || emptyStartLabel != nil || startEditable { startTrack }
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .topLeading) {
          HStack(spacing: 2) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
              Image(nsImage: image).resizable().scaledToFill().frame(
                width: max(1, (width - 18) / 10), height: 40
              ).clipped()
            }
          }.background(.secondary.opacity(0.1))
          if showsRange && useRange {
            let left = max(0, min(1, (rangeStart - windowStart) / span)) * width
            let right = max(0, min(1, (rangeEnd - windowStart) / span)) * width
            Rectangle().fill(.blue.opacity(0.18)).frame(width: max(0, right - left), height: 40)
              .offset(x: left)
            rangeHandle(width: width, seconds: rangeStart, isStart: true)
            rangeHandle(width: width, seconds: rangeEnd, isStart: false)
          }
          Rectangle().fill(.blue).frame(width: 2, height: 48).offset(
            x: max(0, min(1, (time.seconds - windowStart) / span)) * width
          ).allowsHitTesting(false)
          if showsIssues {
            ForEach(Array(issues.enumerated()), id: \.element.id) { n, issue in
              if issue.target.first.seconds >= windowStart
                && issue.target.first.seconds <= windowStart + span
              {
                Text("\(n+1)").font(.system(size: 9)).foregroundStyle(.white).padding(2).background(
                  .blue, in: Circle()
                ).offset(x: (issue.target.first.seconds - windowStart) / span * width, y: 42)
                  .allowsHitTesting(false)
              }
            }
          }
        }.contentShape(Rectangle()).gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            onSeek(nearest(windowStart + value.location.x / width * span))
          })
      }.frame(height: 58)
    }.font(.caption)
      .task(
        id:
          "\(asset?.id.uuidString ?? "")-\(Int(magnification))-\(Int(windowStart*1000))-\(frames.count)"
      ) {
        guard let asset else { return }
        var images: [NSImage] = []
        for n in 0..<10 {
          if Task.isCancelled { return }
          let sample = nearest(windowStart + span * Double(n) / 10)
          if let result = try? await VideoService.frame(
            repository.assetURL(for: asset), asset: asset, at: sample, maxDimension: 128)
          {
            images.append(
              NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height)))
          }
        }
        if !Task.isCancelled { thumbnails = images }
      }
      .onDisappear { trackEscape(false) }
      .onExitCommand {
        guard draggingStart else { return }
        suppressStartEnd = true
        draggingStart = false
        trackEscape(false)
        onCancelStart()
      }
  }

  private var startTrack: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary).frame(height: 4)
        if let label = emptyStartLabel, startMarker == nil {
          Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        if let marker = startMarker {
          Circle().fill(startEditable ? Color.accentColor : Color.secondary).frame(width: 12, height: 12)
            .offset(x: max(0, min(width - 12, position(marker, width: width) - 6)))
            .highPriorityGesture(
              DragGesture(minimumDistance: 1, coordinateSpace: .named("startTrack")).onChanged { value in
                guard startEditable, !suppressStartEnd else { return }
                if !draggingStart {
                  draggingStart = true
                  onUpdateStart(marker)
                  trackEscape(true)
                }
                onUpdateStart(nearest(windowStart + value.location.x / width * span))
              }.onEnded { _ in
                finishStartDrag()
              })
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "startTrack")
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { _ in
            guard startEditable, startMarker == nil, !draggingStart else { return }
            draggingStart = true
            trackEscape(true)
          }.onEnded { value in
            guard startEditable, startMarker == nil else { return }
            if suppressStartEnd {
              suppressStartEnd = false
              draggingStart = false
              trackEscape(false)
              return
            }
            onPlaceStart(nearest(windowStart + value.location.x / width * span))
          })
        .simultaneousGesture(
          SpatialTapGesture().onEnded { value in
            guard startEditable, startMarker != nil, !draggingStart else { return }
            onPlaceStart(nearest(windowStart + value.location.x / width * span))
          })
    }.frame(height: 22)
  }

  private func finishStartDrag() {
    let cancelled = suppressStartEnd
    suppressStartEnd = false
    draggingStart = false
    trackEscape(false)
    if cancelled { onCancelStart() } else { onEndStart() }
  }

  private func position(_ marker: MediaTime, width: CGFloat) -> CGFloat {
    max(0, min(1, (marker.seconds - windowStart) / span)) * width
  }

  private func nearest(_ seconds: Double) -> MediaTime {
    guard seconds.isFinite else { return time }
    return frames.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .zero
  }

  private func trackEscape(_ active: Bool) {
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
      self.escapeMonitor = nil
    }
    guard active else { return }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53, draggingStart else { return event }
      suppressStartEnd = true
      return nil
    }
  }

  private func rangeHandle(width: CGFloat, seconds: Double, isStart: Bool) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 6, height: 42)
      .offset(x: max(0, min(1, (seconds - windowStart) / span)) * width - 3)
      .gesture(
        DragGesture(minimumDistance: 1).onChanged { drag in
          let value = max(0, min(duration, windowStart + drag.location.x / width * span))
          if isStart {
            rangeStart = min(value, rangeEnd - 0.001)
          } else {
            rangeEnd = max(value, rangeStart + 0.001)
          }
        })
  }
}
