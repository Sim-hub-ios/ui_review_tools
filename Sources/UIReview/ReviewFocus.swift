import AppKit

/// Clicking non-text content ends editing before the normal click is delivered.
/// Never consumes the event: buttons, selection and canvas gestures still receive it.
@MainActor enum ReviewFocus {
    static func endEditingOutsideText(in window: NSWindow, at point: NSPoint) {
        guard window.attachedSheet == nil, NSApp.modalWindow == nil,
              let editor = window.firstResponder as? NSTextView,
              editor.isEditable, let content = window.contentView,
              let hit = content.hitTest(content.convert(point, from: nil)) else { return }
        var candidate: NSView? = hit
        while let view = candidate {
            if let field = view as? NSTextField, field.isEditable || field.isSelectable { return }
            if let text = view as? NSTextView, text.isEditable || text.isSelectable { return }
            // The empty area of a text editor's scroll view belongs to that editor too.
            if let scroll = view as? NSScrollView,
               let text = scroll.documentView as? NSTextView,
               text.isEditable || text.isSelectable { return }
            candidate = view.superview
        }
        window.makeFirstResponder(nil)
    }
}
