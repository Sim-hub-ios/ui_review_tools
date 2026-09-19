import Foundation

public struct Region: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func clamped(toWidth w: Double, height h: Double) -> Region {
        let left = min(max(0, x), w)
        let top = min(max(0, y), h)
        return Region(x: left, y: top, width: max(0, min(width, w - left)),
                      height: max(0, min(height, h - top)))
    }

    public func normalized(width: Int, height: Int) -> Region {
        guard width > 0, height > 0 else { return Region(x: 0, y: 0, width: 0, height: 0) }
        return Region(x: x / Double(width), y: y / Double(height),
                      width: self.width / Double(width), height: self.height / Double(height))
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
    }
}

public struct Issue: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var region: Region
    public var normalizedRegion: Region
    public var comment: String

    public init(id: UUID = UUID(), region: Region, comment: String = "", imageWidth: Int, imageHeight: Int) {
        self.id = id; self.region = region; self.comment = comment
        self.normalizedRegion = region.normalized(width: imageWidth, height: imageHeight)
    }
}

public struct Screenshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let originalPath: String
    public var issues: [Issue]

    public init(id: UUID = UUID(), name: String, pixelWidth: Int, pixelHeight: Int,
                originalPath: String, createdAt: Date = Date(), issues: [Issue] = []) {
        self.id = id; self.name = name; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.originalPath = originalPath; self.createdAt = createdAt; self.issues = issues
    }
}

public struct Review: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var screenshots: [Screenshot]
    public var animations: [Animation] = []
    public var videoAssets: [VideoAsset] = []
    public var itemOrder: [ReviewItem] = []

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), screenshots: [Screenshot] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = createdAt; self.screenshots = screenshots
        self.itemOrder = screenshots.map { ReviewItem(kind: .screenshot, id: $0.id) }
    }

    public var issueCount: Int { screenshots.reduce(0) { $0 + $1.issues.count } + animations.reduce(0) { $0 + $1.issues.count } }
    public var referencedVideoAssetIDs: Set<UUID> {
        Set(animations.flatMap {
            [$0.currentAssetID] + [$0.activeReference?.referenceAssetID].compactMap { $0 }
                + $0.issues.compactMap { $0.referenceSnapshot?.referenceAssetID }
        })
    }
    public mutating func pruneUnusedVideoAssets(keeping extra: UUID? = nil) {
        var ids = referencedVideoAssetIDs
        if let extra { ids.insert(extra) }
        videoAssets.removeAll { !ids.contains($0.id) }
    }
    public mutating func reconcileOrder() {
        let items = screenshots.map { ReviewItem(kind: .screenshot, id: $0.id) } + animations.map { ReviewItem(kind: .animation, id: $0.id) }
        itemOrder = itemOrder.filter { items.contains($0) }
        for item in items where !itemOrder.contains(item) { itemOrder.append(item) }
    }
    enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, screenshots, animations, videoAssets, itemOrder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        screenshots = try c.decode([Screenshot].self, forKey: .screenshots)
        animations = try c.decodeIfPresent([Animation].self, forKey: .animations) ?? []
        videoAssets = try c.decodeIfPresent([VideoAsset].self, forKey: .videoAssets) ?? []
        itemOrder = try c.decodeIfPresent([ReviewItem].self, forKey: .itemOrder) ?? screenshots.map { ReviewItem(kind: .screenshot, id: $0.id) }
    }
}

public struct ReviewLibrary: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var revision = UUID()
    public var currentReviewID: UUID?
    public var reviews: [Review]

    public init(currentReviewID: UUID? = nil, reviews: [Review] = []) {
        self.currentReviewID = currentReviewID; self.reviews = reviews
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, revision, currentReviewID, reviews }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard (1...2).contains(schemaVersion) else { throw ReviewError.invalidData("数据版本不受支持，请升级 UI Review。") }
        revision = schemaVersion == 2 ? try c.decode(UUID.self, forKey: .revision) : UUID()
        currentReviewID = try c.decodeIfPresent(UUID.self, forKey: .currentReviewID)
        reviews = try c.decode([Review].self, forKey: .reviews)
        if schemaVersion == 2 { _ = try c.decode([RequiredV2Fields].self, forKey: .reviews) }
    }
    public var currentReview: Review? { reviews.first { $0.id == currentReviewID } }
}

public enum ReviewError: LocalizedError {
    case invalidData(String)
    case missing(String)
    public var errorDescription: String? {
        switch self {
        case .invalidData(let text), .missing(let text): return text
        }
    }
}

public enum ReviewJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

private struct RequiredV2Fields: Decodable {
    let animations: [Animation]
    let videoAssets: [VideoAsset]
    let itemOrder: [ReviewItem]
}
