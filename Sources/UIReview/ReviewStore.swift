import AppKit
import Observation
import ReviewCore
import ReviewMedia
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
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline = Date.distantFuture
    @ObservationIgnored private let writer: LibraryWriter
    private(set) var hasUnsavedChanges = false
    private(set) var library = ReviewLibrary()
    var replacingMotionRegion = false
    var pendingReferenceID: UUID?
    var selectedAnimationID: UUID?
    var selectedScreenshotID: UUID?
    var selectedIssueID: UUID?
    var tool: CanvasTool = .rectangle
    var zoom: Double = 0 // 0 = fit
    var errorMessage: String?
    var status = "所有内容保存在本机"
    var isBusy = false
    var showHandoff = false
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
    @ObservationIgnored var motionKeyAction: ((UInt16) -> Void)?
    @ObservationIgnored var importTask: Task<Void, Never>?
    @ObservationIgnored private var images: [UUID: NSImage] = [:]

    struct Snapshot {
        var library: ReviewLibrary
        var animationID: UUID?
        var screenshotID: UUID?
        var issueID: UUID?
        var name: String
    }

    init(repository: ReviewRepository = ReviewRepository()) {
        self.repository = repository
        self.writer = LibraryWriter(repository: repository)
        do {
            library = try writer.open()
            selectFirstMaterial()
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
        selectedAnimationID = nil; selectedScreenshotID = id; selectedIssueID = nil; zoom = 0; lastEditKey = nil
        tool = screenshot?.issues.isEmpty == false ? .select : .rectangle
    }

    private func snapshot(_ name: String) -> Snapshot {
        Snapshot(library: library, animationID: selectedAnimationID, screenshotID: selectedScreenshotID, issueID: selectedIssueID, name: name)
    }

    func commit(_ name: String, coalescing key: String? = nil, _ mutate: (inout ReviewLibrary) -> Void) {
        guard !loadFailed else { return }
        var next = library
        mutate(&next)
        guard next != library else { return }
        for i in next.reviews.indices { next.reviews[i].reconcileOrder() }
        next.schemaVersion = 2; next.revision = UUID()
        do { try repository.validate(next) } catch { errorMessage = error.localizedDescription; return }
        if key == nil || key != lastEditKey || Date().timeIntervalSince(lastEditTime) > 1.2 {
            undoStack.append(snapshot(name))
            if undoStack.count > 80 { undoStack.removeFirst() }
        }
        redoStack.removeAll(); library = next; hasUnsavedChanges = true
        lastEditKey = key; lastEditTime = Date()
        repairSelection()
        if key != nil { scheduleSave() } else { retrySave() }

    }

    private func scheduleSave() {
        saveTask?.cancel()
        if saveDeadline == .distantFuture { saveDeadline = Date().addingTimeInterval(1) }
        let delay = max(0, min(0.3, saveDeadline.timeIntervalSinceNow))
        saveTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation()
                let value = library
                saveDeadline = .distantFuture
                try await writer.saveAsync(value)
                guard library.revision == value.revision else { return }
                hasUnsavedChanges = false; status = "已自动保存到本机"
            } catch is CancellationError { }
            catch { guard !Task.isCancelled, hasUnsavedChanges else { return }; hasUnsavedChanges = true; status = "更改尚未保存 · 请重试"; errorMessage = "保存失败，输入已保留：\(error.localizedDescription)" }
        }
    }

    @discardableResult func retrySave() -> Bool {
        guard !loadFailed else { return false }
        saveTask?.cancel(); saveTask = nil; saveDeadline = .distantFuture
        do {
            try writer.save(library); hasUnsavedChanges = false; status = "已自动保存到本机"
            return true
        } catch {
            hasUnsavedChanges = true; status = "更改尚未保存 · 请重试"
            errorMessage = "保存失败，输入已保留：\(error.localizedDescription)"
            return false
        }
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
        guard !loadFailed, let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot(previous.name))
        restore(previous); library.revision = UUID(); hasUnsavedChanges = true
        if retrySave() { status = "已撤销\(previous.name)" }
    }

    func redo() {
        guard !loadFailed, let next = redoStack.popLast() else { return }
        undoStack.append(snapshot(next.name))
        restore(next); library.revision = UUID(); hasUnsavedChanges = true
        if retrySave() { status = "已重做\(next.name)" }
    }

    private func restore(_ state: Snapshot) {
        library = state.library; selectedAnimationID = state.animationID; selectedScreenshotID = state.screenshotID
        selectedIssueID = state.issueID; lastEditKey = nil; repairSelection()
    }

    private func selectFirstMaterial() {
        selectedScreenshotID = nil; selectedAnimationID = nil; selectedIssueID = nil
        guard let item = currentReview?.itemOrder.first else { return }
        if item.kind == .animation { selectedAnimationID = item.id; tool = .select }
        else { selectedScreenshotID = item.id; tool = screenshot?.issues.isEmpty == false ? .select : .rectangle }
    }

    private func repairSelection() {
        if let animation { selectedScreenshotID = nil; if !animation.issues.contains(where: { $0.id == selectedIssueID }) { selectedIssueID = nil }; return }
        selectedAnimationID = nil
        if screenshot == nil { selectFirstMaterial() }
        if issue == nil { selectedIssueID = nil }
    }

    func newReview() {
        commit("开始新的 Review") { $0.currentReviewID = nil }
        selectedAnimationID = nil; selectedScreenshotID = nil; selectedIssueID = nil
    }

    func openReview(_ id: UUID) {
        commit("切换 Review") { $0.currentReviewID = id }
        selectFirstMaterial()
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

    /// Return whether this material shortcut consumed the event. Text editing keeps its own keys.
    func handleMaterialDeletion(_ event: NSEvent, isEditingText: Bool) -> Bool {
        guard ScreenshotShortcut.shouldDelete(event, isEditingText: isEditingText),
              animation != nil || screenshot != nil else { return false }
        // Holding the key must not delete the next automatically selected material.
        guard !event.isARepeat else { return true }
        if let animation { deleteAnimation(animation.id) }
        else if let screenshot { deleteScreenshot(screenshot.id) }
        return true
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
        let videos = urls.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
        for url in urls where !videos.contains(url) {
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
        if !videos.isEmpty { importVideos(videos) }
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
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "导入素材"
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
        if currentReview?.animations.isEmpty == false { showHandoff = true; return }
        guard let review = currentReview, !review.screenshots.isEmpty, retrySave() else { return }
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
        if currentReview?.animations.isEmpty == false { showHandoff = true; return }
        guard let review = currentReview, retrySave() else { return }
        let text = "请通过 ui-review MCP 的 get_review 读取 Review \(review.id.uuidString)（\(review.title)），然后用 get_screenshot 获取相关原图及标注图。逐项理解用户评论和区域坐标，结合当前项目处理 UI 问题。若要求不清楚，请先说明疑问。"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        status = "已复制交接提示词；请在 Coding Agent 中粘贴"
    }
}
