import AppKit
import XCTest
@testable import UIReview

final class CanvasShortcutTests: XCTestCase {
    private func key(_ value: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: value,
                                      charactersIgnoringModifiers: value, isARepeat: false, keyCode: 0))
    }

    func testScreenshotDeletionRequiresCommandAndDoesNotStealTextEditing() throws {
        func deletion(_ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 51) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: keyCode))
        }
        XCTAssertTrue(ScreenshotShortcut.shouldDelete(try deletion(.command), isEditingText: false))
        XCTAssertTrue(ScreenshotShortcut.shouldDelete(try deletion(.command, keyCode: 117), isEditingText: false))
        XCTAssertFalse(ScreenshotShortcut.shouldDelete(try deletion(.command), isEditingText: true))
        XCTAssertFalse(ScreenshotShortcut.shouldDelete(try deletion([]), isEditingText: false))
        XCTAssertFalse(ScreenshotShortcut.shouldDelete(try deletion([.command, .shift]), isEditingText: false))
        XCTAssertFalse(ScreenshotShortcut.shouldDelete(try key("v", modifiers: .command), isEditingText: false))
    }

    func testToolSwitchingAndTypingProtection() throws {
        XCTAssertEqual(CanvasTool.shortcut(for: try key("v"), isEditingText: false), .select)
        XCTAssertEqual(CanvasTool.shortcut(for: try key("r"), isEditingText: false), .rectangle)
        XCTAssertEqual(CanvasTool.shortcut(for: try key("V", modifiers: .shift), isEditingText: false), .select)
        for value in ["v", "r"] {
            XCTAssertNil(CanvasTool.shortcut(for: try key(value), isEditingText: true))
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
                XCTAssertNil(CanvasTool.shortcut(for: try key(value, modifiers: modifier), isEditingText: false))
            }
        }
        XCTAssertNil(CanvasTool.shortcut(for: try key("x"), isEditingText: false))
    }
}
