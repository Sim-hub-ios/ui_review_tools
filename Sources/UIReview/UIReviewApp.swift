import AppKit
import Sparkle
import SwiftUI

private let appLanguageBootstrap: Void = AppLanguage.apply()

@main
struct UIReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let updaterController: SPUStandardUpdaterController
    @State private var store = ReviewStore()

    init() {
        _ = appLanguageBootstrap
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        Window("UI Review", id: "review") {
            ContentView(store: store)
                .onAppear { appDelegate.connect(store, showWindow: { openWindow(id: "review") }) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("开始新的 Review") { store.newReview() }.keyboardShortcut("n")
                Button("导入素材…") { store.chooseFiles() }.keyboardShortcut("o")
                Button("导出 Review…") { store.exportReview() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!store.canHandoff)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("重做") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("粘贴图片") { store.pasteImage() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Review") {
                Button("截取屏幕") { store.captureScreen() }
                Button("iOS Simulator 截图…") { store.chooseSimulator() }
                Divider()
                Button("历史 Review…") { store.showHistory = true }
                Button("Agent 集成…") { store.showIntegration = true }
                Button("复制当前素材") { store.copyHandoff(.currentItem) }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!store.canHandoff)
                Button("复制整个 Review") { store.copyHandoff(.wholeReview) }.disabled(!store.canHandoff)
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
        AppLanguage.apply()
        AppMenuPolicy.install()
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
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak store] event in
            if event.type != .keyDown {
                if let window = event.window, window.identifier?.rawValue == "review" {
                    ReviewFocus.endEditingOutsideText(in: window, at: event.locationInWindow)
                    store?.materialListFocused = ReviewFocus.containsMaterialList(
                        in: window, at: event.locationInWindow)
                }
                return event
            }
            if NSApp.modalWindow == nil, let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review", store?.animation != nil,
               !ReviewFocus.isEditingText(in: window),
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               [UInt16(49), 123, 124].contains(event.keyCode), let action = store?.motionKeyAction {
                action(event.keyCode); return nil
            }
            if NSApp.modalWindow == nil,
               let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review",
               store?.handleMaterialDeletion(event, isEditingText: ReviewFocus.isEditingText(in: window)) == true {
                return nil
            }
            if NSApp.modalWindow == nil,
               let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review", (store?.screenshot != nil || store?.animation != nil),
               let tool = CanvasTool.shortcut(for: event, isEditingText: ReviewFocus.isEditingText(in: window)) {
                store?.tool = tool
                return nil
            }
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(),
               NSApp.modalWindow == nil,
               let window = NSApp.keyWindow, window.attachedSheet == nil,
               window.identifier?.rawValue == "review" {
                if ReviewFocus.isEditingText(in: window) {
                    let action: Selector? = switch key {
                    case "v": #selector(NSText.paste(_:))
                    case "c": #selector(NSText.copy(_:))
                    case "x": #selector(NSText.cut(_:))
                    case "a": #selector(NSText.selectAll(_:))
                    default: nil
                    }
                    if let action, ReviewFocus.performEdit(action, in: window) { return nil }
                    if key == "v" { return event }
                } else if key == "v" {
                    store?.pasteClipboard()
                    return nil
                }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "更改尚未保存"
        alert.informativeText = "可以重试保存，或返回继续编辑。放弃后未保存的内容将丢失。"
        alert.addButton(withTitle: "重试保存"); alert.addButton(withTitle: "返回编辑"); alert.addButton(withTitle: "放弃并退出")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return store.retrySave() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow?() }
        return true
    }
}
