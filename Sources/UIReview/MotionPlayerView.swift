import AppKit
import AVFoundation
import SwiftUI

/// Render through AVPlayerLayer to avoid the AVKit SwiftUI generic metadata crash.
/// Playback controls and timing remain owned by MotionSession.
struct MotionPlayerView: NSViewRepresentable {
  let player: AVPlayer
  var onPaste: (() -> Void)? = nil

  func makeNSView(context: Context) -> MotionPlayerSurface {
    let view = MotionPlayerSurface()
    view.videoLayer.player = player
    view.onPaste = onPaste
    return view
  }

  func updateNSView(_ view: MotionPlayerSurface, context: Context) {
    if view.videoLayer.player !== player { view.videoLayer.player = player }
    view.onPaste = onPaste
  }

  static func dismantleNSView(_ view: MotionPlayerSurface, coordinator: ()) {
    view.videoLayer.player = nil
    view.onPaste = nil
  }
}

final class MotionPlayerSurface: NSView {
  let videoLayer = AVPlayerLayer()
  var onPaste: (() -> Void)?

  override var acceptsFirstResponder: Bool { onPaste != nil }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  @objc func paste(_ sender: Any?) { onPaste?() }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    videoLayer.videoGravity = .resizeAspect
    videoLayer.backgroundColor = NSColor.black.cgColor
    layer = videoLayer
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? {
    onPaste == nil ? nil : super.hitTest(point)
  }
}
