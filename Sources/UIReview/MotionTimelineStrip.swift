import ReviewCore
import ReviewMedia
import SwiftUI

struct MotionTimelineStrip: View {
  @Bindable var session: MotionSession
  let repository: ReviewRepository
  let issues: [AnimationIssue]
  @State private var thumbnails: [NSImage] = []
  @State private var magnification = 1.0
  private var duration: Double { max(0.001, session.asset?.duration.seconds ?? 1) }
  private var span: Double { duration / magnification }
  private var start: Double {
    max(0, min(duration - span, floor(session.time.seconds / span) * span))
  }
  var body: some View {
    VStack(spacing: 5) {
      HStack {
        Text(String(format: "%.3f–%.3f s", start, start + span)).foregroundStyle(.secondary)
        Spacer()
        Button("−") { magnification = max(1, magnification / 2) }.disabled(magnification == 1)
        Text("\(Int(magnification))×").monospacedDigit()
        Button("＋") { magnification = min(32, magnification * 2) }
      }
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
          if session.useRange {
            let left = max(0, min(1, (session.rangeStart - start) / span)) * width
            let right = max(0, min(1, (session.rangeEnd - start) / span)) * width
            Rectangle().fill(.blue.opacity(0.18)).frame(width: max(0, right - left), height: 40)
              .offset(x: left)
            handle(width: width, seconds: session.rangeStart, isStart: true)
            handle(width: width, seconds: session.rangeEnd, isStart: false)
          }
          Rectangle().fill(.blue).frame(width: 2, height: 48).offset(
            x: max(0, min(1, (session.time.seconds - start) / span)) * width
          ).allowsHitTesting(false)
          ForEach(Array(issues.enumerated()), id: \.element.id) { n, issue in
            if issue.target.first.seconds >= start && issue.target.first.seconds <= start + span {
              Text("\(n+1)").font(.system(size: 9)).foregroundStyle(.white).padding(2).background(
                .blue, in: Circle()
              ).offset(x: (issue.target.first.seconds - start) / span * width, y: 42)
                .allowsHitTesting(false)
            }
          }
        }.contentShape(Rectangle()).onTapGesture { location in
          session.seek(session.nearest(start + location.x / width * span))
        }
      }.frame(height: 58).coordinateSpace(name: "motionTimeline")
    }.font(.caption)
      .task(
        id:
          "\(session.asset?.id.uuidString ?? "")-\(Int(magnification))-\(Int(start*1000))-\(session.frames.count)"
      ) {
        guard let asset = session.asset else { return }
        var images: [NSImage] = []
        for n in 0..<10 {
          if Task.isCancelled { return }
          let time = session.nearest(start + span * Double(n) / 10)
          if let result = try? await VideoService.frame(
            repository.assetURL(for: asset), asset: asset, at: time, maxDimension: 128)
          {
            images.append(
              NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height)))
          }
        }
        if !Task.isCancelled { thumbnails = images }
      }
  }
  private func handle(width: CGFloat, seconds: Double, isStart: Bool) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 6, height: 42)
      .offset(x: max(0, min(1, (seconds - start) / span)) * width - 3)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named("motionTimeline")).onChanged {
          drag in
          let value = max(0, min(duration, start + drag.location.x / width * span))
          if isStart {
            session.rangeStart = min(value, session.rangeEnd - 0.001)
          } else {
            session.rangeEnd = max(value, session.rangeStart + 0.001)
          }
        })
  }
}
