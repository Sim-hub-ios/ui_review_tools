import AppKit
import SwiftUI
import ReviewCore

struct AnnotationCanvas: NSViewRepresentable {
    let store: ReviewStore
    let screenshot: Screenshot

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(); updateNSView(view, context: context); return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        if view.screenshot?.id != screenshot.id { view.cancelDrag() }
        view.screenshot = screenshot; view.image = store.image(for: screenshot)
        view.selectedID = store.selectedIssueID; view.tool = store.tool; view.zoom = store.zoom
        view.onSelect = { store.selectedIssueID = $0 }
        view.onCreate = { store.addIssue($0) }
        view.onUpdate = { store.updateRegion($0, region: $1) }
        view.onDelete = { if let id = store.selectedIssueID { store.deleteIssue(id) } }
        view.onTool = { store.tool = $0 }
        view.onPaste = { store.pasteImage() }
        view.needsDisplay = true
    }
}

final class CanvasView: NSView {
    var screenshot: Screenshot?
    var image: NSImage?
    var selectedID: UUID?
    var tool: CanvasTool = .rectangle
    var zoom: Double = 0
    var onSelect: ((UUID?) -> Void)?
    var onCreate: ((Region) -> Void)?
    var onUpdate: ((UUID, Region) -> Void)?
    var onDelete: (() -> Void)?
    var onTool: ((CanvasTool) -> Void)?
    var onPaste: (() -> Void)?
    var onEscape: (() -> Void)?
    var issueNumbers: [UUID: Int] = [:]
    private var start: CGPoint?
    private var initialRegion: Region?
    private var preview: Region?
    private var draggingID: UUID?
    private var corner: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var imageRect: CGRect {
        guard let shot = screenshot else { return .zero }
        let scale = min((bounds.width - 64) / Double(shot.pixelWidth), (bounds.height - 64) / Double(shot.pixelHeight))
        // The SwiftUI scroll view sizes this view for explicit zoom levels.
        let s = max(0.01, zoom == 0 ? scale : zoom)
        let width = Double(shot.pixelWidth) * s, height = Double(shot.pixelHeight) * s
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    var scale: CGFloat { imageRect.width / CGFloat(screenshot?.pixelWidth ?? 1) }

    private func screenRect(_ r: Region) -> CGRect {
        CGRect(x: imageRect.minX + r.x * scale, y: imageRect.minY + r.y * scale,
               width: r.width * scale, height: r.height * scale)
    }

    private func pixelPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, (p.x - imageRect.minX) / scale), CGFloat(screenshot?.pixelWidth ?? 1)),
                y: min(max(0, (p.y - imageRect.minY) / scale), CGFloat(screenshot?.pixelHeight ?? 1)))
    }

    private func handles(_ rect: CGRect) -> [CGRect] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { CGRect(x: $0.x - 4, y: $0.y - 4, width: 8, height: 8) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let image, let screenshot else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 14; shadow.shadowOffset = NSSize(width: 0, height: 3); shadow.set()
        NSColor.white.setFill(); imageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        for (index, issue) in screenshot.issues.enumerated() {
            let region = draggingID == issue.id ? preview ?? issue.region : issue.region
            drawRegion(region, number: issueNumbers[issue.id] ?? index + 1, selected: issue.id == selectedID)
        }
        if draggingID == nil, let preview { drawRegion(preview, number: screenshot.issues.count + 1, selected: true) }
    }

    private func drawRegion(_ region: Region, number: Int, selected: Bool) {
        let rect = screenRect(region)
        let color = NSColor.systemBlue
        color.withAlphaComponent(selected ? 0.09 : 0.025).setFill(); rect.fill()
        let path = NSBezierPath(rect: rect); path.lineWidth = selected ? 2 : 1.5; color.setStroke(); path.stroke()
        let badge = CGRect(x: rect.minX, y: max(imageRect.minY, rect.minY - 23), width: 22, height: 22)
        color.setFill(); NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
        if selected {
            for handle in handles(rect) {
                NSColor.white.setFill(); handle.fill(); color.setStroke(); NSBezierPath(rect: handle).stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard screenshot != nil else { return }
        // Resize handles remain available even when rectangle mode is active.
        if let issue = screenshot?.issues.first(where: { $0.id == selectedID }),
           let index = handles(screenRect(issue.region)).firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(p) }) {
            corner = index; initialRegion = issue.region; draggingID = issue.id
        } else if tool == .select,
                  let issue = screenshot?.issues.reversed().first(where: { screenRect($0.region).contains(p) }) {
            onSelect?(issue.id); selectedID = issue.id; initialRegion = issue.region; draggingID = issue.id
        } else {
            guard imageRect.contains(p) else { onSelect?(nil); return }
            onSelect?(nil); selectedID = nil
            guard tool == .rectangle else { return }
            draggingID = nil; initialRegion = nil
        }
        start = pixelPoint(p); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let shot = screenshot else { return }
        let point = pixelPoint(convert(event.locationInWindow, from: nil))
        if let initial = initialRegion {
            if let corner {
                let opposite = [CGPoint(x: initial.x + initial.width, y: initial.y + initial.height),
                                CGPoint(x: initial.x, y: initial.y + initial.height),
                                CGPoint(x: initial.x, y: initial.y), CGPoint(x: initial.x + initial.width, y: initial.y)][corner]
                preview = region(from: opposite, to: point)
            } else {
                preview = Region(x: min(max(0, initial.x + point.x - start.x), Double(shot.pixelWidth) - initial.width),
                                 y: min(max(0, initial.y + point.y - start.y), Double(shot.pixelHeight) - initial.height),
                                 width: initial.width, height: initial.height)
            }
        } else { preview = region(from: start, to: point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let preview, preview.width >= 2, preview.height >= 2 {
            if let id = draggingID { onUpdate?(id, preview) } else { onCreate?(preview) }
        }
        cancelDrag()
    }

    func cancelDrag() {
        start = nil; preview = nil; draggingID = nil; initialRegion = nil; corner = nil; needsDisplay = true
    }

    private func region(from a: CGPoint, to b: CGPoint) -> Region {
        Region(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    @objc func paste(_ sender: Any?) { onPaste?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty { onDelete?() }
            else { super.keyDown(with: event) }
        case 53: cancelDrag(); onEscape?()
        default:
            if let tool = CanvasTool.shortcut(for: event, isEditingText: false) {
                onTool?(tool); return
            }
            super.keyDown(with: event)
        }
    }
}
