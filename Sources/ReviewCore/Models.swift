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

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), screenshots: [Screenshot] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = createdAt; self.screenshots = screenshots
    }

    public var issueCount: Int { screenshots.reduce(0) { $0 + $1.issues.count } }
}

public struct ReviewLibrary: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var currentReviewID: UUID?
    public var reviews: [Review]

    public init(currentReviewID: UUID? = nil, reviews: [Review] = []) {
        self.currentReviewID = currentReviewID; self.reviews = reviews
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
