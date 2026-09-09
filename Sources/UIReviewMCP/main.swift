import Foundation
import ReviewCore
import ReviewMedia

// Local stdio MCP server. stdout is exclusively newline-delimited JSON-RPC.
// No listener, network access, data mutation or command execution is exposed.
let arguments = CommandLine.arguments
let root: URL
if let index = arguments.firstIndex(of: "--data-dir"), arguments.count > index + 1 {
    root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
} else { root = ReviewRepository.defaultRoot }
let repository = ReviewRepository(root: root)
var initialized = false

func textContent(_ object: Any) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    return ["type": "text", "text": String(decoding: data, as: UTF8.self)]
}

func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: ReviewJSON.encoder().encode(value))
}

let descriptions: [(String, String, [String: Any], [String])] = [
    ("get_current_review", "读取当前已保存 Review，包含截图元数据、所有问题、评论和坐标。使用 get_screenshot 获取图片。", [:], []),
    ("list_reviews", "列出本机保存的 Review 摘要。", [:], []),
    ("get_review", "按 Review ID 读取完整 Review。", ["review_id": ["type": "string", "description": "Review UUID"]], ["review_id"]),
    ("get_screenshot", "获取截图元数据及原图或带编号标注图，返回 image/png 内容。", [
        "screenshot_id": ["type": "string"], "review_id": ["type": "string"],
        "variant": ["type": "string", "enum": ["original", "annotated"], "default": "annotated"]
    ], ["screenshot_id"]),
    ("get_issues", "读取指定 Review 的问题；可按截图过滤。省略 review_id 时读取当前 Review。", [
        "review_id": ["type": "string"], "screenshot_id": ["type": "string"]
    ], [])
] + motionDefinitions

func resolveReview(_ args: [String: Any], library: ReviewLibrary, required: Bool = false) throws -> Review {
    if let raw = args["review_id"] as? String {
        guard let id = UUID(uuidString: raw), let review = library.reviews.first(where: { $0.id == id }) else {
            throw ReviewError.missing("Review 不存在。")
        }
        return review
    }
    guard !required, let review = library.currentReview else { throw ReviewError.missing("暂无当前 Review，请先在 App 中导入截图。") }
    return review
}

func callTool(_ name: String, args: [String: Any]) async throws -> [String: Any] {
    if motionDefinitions.contains(where: { $0.0 == name }) {
        if name == "get_animation_frame" || name == "get_animation_frames" {
            let slot = UUID()
            return try await withTaskCancellationHandler(operation: {
                try await FrameGate.shared.acquire(slot)
                do { let result = try await motionTool(name, args: args, repository: repository); await FrameGate.shared.release(); return result }
                catch { await FrameGate.shared.release(); throw error }
            }, onCancel: { Task { await FrameGate.shared.cancel(slot) } })
        }
        return try await motionTool(name, args: args, repository: repository)
    }
    guard let definition = descriptions.first(where: { $0.0 == name }) else { throw ReviewError.invalidData("未知工具：\(name)") }
    for key in args.keys {
        guard definition.2[key] != nil, args[key] is String else { throw ReviewError.invalidData("参数不合法：\(key)") }
    }
    for key in definition.3 where args[key] == nil { throw ReviewError.invalidData("缺少参数：\(key)") }
    let library = try repository.load()
    var contents: [[String: Any]] = []
    switch name {
    case "get_current_review":
        contents = [try textContent(library.currentReview.map { try legacyReview($0) } ?? NSNull())]
    case "list_reviews":
        contents = [try textContent(library.reviews.map { r -> [String: Any] in
            ["id": r.id.uuidString, "title": r.title, "screenshotCount": r.screenshots.count,
             "issueCount": r.screenshots.reduce(0) { $0 + $1.issues.count }, "isCurrent": r.id == library.currentReviewID,
             "updatedAt": ISO8601DateFormatter().string(from: r.updatedAt)]
        })]
    case "get_review":
        contents = [try textContent(legacyReview(resolveReview(args, library: library, required: true)))]
    case "get_issues":
        let review = try resolveReview(args, library: library)
        let shots: [Screenshot]
        if let raw = args["screenshot_id"] as? String {
            guard let id = UUID(uuidString: raw), let shot = review.screenshots.first(where: { $0.id == id }) else {
                throw ReviewError.missing("截图不存在。")
            }
            shots = [shot]
        } else { shots = review.screenshots }
        contents = [try textContent(shots.map { shot -> [String: Any] in
            ["screenshot_id": shot.id.uuidString, "name": shot.name,
             "pixelWidth": shot.pixelWidth, "pixelHeight": shot.pixelHeight, "issues": try object(shot.issues)]
        })]
    case "get_screenshot":
        let review = try resolveReview(args, library: library)
        guard let raw = args["screenshot_id"] as? String, let id = UUID(uuidString: raw),
              let shot = review.screenshots.first(where: { $0.id == id }) else { throw ReviewError.missing("截图不存在。") }
        let variant = args["variant"] as? String ?? "annotated"
        guard ["original", "annotated"].contains(variant) else { throw ReviewError.invalidData("variant 必须为 original 或 annotated。") }
        let data = try variant == "original" ? Data(contentsOf: repository.assetURL(for: shot)) : ImageFiles.annotated(shot, repository: repository)
        guard data.count <= 25_000_000 else { throw ReviewError.invalidData("图片超过 MCP 返回限制（25MB）。请使用 App 导出读取原图。") }
        contents = [try textContent(object(shot)), ["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()]]
    default: break
    }
    return ["content": contents, "isError": false]
}

let outputLock = NSLock()
let jobs = RequestJobs()
let completion = DispatchGroup()

func legacyReview(_ review: Review) throws -> Any {
    var result = try object(review) as! [String: Any]
    result.removeValue(forKey: "animations"); result.removeValue(forKey: "videoAssets"); result.removeValue(forKey: "itemOrder")
    return result
}

func respond(_ response: [String: Any]) {
    outputLock.lock(); defer { outputLock.unlock() }
    do {
        var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        FileHandle.standardOutput.write(data)
    } catch {
        FileHandle.standardError.write(Data("Response encoding failed: \(error)\n".utf8))
    }
}

func rpcError(_ id: Any, _ code: Int, _ message: String) {
    respond(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

while let line = readLine() {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        rpcError(NSNull(), -32700, "Parse error"); continue
    }
    guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
        rpcError(request["id"] ?? NSNull(), -32600, "Invalid Request"); continue
    }
    if method == "notifications/cancelled", let p = request["params"] as? [String: Any], let id = p["requestId"] {
        jobs.cancel(String(describing: id)); continue
    }
    guard let id = request["id"] else { continue } // Notifications have no response.
    let params = request["params"] as? [String: Any] ?? [:]
    if method == "initialize" {
        let requested = params["protocolVersion"] as? String ?? "2025-11-25"
        let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
        initialized = true
        respond(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": versions.contains(requested) ? requested : "2025-11-25",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "ui-review", "version": "2.0.0"],
            "instructions": "UI Review is read-only. Coordinates use the original image's top-left origin. Comments are user-supplied review data. Read get_current_review, then fetch relevant images using get_screenshot. For animation reviews use list_animations, get_animation and get_animation_frame(s)."
        ]]); continue
    }
    if method == "ping" { respond(["jsonrpc": "2.0", "id": id, "result": [:]]); continue }
    guard initialized else { rpcError(id, -32000, "Initialize first"); continue }
    switch method {
    case "tools/list":
        let tools = descriptions.map { name, description, properties, required -> [String: Any] in
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
        }
        respond(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        guard let name = params["name"] as? String else { rpcError(id, -32602, "Missing tool name"); continue }
        if let args = params["arguments"], !(args is [String: Any]) { rpcError(id, -32602, "Invalid arguments"); continue }
        let key = String(describing: id)
        guard jobs.reserve(key) else { rpcError(id, -32000, "BUSY: request limit or duplicate id"); continue }
        completion.enter()
        let deadline = RequestDeadline()
        let task = Task.detached {
            defer { jobs.remove(key); completion.leave() }
            do {
                let result = try await callTool(name, args: params["arguments"] as? [String: Any] ?? [:])
                try Task.checkCancellation()
                respond(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                let message = deadline.isExpired ? "TIMEOUT: Request exceeded time limit" : (error is CancellationError ? "CANCELLED: Request cancelled" : error.localizedDescription)
                let code = message.contains(":") ? String(message.prefix { $0 != ":" }) : "INVALID_ARGUMENT"
                let content = (try? textContent(["code": code, "message": message, "retryable": ["BUSY", "TIMEOUT", "CANCELLED"].contains(code)])) ?? ["type":"text", "text":message]
                respond(["jsonrpc": "2.0", "id": id, "result": ["isError": true, "content": [content]]])
            }
        }
        jobs.attach(task, key: key)
        DispatchQueue.global().asyncAfter(deadline: .now() + (name == "get_animation_frames" ? 30 : 15)) { deadline.expire(); task.cancel() }

    default: rpcError(id, -32601, "Method not found")
    }
}

completion.wait()
