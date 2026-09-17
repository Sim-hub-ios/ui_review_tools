import XCTest

final class SparkleTests: XCTestCase {
    func testInfoPlistUsesGitHubLatestAppcastAndManualInstall() throws {
        let plist = try infoPlist()
        XCTAssertEqual(plist["SUFeedURL"] as? String,
                       "https://github.com/Sim-hub-ios/ui_review_tools/releases/latest/download/appcast.xml")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        let key = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
    }

    func testPublishReleaseFailsWhenArtifactsAreMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runPublish(["--dry-run"], root: root)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("Missing"), result.err)
    }

    func testPublishReleaseDryRunUsesVersionedGitHubAssets() throws {
        let version = try XCTUnwrap(try infoPlist()["CFBundleShortVersionString"] as? String)
        let root = try publishFixture(version: version, notes: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runPublish(["--dry-run"], root: root)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("gh release create \"v\(version)\""), result.out)
        XCTAssertTrue(result.out.contains("gh release upload \"v\(version)\""), result.out)
        XCTAssertTrue(result.out.contains("--clobber"), result.out)
        XCTAssertTrue(result.out.contains("--repo Sim-hub-ios/ui_review_tools"), result.out)
        XCTAssertTrue(result.out.contains("--title \"UI Review \(version)\""), result.out)
        XCTAssertTrue(result.out.contains("--notes \"UI Review \(version)\""), result.out)
        XCTAssertTrue(result.out.contains("\"\(root.path)/build/UIReview-\(version).pkg\""), result.out)
        XCTAssertFalse(result.out.contains("UI Review-\(version).pkg"), result.out)
        XCTAssertTrue(result.out.contains("\"\(root.path)/build/sparkle/UIReview-\(version).zip\""), result.out)
        XCTAssertTrue(result.out.contains("\"\(root.path)/build/sparkle/appcast.xml\""), result.out)
        XCTAssertFalse(result.out.contains("--notes-file"), result.out)
    }

    func testPublishReleaseDryRunEmbedsOptionalNotesFile() throws {
        let version = try XCTUnwrap(try infoPlist()["CFBundleShortVersionString"] as? String)
        let root = try publishFixture(version: version, notes: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runPublish(["--dry-run"], root: root)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("--notes-file \"\(root.path)/docs/releases/UIReview-\(version).md\""), result.out)
        XCTAssertFalse(result.out.contains("--notes \"UI Review \(version)\""), result.out)
    }

    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func publishFixture(version: String, notes: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sparkle = root.appendingPathComponent("build/sparkle")
        try FileManager.default.createDirectory(at: sparkle, withIntermediateDirectories: true)
        try Data("pkg".utf8).write(to: root.appendingPathComponent("build/UI Review-\(version).pkg"))
        try Data("zip".utf8).write(to: sparkle.appendingPathComponent("UIReview-\(version).zip"))
        try Data("appcast".utf8).write(to: sparkle.appendingPathComponent("appcast.xml"))
        if notes {
            let notesDir = root.appendingPathComponent("docs/releases")
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
            try Data("notes".utf8).write(to: notesDir.appendingPathComponent("UIReview-\(version).md"))
        }
        return root
    }

    private func runPublish(_ args: [String], root: URL) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot().appendingPathComponent("scripts/publish-release.sh").path] + args
        var env = ProcessInfo.processInfo.environment
        env["RELEASE_ROOT"] = root.path
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
