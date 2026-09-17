import AppKit
import XCTest
@testable import UIReview

final class AppMenuPolicyTests: XCTestCase {
    func testBlocksSystemEditingAndInputExtras() {
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Cut", #selector(NSText.cut(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Copy", #selector(NSText.copy(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Paste", #selector(NSText.paste(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Delete", #selector(NSText.delete(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Select All", #selector(NSResponder.selectAll(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("AutoFill")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Start Dictation...")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Start Dictation…")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("剪切", #selector(NSText.cut(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("自动填充")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("开始听写…")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("表情与符号")))
    }

    func testKeepsUndoRedoPasteImageAndAppContextActions() {
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("撤销")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("重做")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("粘贴图片")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("删除问题")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("重命名…")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("删除截图及问题")))
    }

    func testBlocksWindowCloseInFileMenu() {
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Close", #selector(NSWindow.performClose(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("关闭", #selector(NSWindow.performClose(_:)))))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("Close Window")))
        XCTAssertTrue(AppMenuPolicy.isBlocked(item("关闭窗口")))
    }

    func testKeepsFileMenuReviewActions() {
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("开始新的 Review")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("导入素材...")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("导入素材…")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("导出 Review...")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("导出 Review…")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("退出")))
        XCTAssertFalse(AppMenuPolicy.isBlocked(item("Quit")))
    }

    func testSanitizeRemovesBlockedItemsAndExtraSeparators() {
        let menu = NSMenu()
        menu.addItem(item("撤销"))
        menu.addItem(item("重做"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:))))
        menu.addItem(item("Copy", #selector(NSText.copy(_:))))
        menu.addItem(item("Paste", #selector(NSText.paste(_:))))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:))))
        menu.addItem(item("粘贴图片"))
        menu.addItem(.separator())
        menu.addItem(item("AutoFill"))
        menu.addItem(item("Start Dictation…"))
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:))))

        AppMenuPolicy.sanitize(menu)

        XCTAssertEqual(menu.items.map(\.title), ["撤销", "重做", "", "粘贴图片"])
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
    }

    func testSanitizeRemovesCloseAndTrailingSeparatorFromFileMenu() {
        let menu = NSMenu()
        menu.addItem(item("开始新的 Review"))
        menu.addItem(item("导入素材…"))
        menu.addItem(item("导出 Review…"))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(NSWindow.performClose(_:))))

        AppMenuPolicy.sanitize(menu)

        XCTAssertEqual(menu.items.map(\.title), ["开始新的 Review", "导入素材…", "导出 Review…"])
        XCTAssertFalse(menu.items.contains(where: \.isSeparatorItem))
    }

    func testApplyLocksChineseAndHidesSystemTextExtras() throws {
        let suite = "AppLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        AppLanguage.apply(defaults)

        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
        XCTAssertTrue(defaults.bool(forKey: "NSDisabledDictationMenuItem"))
        XCTAssertTrue(defaults.bool(forKey: "NSDisabledCharacterPaletteMenuItem"))
    }

    func testInfoPlistDeclaresChineseOnlyLocalizations() throws {
        let plist = try infoPlist()
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "zh-Hans")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["zh-Hans"])
        let lproj = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lproj.path))
    }

    private func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }
}
