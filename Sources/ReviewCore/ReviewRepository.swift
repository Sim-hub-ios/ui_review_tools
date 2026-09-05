import Foundation

/// Assets are immutable. Only library.json is replaced atomically, so independent
/// MCP readers always observe a complete, committed snapshot.
public struct ReviewRepository: Sendable {
    public let root: URL

    public init(root: URL = ReviewRepository.defaultRoot) { self.root = root.standardizedFileURL }

    public static var defaultRoot: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.count > index + 1 {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let path = ProcessInfo.processInfo.environment["UI_REVIEW_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UIReview", isDirectory: true)
    }

    public func load() throws -> ReviewLibrary {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ReviewLibrary() }
        let data = try Data(contentsOf: url)
        let library = try ReviewJSON.decoder().decode(ReviewLibrary.self, from: data)
        try validate(library)
        return library
    }

    public func save(_ library: ReviewLibrary) throws {
        try validate(library)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ReviewJSON.encoder().encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }

    public func assetURL(for screenshot: Screenshot) throws -> URL {
        let path = screenshot.originalPath
        guard path == "assets/\(screenshot.id.uuidString).png" else {
            throw ReviewError.invalidData("截图路径不合法。")
        }
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
        let allowed = root.resolvingSymlinksInPath().appendingPathComponent("assets").path + "/"
        guard url.path.hasPrefix(allowed) else { throw ReviewError.invalidData("截图路径超出数据目录。") }
        return url
    }

    public func storePNG(_ data: Data, id: UUID) throws -> String {
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("assets").path else {
            throw ReviewError.invalidData("图片资产目录不能指向数据目录之外。")
        }
        let path = "assets/\(id.uuidString).png"
        let url = root.appendingPathComponent(path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ReviewError.invalidData("截图 ID 已存在。")
        }
        try data.write(to: url, options: .atomic)
        return path
    }

    public func validate(_ library: ReviewLibrary) throws {
        guard library.schemaVersion == 1 else { throw ReviewError.invalidData("数据版本不受支持，请使用较新版本的 UI Review。") }
        if let id = library.currentReviewID, !library.reviews.contains(where: { $0.id == id }) {
            throw ReviewError.invalidData("当前 Review 不存在。")
        }
        guard Set(library.reviews.map(\.id)).count == library.reviews.count else {
            throw ReviewError.invalidData("Review ID 重复。")
        }
        for review in library.reviews {
            guard Set(review.screenshots.map(\.id)).count == review.screenshots.count else {
                throw ReviewError.invalidData("截图 ID 重复。")
            }
            for shot in review.screenshots {
                guard shot.pixelWidth > 0, shot.pixelHeight > 0,
                      Double(shot.pixelWidth) * Double(shot.pixelHeight) <= 40_000_000 else {
                    throw ReviewError.invalidData("截图尺寸超出限制（最大 4000 万像素）。")
                }
                _ = try assetURL(for: shot)
                guard Set(shot.issues.map(\.id)).count == shot.issues.count else {
                    throw ReviewError.invalidData("问题 ID 重复。")
                }
                for issue in shot.issues {
                    let r = issue.region
                    guard r.isValid, r.x + r.width <= Double(shot.pixelWidth) + 0.01,
                          r.y + r.height <= Double(shot.pixelHeight) + 0.01 else {
                        throw ReviewError.invalidData("问题区域超出截图边界。")
                    }
                    let expected = r.normalized(width: shot.pixelWidth, height: shot.pixelHeight)
                    guard abs(expected.x - issue.normalizedRegion.x) < 0.000001,
                          abs(expected.y - issue.normalizedRegion.y) < 0.000001,
                          abs(expected.width - issue.normalizedRegion.width) < 0.000001,
                          abs(expected.height - issue.normalizedRegion.height) < 0.000001 else {
                        throw ReviewError.invalidData("归一化坐标与像素坐标不一致。")
                    }
                }
            }
        }
    }
}
