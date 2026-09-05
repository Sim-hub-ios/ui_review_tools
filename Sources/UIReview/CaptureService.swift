import AppKit
import Carbon
import CoreGraphics
import ReviewCore

struct SimulatorDevice: Identifiable, Decodable {
    var udid: String
    var name: String
    var state: String
    var isAvailable: Bool?
    var id: String { udid }
}

enum CaptureService {
    static func run(_ executable: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                // Drain both streams concurrently to avoid deadlock on full pipes.
                let group = DispatchGroup()
                final class Output: @unchecked Sendable { var stdout = Data(); var stderr = Data() }
                let data = Output()
                do {
                    try process.run()
                    group.enter(); DispatchQueue.global().async {
                        data.stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave()
                    }
                    group.enter(); DispatchQueue.global().async {
                        data.stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave()
                    }
                    process.waitUntilExit(); group.wait()
                    guard process.terminationStatus == 0 else {
                        let message = String(decoding: data.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ReviewError.invalidData(message.isEmpty ? "操作已取消或未完成。" : message)
                    }
                    continuation.resume(returning: data.stdout)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func bootedSimulators() async throws -> [SimulatorDevice] {
        struct Response: Decodable { var devices: [String: [SimulatorDevice]] }
        let data = try await run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted", "--json"])
        return try JSONDecoder().decode(Response.self, from: data).devices
            .filter { $0.key.contains("iOS") }.flatMap(\.value)
            .filter { $0.state == "Booted" && $0.isAvailable != false }.sorted { $0.name < $1.name }
    }
}

extension ReviewStore {
    func captureScreen() {
        guard !isBusy, !loadFailed else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "需要屏幕录制权限。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 UI Review，必要时重新打开 App。"
            return
        }
        isBusy = true; status = "拖动选择截图区域；按 Esc 取消"
        NSApp.hide(nil)
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-capture-\(UUID())")
            let file = folder.appendingPathComponent("screen.png")
            defer {
                try? FileManager.default.removeItem(at: folder)
                isBusy = false; NSApp.activate(ignoringOtherApps: true)
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await Task.sleep(for: .milliseconds(250))
                _ = try await CaptureService.run("/usr/sbin/screencapture", arguments: ["-i", "-x", "-t", "png", file.path])
                guard FileManager.default.fileExists(atPath: file.path) else { status = "已取消截图"; return }
                try importImage(Data(contentsOf: file), name: "屏幕截图 \(Date().formatted(date: .omitted, time: .standard)).png")
            } catch {
                if !FileManager.default.fileExists(atPath: file.path) { status = "截图未完成或已取消" }
                else { errorMessage = error.localizedDescription }
            }
        }
    }

    func chooseSimulator() {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                simulators = try await CaptureService.bootedSimulators()
                showSimulator = true
            } catch { errorMessage = "无法读取模拟器。请确认已安装 Xcode 并设置 Command Line Tools。\n\(error.localizedDescription)" }
        }
    }

    func captureSimulator(_ device: SimulatorDevice) {
        guard !isBusy, UUID(uuidString: device.udid) != nil else { return }
        showSimulator = false; isBusy = true
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UIReview-sim-\(UUID())")
            let file = folder.appendingPathComponent("simulator.png")
            defer { isBusy = false; try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try await CaptureService.run("/usr/bin/xcrun", arguments: ["simctl", "io", device.udid, "screenshot", "--type=png", file.path])
                try importImage(Data(contentsOf: file), name: "\(device.name) \(Date().formatted(date: .omitted, time: .standard)).png")
            } catch { errorMessage = "模拟器截图失败：\(error.localizedDescription)" }
        }
    }
}

@MainActor
final class GlobalScreenshotShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let shortcut = Unmanaged<GlobalScreenshotShortcut>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func enable(_ enabled: Bool) -> Bool {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        guard enabled else { return true }
        let id = EventHotKeyID(signature: 0x55495256, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | optionKey | controlKey), id,
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
