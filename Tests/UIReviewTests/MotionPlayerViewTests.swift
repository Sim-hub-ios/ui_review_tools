import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import UIReview

final class MotionPlayerViewTests: XCTestCase {
  @MainActor func testVideoPasteUsesFocusedResponderWithoutHijackingText() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    let surface = MotionPlayerSurface(frame: window.contentView!.bounds)
    window.contentView!.addSubview(surface)
    var pastes = 0
    surface.onPaste = { pastes += 1 }
    XCTAssertTrue(window.makeFirstResponder(surface))
    // Route through this window's responder chain, independent of key-window state in CI.
    pastes = 0
    XCTAssertTrue(window.firstResponder!.tryToPerform(#selector(MotionPlayerSurface.paste(_:)), with: nil))
    XCTAssertEqual(pastes, 1)
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView!.addSubview(editor)
    XCTAssertTrue(window.makeFirstResponder(editor))
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(pastes, 1)
    surface.onPaste = nil
    XCTAssertFalse(surface.acceptsFirstResponder)
  }

  @MainActor func testPlaybackViewsMountReplaceAndDetachPlayers() async throws {
    _ = NSApplication.shared
    let first = AVPlayer(), second = AVPlayer()
    // Materialize the SwiftUI -> native view path missing from session-only tests.
    let host = NSHostingView(rootView: MotionPlayerView(player: first))
    host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func surfaces(_ view: NSView) -> [MotionPlayerSurface] {
      (view as? MotionPlayerSurface).map { [$0] } ?? view.subviews.flatMap(surfaces)
    }
    let surface = try XCTUnwrap(surfaces(host).first)
    XCTAssertTrue(surface.videoLayer.player === first)
    XCTAssertEqual(surface.videoLayer.videoGravity, .resizeAspect)
    host.rootView = MotionPlayerView(player: second)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(surface.videoLayer.player === second)
    MotionPlayerView.dismantleNSView(surface, coordinator: ())
    XCTAssertNil(surface.videoLayer.player)
  }
}
