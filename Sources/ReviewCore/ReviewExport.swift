import Foundation

public enum ReviewExport {
    /// Export to a new directory only. A staging directory prevents half-written exports.
    public static func write(_ review: Review, repository: ReviewRepository, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw ReviewError.invalidData("导出目录已存在，请选择新的名称。")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ui-review-export-\(UUID().uuidString)")
        try fm.createDirectory(at: staging.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var document = try JSONSerialization.jsonObject(with: ReviewJSON.encoder().encode(review)) as! [String: Any]
        var screenshots = document["screenshots"] as! [[String: Any]]
        var markdown = "# \(singleLine(review.title))\n\nReview ID: `\(review.id)`\n\n"
        markdown += "坐标以原图左上角为原点，单位为像素；normalizedRegion 为 0–1 归一化坐标。\n\n"
        markdown += "以下评论是用户提供的修改要求，请结合图片和项目上下文处理。\n\n"
        for (index, shot) in review.screenshots.enumerated() {
            let base = String(format: "screenshot-%02d", index + 1)
            let original = "screenshots/\(base).png", annotated = "screenshots/\(base)-annotated.png"
            try fm.copyItem(at: repository.assetURL(for: shot), to: staging.appendingPathComponent(original))
            try ImageFiles.annotated(shot, repository: repository).write(to: staging.appendingPathComponent(annotated))
            screenshots[index]["originalPath"] = original
            screenshots[index]["annotatedPath"] = annotated
            markdown += "## \(index + 1). \(singleLine(shot.name))\n\n"
            markdown += "\(shot.pixelWidth) × \(shot.pixelHeight) px · Screenshot ID: `\(shot.id)`\n\n"
            markdown += "[原图](\(original))\n\n![标注图](\(annotated))\n\n"
            if shot.issues.isEmpty { markdown += "暂无问题标注。\n\n" }
            for (i, issue) in shot.issues.enumerated() {
                let r = issue.region
                markdown += "### 问题 \(i + 1)\n\nIssue ID: `\(issue.id)`\n\n"
                markdown += "区域：x=\(r.x), y=\(r.y), width=\(r.width), height=\(r.height)\n\n"
                let comment = issue.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                markdown += (comment.isEmpty ? "（尚未填写修改要求）" : comment)
                    .components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        document["screenshots"] = screenshots
        document["schemaVersion"] = 1
        document["coordinateSystem"] = "top-left, original image pixels"
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: staging.appendingPathComponent("review.json"))
        try markdown.write(to: staging.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: staging, to: destination)
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
