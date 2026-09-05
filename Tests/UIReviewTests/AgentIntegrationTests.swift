import XCTest
@testable import UIReview

final class AgentIntegrationTests: XCTestCase {
    private func fixture() throws -> Data {
        let tools = ["get_current_review", "list_reviews", "get_review", "get_screenshot", "get_issues"].map {
            ["name": $0, "annotations": ["readOnlyHint": true]] as [String: Any]
        }
        return try [
            ["id": 1, "result": ["protocolVersion": "2025-11-25", "serverInfo": ["name": "ui-review"]]],
            ["id": 2, "result": ["tools": tools]]
        ].map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
    }
    private func installer() -> AgentInstaller {
        AgentInstaller(executable: "/usr/bin/true", dataDirectory: "/tmp/review with spaces/中文", environment: [:], home: URL(fileURLWithPath: "/tmp/UIReview-mock-home-unused"), locateCLI: { _ in "/usr/bin/true" })
    }
    func testArgumentArraysPreserveSpacesAndSpecialCharacters() throws {
        var i = installer()
        i = AgentInstaller(executable: "/Applications/UI Review $test.app/helper", dataDirectory: "/tmp/中文 \"quoted\"")
        XCTAssertEqual(try i.installationArguments(.codex), ["mcp", "add", "ui-review", "--", i.executable, "--data-dir", i.dataDirectory])
        let args = try i.installationArguments(.claude)
        XCTAssertEqual(Array(args.prefix(5)), ["mcp", "add-json", "--scope", "user", "ui-review"])
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[5].utf8)) as? [String: Any])
        XCTAssertEqual(config["command"] as? String, i.executable)
        XCTAssertEqual(config["args"] as? [String], i.arguments)
    }
    func testInstallationRechecksConfigurationAndIsIdempotent() throws {
        var i = installer()
        var configured = false, writes = 0, probes = 0
        let valid = try fixture(), command = i.executable, arguments = i.arguments
        i.run = { _, args, _, input in
            if input != nil { probes += 1; return valid }
            if args.prefix(2) == ["mcp", "add"] { writes += 1; configured = true; return Data() }
            return try JSONSerialization.data(withJSONObject: configured ? [["name": "ui-review", "enabled": true, "transport": ["type": "stdio", "command": command, "args": arguments]]] : [])
        }
        let absent = i.check(.codex, install: false)
        XCTAssertTrue(absent.canInstall); XCTAssertEqual(writes, 0); XCTAssertEqual(probes, 0)
        XCTAssertTrue(i.check(.codex, install: true).healthy)
        XCTAssertTrue(i.check(.codex, install: true).healthy)
        XCTAssertEqual(writes, 1); XCTAssertEqual(probes, 2)
    }
    func testConflictingOrDisabledConfigurationNeverWritesOrLaunches() throws {
        for disabled in [false, true] {
            var i = installer(); var calls = 0
            let command = disabled ? i.executable : "/different/helper", arguments = i.arguments
            i.run = { _, args, _, input in
                calls += 1
                XCTAssertEqual(args, ["mcp", "list", "--json"]); XCTAssertNil(input)
                return try JSONSerialization.data(withJSONObject: [["name": "ui-review", "enabled": !disabled, "transport": ["command": command, "args": arguments]]])
            }
            let result = i.check(.codex, install: true)
            XCTAssertFalse(result.healthy); XCTAssertFalse(result.canInstall); XCTAssertTrue(result.message.contains("未覆盖")); XCTAssertEqual(calls, 1)
        }
    }
    func testConfiguredButUnhealthyDoesNotReportSuccess() throws {
        var i = installer(); let command = i.executable, arguments = i.arguments
        i.run = { _, _, _, input in
            if input != nil { return Data("{}\n".utf8) }
            return try JSONSerialization.data(withJSONObject: [["name": "ui-review", "transport": ["command": command, "args": arguments]]])
        }
        let state = i.check(.codex, install: false)
        XCTAssertTrue(state.installed); XCTAssertFalse(state.healthy); XCTAssertTrue(state.message.contains("连接检测失败"))
    }
    func testClaudeMalformedConfigurationIsNotReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude.json"), content = Data("{bad".utf8)
        try content.write(to: file)
        var i = installer(); i.environment["CLAUDE_CONFIG_DIR"] = root.path
        i.run = { _, _, _, _ in XCTFail("Should not run any write or probe"); return Data() }
        XCTAssertFalse(i.check(.claude, install: true).healthy)
        XCTAssertEqual(try Data(contentsOf: file), content)
    }
    func testClaudeFirstInstallCreatesPrivateConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-first-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var i = installer(); i.environment["CLAUDE_CONFIG_DIR"] = root.path
        let reply = try fixture()
        i.run = { _, _, _, input in XCTAssertNotNil(input); return reply }
        let state = i.check(.claude, install: true)
        XCTAssertTrue(state.healthy, state.message)
        let config = try XCTUnwrap(i.configuration(.claude, cli: "/usr/bin/true"))
        XCTAssertTrue(i.matches(config))
        let mode = try FileManager.default.attributesOfItem(atPath: i.claudeConfig.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testProbeRejectsWrongProtocolMissingToolsAndNonReadOnlyTools() throws {
        let good = try fixture()
        XCTAssertNoThrow(try AgentInstaller.validateProbe(good))
        let source = String(decoding: good, as: UTF8.self)
        for modified in [source.replacingOccurrences(of: "2025-11-25", with: "old"),
                         source.replacingOccurrences(of: "get_issues", with: "delete_all"),
                         source.replacingOccurrences(of: "true", with: "false")] {
            XCTAssertThrowsError(try AgentInstaller.validateProbe(Data(modified.utf8)))
        }
    }
    func testProcessTimeoutDoesNotHang() throws {
        let start = Date()
        XCTAssertThrowsError(try IntegrationProcess.run("/bin/sleep", ["10"], environment: [:], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testRealClaudeInstallationPreservesOtherConfigAndIsIdempotent() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/UI Review.app/Contents/MacOS/ui-review-mcp")
        var i = AgentInstaller(executable: helper.path, dataDirectory: "/tmp/UIReview-install-check-empty")
        guard i.findCLI(.claude) != nil, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Requires Claude CLI and packaged helper")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-agent-install-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        i.environment["CLAUDE_CONFIG_DIR"] = root.path
        let original: [String: Any] = ["theme": "dark", "mcpServers": ["other-server": ["type": "stdio", "command": "/usr/bin/true", "args": []]]]
        try JSONSerialization.data(withJSONObject: original).write(to: i.claudeConfig)
        let result = i.check(.claude, install: true)
        XCTAssertTrue(result.healthy, result.message)
        let after = try Data(contentsOf: i.claudeConfig)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(saved["theme"] as? String, "dark")
        let servers = try XCTUnwrap(saved["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["other-server"]?["command"] as? String, "/usr/bin/true")
        XCTAssertTrue(i.matches(try XCTUnwrap(servers["ui-review"])))
        XCTAssertTrue(i.check(.claude, install: true).healthy)
        XCTAssertEqual(after, try Data(contentsOf: i.claudeConfig))
        let health = try IntegrationProcess.run(try XCTUnwrap(i.findCLI(.claude)), ["mcp", "list"], environment: i.processEnvironment)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).contains("✔ Connected"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("ui-review-backup") }
        XCTAssertEqual(backups.count, 1)
    }
    func testRealPackagedHelperHandshake() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/UI Review.app/Contents/MacOS/ui-review-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Build Release app for packaged helper check") }
        try AgentInstaller(executable: helper.path, dataDirectory: "/tmp/UIReview-install-probe-unused").probe()
    }
}
