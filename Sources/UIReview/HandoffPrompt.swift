import Foundation
import ReviewCore
import ReviewMedia

enum HandoffScope {
    case currentItem
    case wholeReview
}

enum HandoffPrompt {
    static func isEnabled(_ review: Review?) -> Bool {
        guard let review else { return false }
        return !review.screenshots.isEmpty || !review.animations.isEmpty
    }

    static func projected(_ review: Review, itemID: UUID?, scope: HandoffScope) -> Review {
        var selected: Review
        switch scope {
        case .wholeReview: selected = review
        case .currentItem: selected = MotionExport.selected(review, itemID: itemID)
        }
        selected.pruneUnusedVideoAssets()
        return selected
    }

    static func pendingCount(_ review: Review) -> Int {
        review.screenshots.flatMap(\.issues).filter {
            $0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
            + review.animations.flatMap(\.issues).filter {
                $0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
    }

    static func text(review: Review, revision: UUID, scope: HandoffScope) -> String {
        let shots = review.screenshots.map { $0.id.uuidString }.joined(separator: ", ")
        let ids = review.animations.map { $0.id.uuidString }.joined(separator: ", ")
        let range = scope == .wholeReview ? "整个 Review" : "当前素材"
        return "请立刻修复 ui-review MCP 中 Review \(review.id.uuidString) 记录的问题，并直接修改当前项目代码。范围：\(range)；截图 ID：[\(shots)]；动画 ID：[\(ids)]。已保存 revision：\(revision.uuidString)。先读取证据再改：截图用 get_review/get_screenshot；动画用 get_animation（expected_revision 为上述 revision）、get_animation_frame/get_animation_frames 获取原帧、区域图和参考证据。按每条原始评论逐项修改，不要只总结或等待确认。\(pendingCount(review)) 项描述待填写，这些先跳过。缺失证据或 revision 变化的条目说明原因后继续处理其余问题，不猜测动画参数。"
    }

    static func copyStatus(for scope: HandoffScope) -> String {
        switch scope {
        case .currentItem: return "已复制当前素材交接提示词"
        case .wholeReview: return "已复制整个 Review 交接提示词"
        }
    }

    static func exportWarning(byteLength: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: byteLength, countStyle: .file)
        return "将导出完整录屏，约 \(size)，另加图片与证据文件"
    }

    static func needsVideoExportConfirmation(_ review: Review) -> Bool {
        !review.animations.isEmpty
    }
}
