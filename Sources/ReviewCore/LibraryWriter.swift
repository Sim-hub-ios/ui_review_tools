import CryptoKit
import Darwin
import Foundation

/// Serial disk transactions with a cooperating-process lock and optimistic conflict detection.
/// Readers never acquire the lock and only see atomic snapshots. V1 bytes are backed up verbatim.
public final class LibraryWriter {
  private let repository: ReviewRepository
  private let queue = DispatchQueue(label: "ui-review.library-writer")
  private var expected: Data?
  public init(repository: ReviewRepository) { self.repository = repository }
  private var url: URL { repository.root.appendingPathComponent("library.json") }
  private func disk() throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: repository.root, withIntermediateDirectories: true)
    let path = repository.root.appendingPathComponent("writer.lock").path
    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw ReviewError.invalidData("无法取得数据写锁。") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw ReviewError.invalidData("另一个 UI Review 正在保存，请稍后重试。")
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
  public func open() throws -> ReviewLibrary {
    try queue.sync {
      try locked {
        expected = try disk()
        var library = try repository.load()
        if library.schemaVersion == 1 {
          guard let bytes = expected else { throw ReviewError.invalidData("升级源文件不存在。") }
          let folder = repository.root.appendingPathComponent("backups")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          guard
            folder.resolvingSymlinksInPath()
              == repository.root.resolvingSymlinksInPath().appendingPathComponent("backups")
          else { throw ReviewError.invalidData("备份目录不能是外部链接。") }
          let backup = folder.appendingPathComponent("library-v1-\(UUID()).json")
          try bytes.write(to: backup, options: .withoutOverwriting)
          guard try Data(contentsOf: backup) == bytes else {
            throw ReviewError.invalidData("升级备份校验失败。")
          }
          library.schemaVersion = 2
          library.revision = UUID()
          try repository.save(library)
          expected = try disk()
        }
        return library
      }
    }
  }
  private func saveTransaction(_ value: ReviewLibrary) throws {
    try locked {
      guard try disk() == expected else {
        throw ReviewError.invalidData("数据已被其他进程修改。已停止写入，请保留当前内容并重新打开应用。")
      }
      try repository.save(value)
      expected = try disk()
    }
  }
  public func save(_ value: ReviewLibrary) throws { try queue.sync { try saveTransaction(value) } }
  public func saveAsync(_ value: ReviewLibrary) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          try self.saveTransaction(value)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
