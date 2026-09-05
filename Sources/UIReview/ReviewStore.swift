import AppKit
import Observation
import ReviewCore
import UniformTypeIdentifiers

enum CanvasTool: String, CaseIterable {
    case select, rectangle

    static func shortcut(for event: NSEvent, isEditingText: Bool) -> CanvasTool? {
        guard !isEditingText, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": return .select
        case "r": return .rectangle
        default: return nil
        }
    }
}

enum ScreenshotShortcut {
    static func shouldDelete(_ event: NSEvent, isEditingText: Bool) -> Bool {
        !isEditingText && [UInt16(51), UInt16(117)].contains(event.keyCode) &&
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }
}

@MainActor @Observable
final class ReviewStore {
    let repository: ReviewRepository
    private(set) var library = ReviewLibrary()
    var selectedScreenshotID: UUID?
    var selectedIssueID: UUID?
    var tool: CanvasTool = .rectangle
    var zoom: Double = 0 // 0 = fit
    var errorMessage: String?
    var status = "所有内容保存在本机"
    var isBusy = false
    var showHistory = false
    var showIntegration = false
    var showSimulator = false
    var simulators: [SimulatorDevice] = []
    private(set) var loadFailed = false
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastEditKey: String?
    private var lastEditTime = Date.distantPast
    // Cache fills during View.body evaluation must not invalidate the observation graph.
    @ObservationIgnored private var images: [UUID: NSImage] = [:]

    struct Snapshot {
        var library: ReviewLibrary
        var screenshotID: UUID?
        var issueID: UUID?
        var name: String
    }

    init(repository: ReviewRepository = ReviewRepository()) {
        self.repository = repository
        do {
            library = try repository.load()
            selectedScreenshotID = library.currentReview?.screenshots.first?.id
        } catch {
            loadFailed = true
            errorMessage = "无法读取保存的数据，已停止写入以保护原文件。\n\(error.localizedDescription)"
        }
    }

    var currentReview: Review? { library.currentReview }
    var screenshot: Screenshot? { currentReview?.screenshots.first { $0.id == selectedScreenshotID } }
    var issue: Issue? { screenshot?.issues.first { $0.id == selectedIssueID } }
    var canUndo: Bool { !undoStack.isEmpty && !loadFailed }
    var canRedo: Bool { !redoStack.isEmpty && !loadFailed }

    func image(for shot: Screenshot) -> NSImage? {
        if let image = images[shot.id] { return image }
        guard let url = try? repository.assetURL(for: shot), let cg = try? ImageFiles.load(url) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images[shot.id] = image
        if images.count > 12 { images = [shot.id: image] }
        return image
    }

    func selectScreenshot(_ id: UUID?) {
        selectedScreenshotID = id; selectedIssueID = nil; zoom = 0; lastEditKey = nil
        tool = screenshot?.issues.isEmpty == false ? .select : .rectangle
    }

    private func snapshot(_ name: String) -> Snapshot {
        Snapshot(library: library, screenshotID: selectedScreenshotID, issueID: selectedIssueID, name: name)
    }

    private func commit(_ name: String, coalescing key: String? = nil, _ mutate: (inout ReviewLibrary) -> Void) {
        guard !loadFailed else { return }
        var next = library
        mutate(&next)
        guard next != library else { return }
        do {
            try repository.save(next)
            if key == nil || key != lastEditKey || Date().timeIntervalSince(lastEditTime) > 1.2 {
                undoStack.append(snapshot(name))
                if undoStack.count > 80 { undoStack.removeFirst() }
            }
            redoStack.removeAll(); library = next
            lastEditKey = key; lastEditTime = Date()
            repairSelection(); status = "已自动保存到本机"
        } catch { errorMessage = "保存失败：\(error.localizedDescription)" }
    }

    private func mutateScreenshot(_ name: String, key: String? = nil, _ change: (inout Screenshot) -> Void) {
        let reviewID = library.currentReviewID, shotID = selectedScreenshotID
        commit(name, coalescing: key) { lib in
            guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }),
                  let s = lib.reviews[r].screenshots.firstIndex(where: { $0.id == shotID }) else { return }
            change(&lib.reviews[r].screenshots[s]); lib.reviews[r].updatedAt = Date()
        }
    }

    func undo() {
        guard let previous = undoStack.last else { return }
        do {
            try repository.save(previous.library)
            redoStack.append(snapshot(previous.name)); undoStack.removeLast()
            restore(previous); status = "已撤销\(previous.name)"
        } catch { errorMessage = error.localizedDescription }
    }

    func redo() {
        guard let next = redoStack.last else { return }
        do {
            try repository.save(next.library)
            undoStack.append(snapshot(next.name)); redoStack.removeLast()
            restore(next); status = "已重做\(next.name)"
        } catch { errorMessage = error.localizedDescription }
    }

    private func restore(_ state: Snapshot) {
        library = state.library; selectedScreenshotID = state.screenshotID
        selectedIssueID = state.issueID; lastEditKey = nil; repairSelection()
    }

    private func repairSelection() {
        if screenshot == nil { selectedScreenshotID = currentReview?.screenshots.first?.id }
        if issue == nil { selectedIssueID = nil }
    }

    func newReview() {
        commit("开始新的 Review") { $0.currentReviewID = nil }
        selectedScreenshotID = nil; selectedIssueID = nil
    }

    func openReview(_ id: UUID) {
        commit("切换 Review") { $0.currentReviewID = id }
        selectScreenshot(currentReview?.screenshots.first?.id)
        showHistory = false
    }

    func renameReview(_ title: String) {
        let id = library.currentReviewID
        commit("重命名 Review", coalescing: "title") { lib in
            guard let r = lib.reviews.firstIndex(where: { $0.id == id }) else { return }
            lib.reviews[r].title = title; lib.reviews[r].updatedAt = Date()
        }
    }

    func deleteReview(_ id: UUID) {
        commit("删除 Review") { lib in
            lib.reviews.removeAll { $0.id == id }
            if lib.currentReviewID == id { lib.currentReviewID = nil }
        }
    }

    func renameScreenshot(_ id: UUID, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reviewID = library.currentReviewID
        commit("重命名截图") { lib in
            guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }),
                  let s = lib.reviews[r].screenshots.firstIndex(where: { $0.id == id }) else { return }
            lib.reviews[r].screenshots[s].name = name; lib.reviews[r].updatedAt = Date()
        }
    }

    func deleteScreenshot(_ id: UUID) {
        let reviewID = library.currentReviewID
        commit("删除截图") { lib in
            guard let r = lib.reviews.firstIndex(where: { $0.id == reviewID }) else { return }
            lib.reviews[r].screenshots.removeAll { $0.id == id }; lib.reviews[r].updatedAt = Date()
        }
    }

    func addIssue(_ region: Region) {
        guard let shot = screenshot else { return }
        let r = region.clamped(toWidth: Double(shot.pixelWidth), height: Double(shot.pixelHeight))
        guard r.width >= 2, r.height >= 2 else { return }
        let issue = Issue(region: r, imageWidth: shot.pixelWidth, imageHeight: shot.pixelHeight)
        mutateScreenshot("添加问题") { $0.issues.append(issue) }
        if screenshot?.issues.contains(where: { $0.id == issue.id }) == true { selectedIssueID = issue.id }
        tool = .select
    }

    func updateRegion(_ id: UUID, region: Region) {
        mutateScreenshot("调整区域") { shot in
            guard let i = shot.issues.firstIndex(where: { $0.id == id }) else { return }
            let r = region.clamped(toWidth: Double(shot.pixelWidth), height: Double(shot.pixelHeight))
            guard r.width >= 2, r.height >= 2 else { return }
            shot.issues[i].region = r
            shot.issues[i].normalizedRegion = r.normalized(width: shot.pixelWidth, height: shot.pixelHeight)
        }
    }

    func updateComment(_ id: UUID, comment: String) {
        mutateScreenshot("编辑评论", key: "comment-\(id)") { shot in
            guard let i = shot.issues.firstIndex(where: { $0.id == id }) else { return }
            shot.issues[i].comment = comment
        }
    }

    func deleteIssue(_ id: UUID) { mutateScreenshot("删除问题") { $0.issues.removeAll { $0.id == id } } }

    func importFiles(_ urls: [URL]) {
        guard !isBusy, !loadFailed else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 100_000_000 else {
                    throw ReviewError.invalidData("请选择不超过 100MB 的图片文件。")
                }
                try importImage(Data(contentsOf: url), name: url.lastPathComponent)
            }
            catch { errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)" }
        }
    }

    func importImage(_ data: Data, name: String) throws {
        guard !loadFailed else { throw ReviewError.invalidData("数据读取失败，无法导入。") }
        let decoded = try ImageFiles.decode(data)
        let id = UUID()
        let path = try repository.storePNG(decoded.png, id: id)
        let shot = Screenshot(id: id, name: name, pixelWidth: decoded.width, pixelHeight: decoded.height, originalPath: path)
        commit("导入截图") { lib in
            if lib.currentReviewID == nil {
                let title = "Review · " + Date().formatted(date: .abbreviated, time: .shortened)
                let review = Review(title: title); lib.reviews.insert(review, at: 0); lib.currentReviewID = review.id
            }
            guard let r = lib.reviews.firstIndex(where: { $0.id == lib.currentReviewID }) else { return }
            lib.reviews[r].screenshots.append(shot); lib.reviews[r].updatedAt = Date()
        }
        if currentReview?.screenshots.contains(where: { $0.id == id }) == true { selectScreenshot(id) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "导入截图"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func pasteImage() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importFiles(urls); return
        }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            do { try importImage(data, name: "剪贴板 \(Date().formatted(date: .omitted, time: .standard)).png") }
            catch { errorMessage = error.localizedDescription }
        } else { status = "剪贴板中没有图片" }
    }

    func exportReview() {
        guard let review = currentReview, !review.screenshots.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "导出到此处"; panel.message = "将在所选位置创建新的 Review 文件夹。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("review-\(Int(Date().timeIntervalSince1970))-\(review.id.uuidString.prefix(6))")
        do {
            try ReviewExport.write(review, repository: repository, to: destination)
            status = "已导出 \(review.screenshots.count) 张截图与 \(review.issueCount) 个问题"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { errorMessage = error.localizedDescription }
    }

    func copyHandoff() {
        guard let review = currentReview else { return }
        let text = "请通过 ui-review MCP 的 get_review 读取 Review \(review.id.uuidString)（\(review.title)），然后用 get_screenshot 获取相关原图及标注图。逐项理解用户评论和区域坐标，结合当前项目处理 UI 问题。若要求不清楚，请先说明疑问。"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        status = "已复制交接提示词；请在 Coding Agent 中粘贴"
    }
}
