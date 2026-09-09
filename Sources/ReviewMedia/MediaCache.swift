import Foundation
import ReviewCore

actor MediaCache {
  static let shared = MediaCache()
  private var indexes: [String: [MediaTime]] = [:]
  private var indexOrder: [String] = []
  private var frames: [String: VideoFrame] = [:]
  private var frameOrder: [String] = []
  private var bytes = 0
  func index(_ key: String) -> [MediaTime]? { indexes[key] }
  func saveIndex(_ value: [MediaTime], key: String) {
    if indexes[key] == nil { indexOrder.append(key) }
    indexes[key] = value
    while indexOrder.count > 8 { indexes.removeValue(forKey: indexOrder.removeFirst()) }
  }
  func frame(_ key: String) -> VideoFrame? { frames[key] }
  func saveFrame(_ value: VideoFrame, key: String) {
    guard frames[key] == nil else { return }
    let size = value.image.bytesPerRow * value.image.height
    guard size <= 96_000_000 else { return }
    while bytes + size > 96_000_000, let first = frameOrder.first {
      if let old = frames.removeValue(forKey: first) {
        bytes -= old.image.bytesPerRow * old.image.height
      }
      frameOrder.removeFirst()
    }
    frames[key] = value
    frameOrder.append(key)
    bytes += size
  }
}
