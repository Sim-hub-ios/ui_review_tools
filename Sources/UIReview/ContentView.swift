import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReviewCore

struct ContentView: View {
    @Bindable var store: ReviewStore
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            ReviewToolbar(store: store)
            HSplitView {
                ScreenshotSidebar(store: store)
                    .frame(width: 232)
                if let animation = store.animation {
                    MotionWorkspace(store: store, animation: animation)
                } else if let shot = store.screenshot {
                    CanvasPanel(store: store, screenshot: shot)
                        .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    IssuePanel(store: store, screenshot: shot)
                        .frame(minWidth: 290, idealWidth: 320, maxWidth: 400)
                } else {
                    EmptyReviewView(store: store)
                        .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Image(systemName: store.loadFailed ? "exclamationmark.triangle" : "externaldrive")
                Text(store.status).lineLimit(1)
                Spacer()
                if store.hasUnsavedChanges { Button("重试保存") { store.retrySave() } }
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    if store.importTask != nil { Button("取消") { store.importTask?.cancel() } }
                    if store.exportTask != nil { Button("取消") { store.cancelExport() } }
                }
                Button("MCP · 只读访问") { store.showIntegration = true }.buttonStyle(.plain)
                Text("\(store.currentReview?.issueCount ?? 0) 个问题").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 32)
            .background(.bar)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .ignoresSafeArea(.container, edges: .top)
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(.blue, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL, .png, .tiff, .image], isTargeted: $targeted, perform: handleDrop)
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $store.showHistory) { HistoryView(store: store) }
        .sheet(isPresented: $store.showIntegration) { IntegrationView(store: store) }
        .sheet(isPresented: $store.showSimulator) { SimulatorPicker(store: store) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !store.isBusy, !store.loadFailed else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in store.importFiles([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let data = image.tiffRepresentation else { return }
                    Task { @MainActor in
                        do { try store.importImage(data, name: "拖入图片.png") }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        return true
    }
}

struct ScreenshotSidebar: View {
    @Bindable var store: ReviewStore
    @State private var renaming: ReviewItem?
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("当前 REVIEW").font(.caption2).foregroundStyle(.secondary)
            Text(store.currentReview?.title ?? "素材").font(.headline).lineLimit(1)
            Text("\(store.currentReview?.screenshots.count ?? 0) 张截图 · \(store.currentReview?.animations.count ?? 0) 段动画").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.currentReview?.itemOrder ?? [], id: \.self) { item in material(item) }
                }
            }.scrollIndicators(.hidden)
            Button("＋ 导入素材") { store.chooseFiles() }.buttonStyle(.plain).foregroundStyle(.blue).disabled(store.loadFailed || store.isBusy)
            HStack {
                Button("历史 Review") { store.showHistory = true }
                Button("新建 Review") { store.newReview() }.disabled(store.currentReview == nil)
            }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("重命名素材", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let item = renaming {
                    if item.kind == .screenshot { store.renameScreenshot(item.id, name: name) }
                    else { store.renameAnimation(item.id, name: name) }
                }
                renaming = nil
            }
        }
    }
    @ViewBuilder private func material(_ item: ReviewItem) -> some View {
        if let shot = store.currentReview?.screenshots.first(where: { $0.id == item.id }) {
            Button { store.selectScreenshot(shot.id) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    if store.selectedScreenshotID == shot.id, let image = store.image(for: shot) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 95)
                    }
                    Label(shot.name, systemImage: "photo").lineLimit(1)
                    Text("\(shot.issues.count) 个问题").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(store.selectedScreenshotID == shot.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).contextMenu {
                Button("重命名…") { renaming = item; name = shot.name }
                Button("删除截图及问题", role: .destructive) { store.deleteScreenshot(shot.id) }
            }
        } else if let animation = store.currentReview?.animations.first(where: { $0.id == item.id }) {
            Button { store.selectAnimation(animation.id) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Label(animation.name, systemImage: "video").lineLimit(1)
                    Text("\(animation.issues.count) 个问题").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(store.selectedAnimationID == animation.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).contextMenu {
                Button("重命名…") { renaming = item; name = animation.name }
                Button("删除动画及问题", role: .destructive) { store.deleteAnimation(animation.id) }
            }
        }
    }
}

struct EmptyReviewView: View {
    let store: ReviewStore
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 42, weight: .light)).foregroundStyle(.blue)
            Text("让反馈落在具体画面上").font(.system(size: 28, weight: .semibold))
            Text("框出问题，说清修改要求，交给你的 Coding Agent。")
                .foregroundStyle(.secondary)
            VStack(spacing: 18) {
                Text("将截图或录屏拖到这里").font(.title3)
                Text("也可以按 ⌘V 粘贴剪贴板图片").foregroundStyle(.secondary)
                Button("选择素材文件") { store.chooseFiles() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            .frame(width: 480, height: 190).background(.background)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
            HStack(spacing: 34) {
                Button("截取屏幕") { store.captureScreen() }
                Button("从 iOS Simulator 获取") { store.chooseSimulator() }
            }.buttonStyle(.plain).foregroundStyle(.blue)
            Text("图片与 MP4 / MOV 录屏 · 首次导入后自动保存").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }.disabled(store.isBusy || store.loadFailed).frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CanvasPanel: View {
    @Bindable var store: ReviewStore
    let screenshot: Screenshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("工具", selection: $store.tool) {
                    Text("选择 V").tag(CanvasTool.select)
                    Text("框选 R").tag(CanvasTool.rectangle)
                }.pickerStyle(.segmented).frame(width: 160).help("V：选择 · R：框选（输入文字时不触发）")
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help("撤销 · ⌘Z")
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).help("重做 · ⇧⌘Z")
                Spacer(minLength: 0)
                Menu {
                    Button("适合窗口") { store.zoom = 0 }
                    ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { value in
                        Button("\(Int(value * 100))%") { store.zoom = value }
                    }
                } label: { Text(store.zoom == 0 ? "适合窗口" : "\(Int(store.zoom * 100))%").monospacedDigit() }
                .menuStyle(.borderlessButton).frame(width: 85)
            }.buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 48).background(.bar)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    AnnotationCanvas(store: store, screenshot: screenshot)
                        .frame(width: store.zoom == 0 ? geometry.size.width : max(geometry.size.width, CGFloat(screenshot.pixelWidth) * store.zoom + 64),
                               height: store.zoom == 0 ? geometry.size.height : max(geometry.size.height, CGFloat(screenshot.pixelHeight) * store.zoom + 64))
                }
            }
            Text("\(screenshot.name) · \(screenshot.pixelWidth) × \(screenshot.pixelHeight) px")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct IssuePanel: View {
    @Bindable var store: ReviewStore
    let screenshot: Screenshot
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("问题  \(screenshot.issues.count)").font(.title3).fontWeight(.semibold)
            Text(screenshot.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(screenshot.issues.enumerated()), id: \.element.id) { index, issue in
                        Button { store.selectedIssueID = issue.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.caption.bold()).frame(width: 22, height: 22)
                                    .background(.blue.opacity(0.12)).clipShape(Circle())
                                Text(issue.comment.isEmpty ? "待填写修改要求" : issue.comment)
                                    .font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedIssueID == issue.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04))
                                .clipShape(.rect(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        .contextMenu { Button("删除问题", role: .destructive) { store.deleteIssue(issue.id) } }
                    }
                }
            }.frame(maxHeight: screenshot.issues.isEmpty ? 0 : 220)

            if let issue = store.issue {
                Text("修改要求").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { store.issue?.id == issue.id ? store.issue?.comment ?? "" : issue.comment },
                                         set: { store.updateComment(issue.id, comment: $0) }))
                    .font(.body).scrollContentBackground(.hidden).padding(8)
                    .frame(minHeight: 110, maxHeight: 190)
                    .background(.background)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(commentFocused ? Color.accentColor : Color.secondary.opacity(0.35)))
                    .focused($commentFocused).accessibilityLabel("修改要求")
                Text("评论自动保存").font(.caption2).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("区域 · 原图像素").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "x  %.0f      y  %.0f\nw  %.0f      h  %.0f", issue.region.x, issue.region.y, issue.region.width, issue.region.height))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("拖动边框移动 · 拖动角点调整大小").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("删除问题", role: .destructive) { store.deleteIssue(issue.id) }.buttonStyle(.plain).foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "rectangle.dashed").font(.title).foregroundStyle(.blue)
                    Text(screenshot.issues.isEmpty ? "框出第一个问题" : "选择一个问题").font(.headline)
                    Text("在画布上拖动绘制矩形，然后在这里描述希望修改的内容。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("开始框选") { store.tool = .rectangle }
                }.padding(.top, 20)
                Spacer()
            }
        }.padding(20).background(.background)
    }
}
