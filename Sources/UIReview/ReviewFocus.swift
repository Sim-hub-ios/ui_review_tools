import AppKit

/// Clicking non-text content ends editing before the normal click is delivered.
/// Never consumes the event: buttons, selection and canvas gestures still receive it.
@MainActor enum ReviewFocus {
    static func isEditingText(in window: NSWindow) -> Bool { editingText(in: window) != nil }

    static func performEdit(_ action: Selector, in window: NSWindow) -> Bool {
        guard let text = editingText(in: window) else { return false }
        return NSApp.sendAction(action, to: text, from: nil)
    }

    static func editingText(in window: NSWindow) -> NSResponder? {
        var candidate: NSResponder? = window.firstResponder
        while let responder = candidate {
            if let field = responder as? NSTextField, field.isEditable || field.isSelectable { return field }
            if let text = responder as? NSTextView, text.isEditable || text.isSelectable { return text }
            if let view = responder as? NSView, let scroll = view as? NSScrollView ?? view.enclosingScrollView,
               let text = scroll.documentView as? NSTextView,
               text.isEditable || text.isSelectable { return text }
            candidate = responder.nextResponder
        }
        return nil
    }

    static let materialListIdentifier = NSUserInterfaceItemIdentifier("material-list")

    static func containsMaterialList(in window: NSWindow, at windowPoint: NSPoint) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.convert(windowPoint, from: nil)
        return containsMaterialList(in: content, contentPoint: point, content: content)
    }

    private static func containsMaterialList(in view: NSView, contentPoint: NSPoint, content: NSView) -> Bool {
        if view.identifier == materialListIdentifier {
            if view.bounds.contains(view.convert(contentPoint, from: content)) { return true }
        }
        return view.subviews.contains {
            containsMaterialList(in: $0, contentPoint: contentPoint, content: content)
        }
    }

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
