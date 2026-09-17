import XCTest
@testable import UIReview

final class AgentIntegrationTests: XCTestCase {
    private func fixture(motion: Bool = false) throws -> Data {
        let tools = (["get_current_review", "list_reviews", "get_review", "get_screenshot", "get_issues"] + (motion ? ["list_animations", "get_animation", "get_animation_frame", "get_animation_frames"] : [])).map {
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
    func testCodexDesktopCLIIsPreferredOverBrokenPATHLauncher() throws {
        guard let desktop = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Requires an installed Codex desktop CLI")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let i = AgentInstaller(executable: "/usr/bin/true", dataDirectory: root.path,
                               environment: ["PATH": root.path], home: root)
        XCTAssertEqual(i.findCLI(.codex), desktop)
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
    func testCustomConfigurationNeverWritesOrLaunches() throws {
        var i = installer()
        i.run = { _, args, _, input in
            XCTAssertEqual(args, ["mcp", "list", "--json"]); XCTAssertNil(input)
            return try JSONSerialization.data(withJSONObject: [["name": "ui-review", "transport": ["command": "/different/helper"]]])
        }
        let result = i.check(.codex, install: true)
        XCTAssertFalse(result.canUpgrade); XCTAssertFalse(result.healthy)
    }
    func testCodexOldPathOffersUpgradeAndRechecksNewConfiguration() throws {
        var i = installer()
        var writes = 0
        let valid = try fixture(motion: true), command = i.executable, arguments = i.arguments
        i.run = { _, args, _, input in
            if input != nil { return valid }
            if args.prefix(2) == ["mcp", "add"] { writes += 1; return Data() }
            return try JSONSerialization.data(withJSONObject: [["name": "ui-review", "enabled": writes > 0,
                "transport": ["type": "stdio", "command": writes > 0 ? command : "/old/UI Review.app/ui-review-mcp", "args": arguments]]])
        }
        let detected = i.check(.codex, install: false)
        XCTAssertTrue(detected.canUpgrade); XCTAssertEqual(detected.actionTitle, "一键升级"); XCTAssertEqual(writes, 0)
        XCTAssertTrue(i.check(.codex, install: true).healthy)
        XCTAssertFalse(i.check(.codex, install: false).canUpgrade)
        XCTAssertEqual(writes, 1)
    }
    func testClaudeUpgradePreservesOtherFieldsAndBacksUpOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var i = installer(); i.environment["CLAUDE_CONFIG_DIR"] = root.path
        let original = try JSONSerialization.data(withJSONObject: ["theme": "dark", "mcpServers": [
            "other": ["command": "keep"], "ui-review": ["command": "/old/ui-review-mcp", "args": []]]])
        try original.write(to: i.claudeConfig)
        let valid = try fixture(motion: true)
        i.run = { _, _, _, _ in valid }
        XCTAssertTrue(i.check(.claude, install: false).canUpgrade)
        XCTAssertEqual(try Data(contentsOf: i.claudeConfig), original)
        XCTAssertTrue(i.check(.claude, install: true).healthy)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: i.claudeConfig)) as? [String: Any])
        XCTAssertEqual(saved["theme"] as? String, "dark")
        XCTAssertEqual((saved["mcpServers"] as? [String: [String: Any]])?["other"]?["command"] as? String, "keep")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("backup") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
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
    func testCursorInstallWithoutCLICreatesPrivateConfigAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var i = installer(); i.home = root
        i.locateCLI = { _ in XCTFail("Cursor must not require a CLI"); return nil }
        let reply = try fixture(motion: true)
        var probes = 0
        i.run = { _, _, _, input in XCTAssertNotNil(input); probes += 1; return reply }
        XCTAssertTrue(i.check(.cursor, install: false).canInstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.cursorConfig.path))
        XCTAssertEqual(probes, 0)
        XCTAssertTrue(i.check(.cursor, install: true).healthy)
        XCTAssertTrue(i.matches(try XCTUnwrap(i.configuration(.cursor, cli: ""))))
        let saved = try Data(contentsOf: i.cursorConfig)
        XCTAssertTrue(i.check(.cursor, install: true).healthy)
        XCTAssertEqual(try Data(contentsOf: i.cursorConfig), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: i.cursorConfig.deletingLastPathComponent().path), ["mcp.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: i.cursorConfig.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testCursorUpgradePreservesOtherConfigAndBacksUpOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var i = installer(); i.home = root
        let folder = i.cursorConfig.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: ["custom": ["keep": true], "mcpServers": [
            "other": ["command": "keep"], "ui-review": ["command": "/old/ui-review-mcp", "args": []]]])
        try original.write(to: i.cursorConfig)
        let reply = try fixture(motion: true)
        i.run = { _, _, _, input in XCTAssertNotNil(input); return reply }
        XCTAssertTrue(i.check(.cursor, install: false).canUpgrade)
        XCTAssertEqual(try Data(contentsOf: i.cursorConfig), original)
        XCTAssertTrue(i.check(.cursor, install: true).healthy)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: i.cursorConfig)) as? [String: Any])
        XCTAssertEqual(saved["custom"] as? [String: Bool], ["keep": true])
        XCTAssertEqual((saved["mcpServers"] as? [String: [String: Any]])?["other"]?["command"] as? String, "keep")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("backup") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
    func testCursorRejectsMalformedAndCustomConfigurationsWithoutWritingOrLaunching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var i = installer(); i.home = root
        try FileManager.default.createDirectory(at: i.cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        i.run = { _, _, _, _ in XCTFail("Must not launch for invalid or custom config"); return Data() }
        for source in ["{bad", "[]", "{\"mcpServers\":[]}", "{\"mcpServers\":{\"ui-review\":false}}",
                       "{\"mcpServers\":{\"ui-review\":{\"command\":\"/custom/helper\"}}}"] {
            let original = Data(source.utf8)
            try original.write(to: i.cursorConfig)
            XCTAssertFalse(i.check(.cursor, install: true).healthy)
            XCTAssertEqual(try Data(contentsOf: i.cursorConfig), original)
        }
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
