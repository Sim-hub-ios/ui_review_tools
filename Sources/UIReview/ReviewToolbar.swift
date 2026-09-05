import AppKit
import SwiftUI

/// Figma 1:114. Keep toolbar geometry independent of macOS toolbar display preferences.
struct ReviewToolbar: View {
    @Bindable var store: ReviewStore
    @Environment(\.colorScheme) private var colorScheme

    private var foreground: Color { colorScheme == .dark ? Color(red: 233/255, green: 237/255, blue: 244/255) : Color(nsColor: .labelColor) }
    private var background: Color { colorScheme == .dark ? Color(red: 41/255, green: 44/255, blue: 50/255) : Color(red: 247/255, green: 248/255, blue: 250/255) }
    private var accent: Color { colorScheme == .dark ? Color(red: 118/255, green: 165/255, blue: 1) : Color(red: 39/255, green: 101/255, blue: 234/255) }

    private var reviewNameWidth: CGFloat {
        let text = store.currentReview?.title ?? "新的 Review"
        return min(220, max(100, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 24))
    }

    var body: some View {
        HStack(spacing: 22) {
            NativeWindowControls().frame(width: 54, height: 16)
            Text("UI Review").font(.system(size: 17)).fixedSize()
            HStack(spacing: 5) {
                if let review = store.currentReview {
                    TextField("Review 名称", text: Binding(get: { store.currentReview?.title ?? review.title }, set: store.renameReview))
                        .textFieldStyle(.plain).accessibilityLabel("Review 名称")
                } else {
                    Text("新的 Review").lineLimit(1)
                }
                Menu {
                    Button("历史 Review…") { store.showHistory = true }
                    Button("开始新的 Review") { store.newReview() }.disabled(store.currentReview == nil)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Review 操作")
            }.font(.system(size: 13)).frame(minWidth: 100, idealWidth: reviewNameWidth, maxWidth: reviewNameWidth).layoutPriority(-1)
            Spacer(minLength: 0)
            Button("截取屏幕") { store.captureScreen() }.fixedSize()
                .help("截取屏幕 · ⌃⌥⌘S").disabled(store.isBusy || store.loadFailed)
            Button("模拟器截图") { store.chooseSimulator() }.fixedSize()
                .help("iOS Simulator 截图").disabled(store.isBusy || store.loadFailed)
            Button("导入图片") { store.chooseFiles() }.fixedSize()
                .help("导入图片 · ⌘O").disabled(store.isBusy || store.loadFailed)
            Button("导出 Review") { store.exportReview() }.fixedSize()
                .help("导出 Review · ⇧⌘E").disabled(store.currentReview?.screenshots.isEmpty != false)
            Button { store.copyHandoff() } label: {
                Text("复制交接提示词").font(.system(size: 12))
                    .foregroundStyle(colorScheme == .dark ? Color(red: 34/255, green: 37/255, blue: 43/255) : .white)
                    .frame(width: 142, height: 32)
                    .background(accent.opacity(store.currentReview == nil ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(store.currentReview == nil)
            .help("复制交接提示词，粘贴到已配置 MCP 的 Coding Agent")
        }
        .font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(foreground)
        .padding(.horizontal, 20).frame(height: 64)
        .background { WindowDragArea().background(background) }
    }
}

/// Use AppKit's standard button styles and NSWindow actions inside the custom title bar.
private struct NativeWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ nsView: ControlsView, context: Context) {}

    final class ControlsView: NSView {
        private var controls: [NSButton] = []
        private var observers: [NSObjectProtocol] = []
        private weak var hostedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, hostedWindow !== window else { return }
            cleanup()
            hostedWindow = window
            let actions: [(NSWindow.ButtonType, Selector)] = [
                (.closeButton, #selector(NSWindow.performClose(_:))),
                (.miniaturizeButton, #selector(NSWindow.performMiniaturize(_:))),
                (.zoomButton, #selector(NSWindow.toggleFullScreen(_:)))
            ]
            for (type, action) in actions {
                guard let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
                button.target = window; button.action = action
                addSubview(button); controls.append(button)
            }
            hideTitlebarButtons()
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.hideTitlebarButtons()
                })
            }
            needsLayout = true
        }
        private func hideTitlebarButtons() {
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                hostedWindow?.standardWindowButton(type)?.isHidden = true
            }
        }
        override func layout() {
            super.layout()
            hideTitlebarButtons()
            for (index, button) in controls.enumerated() {
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 20, y: (bounds.height - button.frame.height) / 2))
            }
        }
        func cleanup() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            for button in controls { button.removeFromSuperview() }
            controls.removeAll()
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                hostedWindow?.standardWindowButton(type)?.isHidden = false
            }
            hostedWindow = nil
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
    static func dismantleNSView(_ nsView: ControlsView, coordinator: ()) { nsView.cleanup() }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}
