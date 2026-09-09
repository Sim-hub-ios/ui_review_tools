import XCTest

@testable import ReviewCore

final class MotionCoreTests: XCTestCase {
  func testRationalComparisonDoesNotOverflowAndRangeIsHalfOpen() throws {
    let a = MediaTime(value: 9_007_199_254_740_990, timescale: Int32.max)
    let b = MediaTime(value: 9_007_199_254_740_991, timescale: Int32.max)
    XCTAssertLessThan(a, b)
    XCTAssertTrue(
      MediaTime(value: 1, timescale: 2).equivalent(to: MediaTime(value: 500, timescale: 1000)))
    let target = TemporalTarget.range(
      MediaTime(value: 1, timescale: 10), MediaTime(value: 4, timescale: 10))
    XCTAssertTrue(target.contains(MediaTime(value: 2, timescale: 10)))
    XCTAssertFalse(target.contains(MediaTime(value: 4, timescale: 10)))
    XCTAssertThrowsError(
      try TemporalTarget.range(.zero, .zero).validate(duration: MediaTime(seconds: 1)))
  }
  func testMigrationBacksUpExactBytesAndReadOnlyLoadDoesNotMigrate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID()
    let bytes = Data(
      "{\"schemaVersion\":1,\"reviews\":[{\"id\":\"\(id)\",\"title\":\"旧数据\",\"createdAt\":\"2026-09-08T00:00:00Z\",\"updatedAt\":\"2026-09-08T00:00:00Z\",\"screenshots\":[]}],\"currentReviewID\":\"\(id)\"}"
        .utf8)
    let url = root.appendingPathComponent("library.json")
    try bytes.write(to: url)
    let repo = ReviewRepository(root: root)
    XCTAssertEqual(try repo.load().schemaVersion, 1)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    let library = try LibraryWriter(repository: repo).open()
    XCTAssertEqual(library.schemaVersion, 2)
    XCTAssertEqual(library.currentReviewID, id)
    let backups = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: backups[0]), bytes)
    XCTAssertEqual(try repo.load(), library)
  }
  func testExternalWriterConflictDoesNotOverwrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = ReviewRepository(root: root)
    let writer = LibraryWriter(repository: repo)
    var mine = try writer.open()
    mine.reviews = [Review(title: "mine")]
    let other = ReviewLibrary(reviews: [Review(title: "other")])
    try repo.save(other)
    let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
    XCTAssertThrowsError(try writer.save(mine))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
  }
  func testUnknownVersionNeverOverwrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let bytes = Data("{\"schemaVersion\":99}".utf8)
    try bytes.write(to: url)
    XCTAssertThrowsError(try LibraryWriter(repository: ReviewRepository(root: root)).open())
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }
}
