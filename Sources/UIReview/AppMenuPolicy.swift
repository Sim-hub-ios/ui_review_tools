import AppKit

enum AppLanguage {
    static let identifier = "zh-Hans"

    static func apply(_ defaults: UserDefaults = .standard) {
        defaults.set([identifier], forKey: "AppleLanguages")
        defaults.set(true, forKey: "NSDisabledDictationMenuItem")
        defaults.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
    }
}

enum AppMenuPolicy {
    private static var observer: Any?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu else { return }
            sanitize(menu)
        }
    }

    static func isBlocked(_ item: NSMenuItem) -> Bool {
        if item.isSeparatorItem { return false }
        if let action = item.action, blockedSelectorNames.contains(NSStringFromSelector(action)) { return true }
        return blockedTitles.contains(normalizedTitle(item.title))
    }

    static func sanitize(_ menu: NSMenu) {
        for item in menu.items where isBlocked(item) {
            menu.removeItem(item)
        }
        collapseSeparators(menu)
    }

    private static func collapseSeparators(_ menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var index = 0
        while index < menu.items.count - 1 {
            if menu.items[index].isSeparatorItem && menu.items[index + 1].isSeparatorItem {
                menu.removeItem(at: index + 1)
            } else {
                index += 1
            }
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockedSelectorNames: Set<String> = [
        "cut:", "copy:", "paste:", "delete:", "selectAll:",
        "pasteAsPlainText:", "pasteAsRichText:", "pasteAndMatchStyle:",
        "orderFrontCharacterPalette:",
        "performClose:",
    ]

    private static let blockedTitles: Set<String> = [
        "Cut", "Copy", "Paste", "Delete", "Select All",
        "Paste and Match Style", "Paste and Match Formatting",
        "AutoFill", "Start Dictation...", "Emoji & Symbols",
        "Close", "Close Window",
        "剪切", "拷贝", "复制", "粘贴", "删除", "全选",
        "粘贴并匹配样式", "粘贴并匹配格式",
        "自动填充", "开始听写...", "表情与符号",
        "关闭", "关闭窗口",
    ]
}
