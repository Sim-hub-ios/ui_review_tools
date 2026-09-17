import Foundation
import Observation
import Darwin

enum AgentClient: String, CaseIterable, Identifiable {
    case codex, claude, cursor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }
}

struct AgentInstallationState {
    var message = "尚未检测"
    var installed = false
    var healthy = false
    var canInstall = false
    var canUpgrade = false
    var actionTitle: String { canUpgrade ? "一键升级" : (installed ? "已安装" : "一键安装") }
}

struct AgentIntegrationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Uses argument arrays, never a shell. Both output streams are drained while the process runs.
struct IntegrationProcess {
    static func run(_ executable: String, _ args: [String], environment: [String: String], input: Data? = nil,
                    timeout: TimeInterval = 15) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        final class Result: @unchecked Sendable { var data = Data() }
        let result = Result(), group = DispatchGroup()
        try process.run()
        group.enter()
        DispatchQueue.global().async { result.data = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { _ = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit(); deadline.cancel(); group.wait()
        guard process.terminationStatus == 0 else {
            throw AgentIntegrationError(message: "命令未完成（退出码 \(process.terminationStatus)），请检查客户端配置或重试。")
        }
        return result.data
    }
}

struct AgentInstaller {
    let executable: String
    let dataDirectory: String
    var environment = ProcessInfo.processInfo.environment
    var home = FileManager.default.homeDirectoryForCurrentUser
    var locateCLI: ((AgentClient) -> String?)?
    var run: (String, [String], [String: String], Data?) throws -> Data = {
        try IntegrationProcess.run($0, $1, environment: $2, input: $3)
    }

    var arguments: [String] { ["--data-dir", dataDirectory] }
    var processEnvironment: [String: String] {
        var env = environment
        let common = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = ((env["PATH"] ?? "").split(separator: ":").map(String.init) + common).joined(separator: ":")
        return env
    }
    func findCLI(_ client: AgentClient) -> String? {
        if let locateCLI { return locateCLI(client) }
        var candidates = (processEnvironment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(client.rawValue)" }
        // Desktop binaries avoid npm launchers depending on the PATH-selected Node architecture.
        if client == .codex {
            candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"] + candidates
        }
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
    var claudeConfig: URL {
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty { return URL(fileURLWithPath: path).appendingPathComponent(".claude.json") }
        return home.appendingPathComponent(".claude.json")
    }
    var cursorConfig: URL { home.appendingPathComponent(".cursor/mcp.json") }

    func configuration(_ client: AgentClient, cli: String) throws -> [String: Any]? {
        if client == .codex {
            let data = try run(cli, ["mcp", "list", "--json"], processEnvironment, nil)
            guard let servers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AgentIntegrationError(message: "无法识别 Codex 配置，请更新客户端后重试。")
            }
            guard let server = servers.first(where: { $0["name"] as? String == "ui-review" }) else { return nil }
            var config = server["transport"] as? [String: Any] ?? [:]
            config["enabled"] = server["enabled"]
            return config
        }
        let file = client == .cursor ? cursorConfig : claudeConfig
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw AgentIntegrationError(message: "\(client.title) 配置格式错误，未修改配置。")
        }
        if let servers = root["mcpServers"] {
            guard let entries = servers as? [String: Any] else { throw AgentIntegrationError(message: "MCP 配置格式错误，未修改配置。") }
            if let entry = entries["ui-review"] {
                guard let config = entry as? [String: Any] else { throw AgentIntegrationError(message: "已有同名配置无法识别，未覆盖。") }
                return config
            }
        }
        return nil
    }
    func matches(_ config: [String: Any]) -> Bool {
        (config["type"] as? String ?? "stdio") == "stdio" &&
        config["command"] as? String == executable && config["args"] as? [String] == arguments &&
        (config["enabled"] as? Bool ?? true) &&
        (config["env"] as? [String: String] ?? [:]).isEmpty &&
        (config["env_vars"] as? [String] ?? []).isEmpty &&
        (config["cwd"] as? String ?? "").isEmpty
    }
    /// Only replace a recognizable local UI Review helper; unrelated same-name servers stay protected.
    func isUpgradeable(_ config: [String: Any]) -> Bool {
        guard (config["type"] as? String ?? "stdio") == "stdio",
              let command = config["command"] as? String,
              command == executable || URL(fileURLWithPath: command).lastPathComponent == "ui-review-mcp",
              (config["env"] as? [String: String] ?? [:]).isEmpty,
              (config["env_vars"] as? [String] ?? []).isEmpty,
              (config["cwd"] as? String ?? "").isEmpty else { return false }
        let args = config["args"] as? [String] ?? []
        return args.isEmpty || (args.count == 2 && args[0] == "--data-dir")
    }
    func installationArguments(_ client: AgentClient) throws -> [String] {
        if client == .codex { return ["mcp", "add", "ui-review", "--", executable] + arguments }
        guard client == .claude else { throw AgentIntegrationError(message: "Cursor 使用 JSON 配置，无需命令行安装。") }
        let data = try JSONSerialization.data(withJSONObject: ["type": "stdio", "command": executable, "args": arguments])
        return ["mcp", "add-json", "--scope", "user", "ui-review", String(decoding: data, as: UTF8.self)]
    }
    func installClaude(replacing expected: [String: Any]? = nil) throws {
        try installJSON(at: claudeConfig, replacing: expected)
    }
    /// Preserve unrelated JSON fields, permissions and a backup for JSON-based clients.
    func installJSON(at configURL: URL, replacing expected: [String: Any]? = nil) throws {
        let file = configURL.resolvingSymlinksInPath(), fm = FileManager.default
        let previous = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var root = try previous.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard root != nil else { throw AgentIntegrationError(message: "客户端配置格式错误，未修改。") }
        if let existing = root?["mcpServers"], !(existing is [String: Any]) {
            throw AgentIntegrationError(message: "MCP 配置格式错误，未修改。")
        }
        var servers = root?["mcpServers"] as? [String: Any] ?? [:]
        guard expected.map({ NSDictionary(dictionary: $0).isEqual(servers["ui-review"]) }) ?? (servers["ui-review"] == nil) else { throw AgentIntegrationError(message: "配置已变化，请重新检测后再安装。") }
        servers["ui-review"] = ["type": "stdio", "command": executable, "args": arguments]
        root?["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root!, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if previous != nil {
            try fm.copyItem(at: file, to: file.appendingPathExtension("ui-review-backup-\(UUID().uuidString)"))
        }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".ui-review-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        let permissions = previous == nil ? 0o600 : ((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600)
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw AgentIntegrationError(message: "无法写入客户端配置，请检查目录权限。")
        }
        let current = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == previous else { throw AgentIntegrationError(message: "客户端配置在安装期间发生变化，请重试。") }
        guard rename(temporary.path, file.path) == 0 else { throw AgentIntegrationError(message: "无法替换客户端配置，请检查目录权限。") }
    }
    func check(_ client: AgentClient, install: Bool) -> AgentInstallationState {
        let locatedCLI = client == .cursor ? "" : findCLI(client)
        guard let cli = locatedCLI else { return .init(message: "未找到客户端命令行工具，请先安装 \(client.title) 或使用手动配置。") }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .init(message: "未找到包内 MCP 服务，请使用完整的 UI Review.app。")
        }
        var installed = false
        do {
            let existing = try configuration(client, cli: cli)
            let upgrade = existing.map { !matches($0) } ?? false
            if upgrade, let existing {
                guard isUpgradeable(existing) else {
                    return .init(message: "已有自定义 ui-review 配置，无法自动升级。请检查手动配置。")
                }
                guard try probe() else {
                    return .init(message: "当前 App 内的 MCP 仍是旧版，请先更新 UI Review App。", installed: true)
                }
                guard install else {
                    return .init(message: "检测到旧版路径或配置，可一键升级到当前 App 的 MCP（并启用）。其他 MCP 配置会保留。", installed: true, canUpgrade: true)
                }
            }
            if existing == nil || upgrade {
                guard install else { return .init(message: "尚未安装 UI Review MCP", canInstall: true) }
                if client == .cursor { try installJSON(at: cursorConfig, replacing: existing) }
                else if client == .claude { try installClaude(replacing: existing) }
                else {
                    let folder = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
                    let config = folder.appendingPathComponent("config.toml")
                    if FileManager.default.fileExists(atPath: config.path) {
                        try FileManager.default.copyItem(at: config, to: config.appendingPathExtension("ui-review-backup-\(UUID().uuidString)"))
                    }
                    _ = try run(cli, try installationArguments(client), processEnvironment, nil)
                }
            }
            guard let saved = try configuration(client, cli: cli), matches(saved) else {
                throw AgentIntegrationError(message: "安装后配置核对失败，请检查客户端设置。")
            }
            installed = true
            let motion = try probe()
            return .init(message: motion ? "配置已安装 · 截图和动画读取可用。请在客户端重新连接。" : "当前 App 内的 MCP 仍是旧版，请先更新 UI Review App。", installed: true, healthy: true)
        } catch {
            return .init(message: (installed ? "配置已安装，连接检测失败：" : "检测或安装失败：") + error.localizedDescription, installed: installed)
        }
    }
    @discardableResult func probe() throws -> Bool {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "UIReview-install-check", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        ]
        let input = try requests.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
        let output = try run(executable, arguments, processEnvironment, input)
        return try Self.validateProbe(output)
    }
    @discardableResult static func validateProbe(_ data: Data) throws -> Bool {
        let replies = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        let initialized = replies.first { $0["id"] as? Int == 1 }?["result"] as? [String: Any]
        let listed = replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
        let tools = listed?["tools"] as? [[String: Any]] ?? []
        let expected: Set<String> = ["get_current_review", "list_reviews", "get_review", "get_screenshot", "get_issues"]
        guard initialized?["protocolVersion"] as? String == "2025-11-25",
              (initialized?["serverInfo"] as? [String: Any])?["name"] as? String == "ui-review",
              expected.isSubset(of: Set(tools.compactMap { $0["name"] as? String })),
              tools.allSatisfy({ ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }) else {
            throw AgentIntegrationError(message: "MCP 握手或只读工具检测未通过。")
        }
        let motion: Set<String> = ["list_animations", "get_animation", "get_animation_frame", "get_animation_frames"]
        return motion.isSubset(of: Set(tools.compactMap { $0["name"] as? String }))
    }
}

@MainActor @Observable
final class AgentIntegrationModel {
    var states: [AgentClient: AgentInstallationState] = [:]
    var busy: AgentClient?
    func refresh(_ client: AgentClient, installer: AgentInstaller, install: Bool = false) async {
        guard busy == nil else { return }
        busy = client
        states[client] = .init(message: install ? "正在安装或升级并检测…" : "正在检测…")
        let state = await Task.detached { installer.check(client, install: install) }.value
        states[client] = state
        busy = nil
    }
}
