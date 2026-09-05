import AppKit
import SwiftUI

@main
struct UIReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var store = ReviewStore()

    var body: some Scene {
        Window("UI Review", id: "review") {
            ContentView(store: store)
                .onAppear { appDelegate.connect(store, showWindow: { openWindow(id: "review") }) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("开始新的 Review") { store.newReview() }.keyboardShortcut("n")
                Button("导入图片…") { store.chooseFiles() }.keyboardShortcut("o")
                Button("导出 Review…") { store.exportReview() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.currentReview?.screenshots.isEmpty != false)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("重做") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Button("粘贴图片") { store.pasteImage() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Review") {
                Button("截取屏幕") { store.captureScreen() }
                Button("iOS Simulator 截图…") { store.chooseSimulator() }
                Divider()
                Button("历史 Review…") { store.showHistory = true }
                Button("Agent 集成…") { store.showIntegration = true }
                Button("复制交接提示词") { store.copyHandoff() }.disabled(store.currentReview == nil)
            }
        }
        Settings { IntegrationView(store: store, isSettings: true) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var store: ReviewStore?
    private var shortcut: GlobalScreenshotShortcut?
    private var pasteMonitor: Any?
    private var showWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }

    func connect(_ store: ReviewStore, showWindow: @escaping () -> Void) {
        guard self.store == nil else { return }
        self.store = store
        self.showWindow = showWindow
        shortcut = GlobalScreenshotShortcut { [weak store] in
            showWindow()
            store?.captureScreen()
        }
        if shortcut?.enable(true) == false { store.status = "全局截图快捷键已被占用，请使用工具栏截图" }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            if NSApp.modalWindow == nil,
               let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review", let screenshot = store?.screenshot,
               ScreenshotShortcut.shouldDelete(event, isEditingText: window.firstResponder is NSTextView || window.firstResponder is NSTextField) {
                if !event.isARepeat { store?.deleteScreenshot(screenshot.id) }
                return nil
            }
            if NSApp.modalWindow == nil,
               let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review", store?.screenshot != nil,
               let tool = CanvasTool.shortcut(for: event, isEditingText: window.firstResponder is NSTextView || window.firstResponder is NSTextField) {
                store?.tool = tool
                return nil
            }
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               NSApp.modalWindow == nil,
               NSApp.keyWindow?.attachedSheet == nil,
               NSApp.keyWindow?.identifier?.rawValue == "review",
               !(NSApp.keyWindow?.firstResponder is NSTextView) {
                store?.pasteImage(); return nil
            }
            return event
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--import"), args.count > i + 1 {
            store.importFiles([URL(fileURLWithPath: args[i + 1])])
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        showWindow?()
        store?.importFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow?() }
        return true
    }
}
