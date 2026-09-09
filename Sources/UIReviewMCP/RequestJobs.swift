import Foundation
import ReviewCore

final class RequestJobs: @unchecked Sendable {
  private let lock = NSLock()
  private var reserved: Set<String> = []
  private var cancelled: Set<String> = []
  private var tasks: [String: Task<Void, Never>] = [:]
  func reserve(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard reserved.count < 128, !reserved.contains(key) else { return false }
    reserved.insert(key)
    return true
  }
  func attach(_ task: Task<Void, Never>, key: String) {
    lock.lock()
    defer { lock.unlock() }
    guard reserved.contains(key) else { return }
    tasks[key] = task
    if cancelled.contains(key) { task.cancel() }
  }
  func cancel(_ key: String) {
    lock.lock()
    defer { lock.unlock() }
    guard reserved.contains(key) else { return }
    cancelled.insert(key)
    tasks[key]?.cancel()
  }
  func remove(_ key: String) {
    lock.lock()
    defer { lock.unlock() }
    tasks.removeValue(forKey: key)
    reserved.remove(key)
    cancelled.remove(key)
  }
}

actor FrameGate {
  static let shared = FrameGate()
  private var active = 0
  private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
  func acquire(_ id: UUID) async throws {
    try Task.checkCancellation()
    if active < 2 {
      active += 1
      return
    }
    guard waiting.count < 8 else { throw ReviewError.invalidData("BUSY: 取帧队列已满。") }
    try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
  }
  func cancel(_ id: UUID) {
    if let i = waiting.firstIndex(where: { $0.0 == id }) {
      waiting.remove(at: i).1.resume(throwing: CancellationError())
    }
  }
  func release() {
    if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() }
  }
}

final class RequestDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  func expire() {
    lock.lock()
    expired = true
    lock.unlock()
  }
  var isExpired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return expired
  }
}
