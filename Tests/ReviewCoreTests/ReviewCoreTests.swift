import XCTest
import CoreGraphics
import ReviewCore

final class ReviewCoreTests: XCTestCase {
    private func repository() throws -> ReviewRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ReviewRepository(root: root)
    }

    private func fixture(_ repo: ReviewRepository) throws -> Review {
        let ctx = CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 200, width: 200, height: 200))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let id = UUID()
        let path = try repo.storePNG(ImageFiles.png(ctx.makeImage()!), id: id)
        let issue = Issue(region: Region(x: 40, y: 50, width: 100, height: 80), comment: "左右间距统一为 16pt\n箭头保持对齐", imageWidth: 200, imageHeight: 400)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Review(title: "设置页面检查", createdAt: date, screenshots: [Screenshot(id: id, name: "设置.png", pixelWidth: 200, pixelHeight: 400, originalPath: path, createdAt: date, issues: [issue])])
    }

    func testCoordinatesClampAndNormalizeInOriginalPixels() {
        let region = Region(x: -5, y: 180, width: 150, height: 80).clamped(toWidth: 100, height: 200)
        XCTAssertEqual(region, Region(x: 0, y: 180, width: 100, height: 20))
        XCTAssertEqual(region.normalized(width: 100, height: 200), Region(x: 0, y: 0.9, width: 1, height: 0.1))
        XCTAssertFalse(Region(x: .nan, y: 0, width: 1, height: 1).isValid)
    }

    func testIndependentReaderSeesSavedReviewAndUnchangedImage() throws {
        let repo = try repository(), review = try fixture(repo)
        let lib = ReviewLibrary(currentReviewID: review.id, reviews: [review])
        try repo.save(lib)
        let loaded = try ReviewRepository(root: repo.root).load()
        XCTAssertEqual(loaded.currentReview?.screenshots, review.screenshots)
        XCTAssertEqual(loaded.currentReview?.title, review.title)
        XCTAssertEqual(loaded.currentReview?.screenshots[0].issues[0].normalizedRegion.y, 0.125)
    }

    func testInvalidSaveDoesNotOverwriteExistingData() throws {
        let repo = try repository(), review = try fixture(repo)
        var lib = ReviewLibrary(currentReviewID: review.id, reviews: [review])
        try repo.save(lib)
        let before = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        lib.reviews[0].screenshots[0].issues[0].region.width = 10000
        XCTAssertThrowsError(try repo.save(lib))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("library.json")), before)
    }

    func testRejectsTraversalAndSymlinkAssets() throws {
        let repo = try repository()
        let id = UUID()
        let shot = Screenshot(id: id, name: "bad", pixelWidth: 20, pixelHeight: 20, originalPath: "../../private.png")
        XCTAssertThrowsError(try repo.assetURL(for: shot))
        let assets = repo.root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("\(id).png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let symlink = Screenshot(id: id, name: "bad", pixelWidth: 20, pixelHeight: 20, originalPath: "assets/\(id).png")
        XCTAssertThrowsError(try repo.assetURL(for: symlink))
    }

    func testCorruptedLibraryFailsInsteadOfStartingEmpty() throws {
        let repo = try repository()
        try Data("{broken".utf8).write(to: repo.root.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try repo.load())
    }

    func testExportContainsAllAssetsAndDoesNotOverwrite() throws {
        let repo = try repository(), review = try fixture(repo)
        let destination = repo.root.appendingPathComponent("export")
        try ReviewExport.write(review, repository: repo, to: destination)
        for path in ["review.md", "review.json", "screenshots/screenshot-01.png", "screenshots/screenshot-01-annotated.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
        }
        let markdown = try String(contentsOf: destination.appendingPathComponent("review.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("> 左右间距统一为 16pt\n> 箭头保持对齐"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("review.json"))) as! [String: Any]
        let shot = (object["screenshots"] as! [[String: Any]])[0]
        XCTAssertEqual(shot["originalPath"] as? String, "screenshots/screenshot-01.png")
        XCTAssertNotNil(shot["annotatedPath"])
        XCTAssertThrowsError(try ReviewExport.write(review, repository: repo, to: destination))
    }

    func testAnnotatedPNGPreservesOrientationAndDrawsInTopLeftCoordinates() throws {
        let repo = try repository(), review = try fixture(repo), shot = review.screenshots[0]
        let data = try ImageFiles.annotated(shot, repository: repo)
        let annotated = try ImageFiles.decode(data).image
        XCTAssertEqual(annotated.width, 200); XCTAssertEqual(annotated.height, 400)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 200 * 400 * 4)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: 200, height: 400, bitsPerComponent: 8, bytesPerRow: 800,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(annotated, in: CGRect(x: 0, y: 0, width: 200, height: 400))
            }
            return Array(bytes[(y * 200 + x) * 4 ..< (y * 200 + x) * 4 + 4])
        }
        XCTAssertGreaterThan(pixel(180, 10)[0], 240, "top stays red")
        XCTAssertGreaterThan(pixel(180, 390)[1], 240, "bottom stays green")
        XCTAssertGreaterThan(pixel(100, 50)[2], 200, "blue annotation at original y=50")
        XCTAssertLessThan(pixel(100, 350)[2], 20, "no vertically mirrored annotation")
    }

    func testMissingImageExportLeavesNoPartialDestination() throws {
        let repo = try repository(), review = try fixture(repo)
        try FileManager.default.removeItem(at: repo.assetURL(for: review.screenshots[0]))
        let destination = repo.root.appendingPathComponent("failed-export")
        XCTAssertThrowsError(try ReviewExport.write(review, repository: repo, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
