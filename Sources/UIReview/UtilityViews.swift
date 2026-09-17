import SwiftUI
import AppKit
import ReviewCore

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReviewStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史 Review").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            if store.library.reviews.isEmpty {
                VStack(spacing: 0) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    Text("暂无历史 Review")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 18)
                    Text("导入截图后会自动创建 Review，\n你可以随时在这里查看和切换。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.top, 8)
                    Button("返回工作区") { dismiss() }
                        .controlSize(.large)
                        .padding(.top, 22)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.library.reviews.sorted { $0.updatedAt > $1.updatedAt }) { review in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(review.title).font(.headline)
                            Text("\(review.screenshots.count) 张截图 · \(review.issueCount) 个问题 · \(review.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if review.id == store.library.currentReviewID { Text("当前").font(.caption).foregroundStyle(.blue) }
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { store.openReview(review.id) }
                    .help("双击打开，右键删除此 Review")
                    .contextMenu {
                        Button("删除 Review", role: .destructive) { store.deleteReview(review.id) }
                            .disabled(store.loadFailed)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { store.openReview(review.id) }
                }
                .listStyle(.inset)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 600, height: 420, alignment: .top)
    }
}

struct SimulatorPicker: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("iOS Simulator 截图").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
            if store.simulators.isEmpty {
                ContentUnavailableView("没有运行中的 iOS 模拟器", systemImage: "iphone",
                                       description: Text("先在 Xcode 或 Simulator 中启动设备，再刷新列表。"))
                HStack {
                    Button("打开 Simulator") {
                        Task {
                            do {
                                let data = try await CaptureService.run("/usr/bin/xcode-select", arguments: ["-p"])
                                let developer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                                NSWorkspace.shared.open(URL(fileURLWithPath: developer).appendingPathComponent("Applications/Simulator.app"))
                            } catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    Button("刷新列表") { store.showSimulator = false; store.chooseSimulator() }
                }
            } else {
                Text("选择要截取的运行中设备。不会启动、重置或改变模拟器内容。")
                    .font(.callout).foregroundStyle(.secondary)
                List(store.simulators) { device in
                    Button { store.captureSimulator(device) } label: {
                        HStack {
                            Image(systemName: "iphone").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading) { Text(device.name).font(.headline); Text(device.udid).font(.caption2).foregroundStyle(.secondary) }
                            Spacer(); Text("截图").foregroundStyle(.blue)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }
            }
        }.padding(24).frame(width: 560, height: 360)
    }
}

struct IntegrationView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReviewStore
    var isSettings = false
    @State private var copied = false
    @State private var integration = AgentIntegrationModel()
    @State private var showManual = false

    private var executable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ui-review-mcp").path
    }

    private var installer: AgentInstaller {
        AgentInstaller(executable: executable, dataDirectory: store.repository.root.path)
    }

    private var jsonConfiguration: String {
        let config: [String: Any] = ["mcpServers": ["ui-review": ["command": executable, "args": ["--data-dir", store.repository.root.path]]]]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private var tomlConfiguration: String {
        func quoted(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        return "[mcp_servers.ui-review]\ncommand = \(quoted(executable))\nargs = [\"--data-dir\", \(quoted(store.repository.root.path))]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("连接 Coding Agent").font(.title2.bold()); Spacer(); if !isSettings { Button("完成") { dismiss() } } }
            Text("只读访问本机 Review；App 退出后仍可读取已保存内容。")
                .foregroundStyle(.secondary)
            GroupBox("1. 配置 MCP") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("点击安装到当前用户的客户端配置。请先将 App 放在固定位置；其他 MCP 配置会保留。")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(AgentClient.allCases) { client in
                        let state = integration.states[client] ?? AgentInstallationState()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(client.title, systemImage: state.healthy ? "checkmark.circle.fill" : "terminal")
                                    .fontWeight(.medium)
                                Spacer()
                                if integration.busy == client { ProgressView().controlSize(.small) }
                                Button("检测状态") {
                                    Task { await integration.refresh(client, installer: installer) }
                                }
                                Button(state.actionTitle) {
                                    Task { await integration.refresh(client, installer: installer, install: true) }
                                }.disabled(!state.canInstall && !state.canUpgrade)
                            }
                            Text(state.message).font(.caption)
                                .foregroundStyle(state.healthy ? Color.green : Color.secondary)
                                .textSelection(.enabled)
                        }.padding(10).background(Color.primary.opacity(0.04)).clipShape(.rect(cornerRadius: 8))
                    }.disabled(integration.busy != nil)
                    Text("检测核对配置并连接本机 MCP 服务，不代表客户端当前会话已重新加载。Claude Code 和 Cursor 使用用户级配置，项目配置可能覆盖它。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("手动配置", isExpanded: $showManual) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Cursor：将 JSON 配置合并到 ~/.cursor/mcp.json。")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                Text(tomlConfiguration).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10)
                            }.background(Color.primary.opacity(0.04)).clipShape(.rect(cornerRadius: 6))
                            HStack {
                                Button("复制 Codex 配置") { copy(tomlConfiguration) }
                                Button("复制 Claude Code / Cursor 配置") { copy(jsonConfiguration) }
                                if copied { Text("已复制").font(.caption).foregroundStyle(.green) }
                            }
                        }.padding(.top, 8)
                    }
                }.padding(10)
            }
            GroupBox("2. 交给 Agent") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("完成截图标注后，复制交接提示词，粘贴到 Codex、Claude Code 或 Cursor 的项目会话中。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("复制当前 Review 的交接提示词") { store.copyHandoff(); copied = true }.disabled(store.currentReview == nil)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label("全局截图：⌃⌥⌘S", systemImage: "keyboard")
                Spacer()
                Button("打开本地数据目录") { NSWorkspace.shared.open(store.repository.root) }
            }.font(.caption).foregroundStyle(.secondary)
            Text("仅在点击安装时修改对应客户端配置，不上传截图。删除的截图文件暂时保留，以支持撤销；导出只包含当前 Review 中的截图。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 680)
        .task {
            for client in AgentClient.allCases { await integration.refresh(client, installer: installer) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
    }
}
