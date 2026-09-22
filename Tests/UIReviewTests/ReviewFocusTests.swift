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

    @MainActor func testIsEditingTextWhenResponderIsTextViewFieldOrScrollWrapper() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let field = NSTextField(frame: NSRect(x: 10, y: 260, width: 120, height: 24))
        field.isEditable = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        editor.isEditable = true
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 80, width: 180, height: 100))
        scroll.documentView = editor
        let canvas = NSView(frame: NSRect(x: 220, y: 80, width: 120, height: 100))
        content.addSubview(field)
        content.addSubview(scroll)
        content.addSubview(canvas)

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(ReviewFocus.isEditingText(in: window))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(ReviewFocus.isEditingText(in: window))
        XCTAssertTrue(window.makeFirstResponder(scroll.contentView))
        XCTAssertTrue(ReviewFocus.isEditingText(in: window), "SwiftUI TextEditor often leaves the clip view first responder")
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertFalse(ReviewFocus.isEditingText(in: window))
    }

    @MainActor func testMaterialListRegionIsRecognizedByClickLocation() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 600))
        sidebar.identifier = ReviewFocus.materialListIdentifier
        let canvas = NSView(frame: NSRect(x: 240, y: 0, width: 560, height: 600))
        content.addSubview(sidebar)
        content.addSubview(canvas)
        XCTAssertTrue(ReviewFocus.containsMaterialList(in: window, at: NSPoint(x: 40, y: 300)))
        XCTAssertFalse(ReviewFocus.containsMaterialList(in: window, at: NSPoint(x: 400, y: 300)))
    }

    @MainActor func testCommandVPastesIntoFocusedTextInsteadOfImporting() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        editor.isEditable = true
        editor.string = "现有"
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 80, width: 220, height: 100))
        scroll.documentView = editor
        window.contentView?.addSubview(scroll)
        XCTAssertTrue(window.makeFirstResponder(scroll.contentView))

        let previous = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("粘贴进来", forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previous { NSPasteboard.general.setString(previous, forType: .string) }
        }

        XCTAssertTrue(ReviewFocus.performEdit(#selector(NSText.paste(_:)), in: window))
        XCTAssertTrue(editor.string.contains("粘贴进来"))
    }
}
