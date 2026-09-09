import AppKit
import XCTest
@testable import UIReview

final class ReviewFocusTests: XCTestCase {
    @MainActor func testTitleEditingEndsInSidebarAndWorkspaceButStaysInTextFields() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let title = NSTextField(frame: NSRect(x: 200, y: 550, width: 200, height: 24))
        title.stringValue = "Review"
        let other = NSTextField(frame: NSRect(x: 600, y: 100, width: 150, height: 24))
        content.addSubview(title); content.addSubview(other)
        for point in [NSPoint(x: 50, y: 350), NSPoint(x: 450, y: 350)] {
            XCTAssertTrue(window.makeFirstResponder(title))
            XCTAssertTrue(window.firstResponder is NSTextView)
            ReviewFocus.endEditingOutsideText(in: window, at: point)
            XCTAssertFalse(window.firstResponder is NSTextView)
            XCTAssertEqual(title.stringValue, "Review")
        }
        for point in [NSPoint(x: 250, y: 560), NSPoint(x: 650, y: 110)] {
            XCTAssertTrue(window.makeFirstResponder(title))
            let editor = window.firstResponder
            ReviewFocus.endEditingOutsideText(in: window, at: point)
            XCTAssertTrue(window.firstResponder === editor)
        }
        // Native button dispatch is unaffected; the focus helper only ends editing.
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        content.addSubview(button)
        ReviewFocus.endEditingOutsideText(in: window, at: NSPoint(x: 40, y: 30))
        XCTAssertFalse(window.firstResponder is NSTextView)
    }
}
