import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum ImageFiles {
    public struct Decoded {
        public let image: CGImage
        public let png: Data
        public var width: Int { image.width }
        public var height: Int { image.height }
    }

    public static func decode(_ data: Data) throws -> Decoded {
        guard data.count <= 100_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000 else {
            throw ReviewError.invalidData("无法读取图片，或图片超过 100MB / 4000 万像素。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReviewError.invalidData("无法解码图片。")
        }
        return Decoded(image: image, png: try png(image))
    }

    public static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReviewError.missing("截图文件无法读取：\(url.lastPathComponent)")
        }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ReviewError.invalidData("无法创建 PNG。")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw ReviewError.invalidData("PNG 编码失败。") }
        return data as Data
    }

    /// Regions use a top-left origin in original image pixels. The CGContext is
    /// bottom-left based; only coordinates are converted, never screenshot pixels.
    public static func annotated(_ screenshot: Screenshot, repository: ReviewRepository) throws -> Data {
        let image = try load(repository.assetURL(for: screenshot))
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReviewError.invalidData("无法创建标注画布。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let lineWidth = max(2.0, Double(w) / 450)
        let diameter = max(22.0, Double(w) / 32)
        let blue = CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
        for (index, issue) in screenshot.issues.enumerated() {
            let r = issue.region
            let rect = CGRect(x: r.x, y: Double(h) - r.y - r.height, width: r.width, height: r.height)
            context.setStrokeColor(blue); context.setLineWidth(lineWidth)
            context.stroke(rect)
            let badge = CGRect(x: min(max(0, r.x), Double(w) - diameter),
                               y: min(Double(h) - diameter, rect.maxY), width: diameter, height: diameter)
            context.setFillColor(blue); context.fillEllipse(in: badge)
            let string = NSAttributedString(string: "\(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, diameter * 0.6, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            let line = CTLineCreateWithAttributedString(string)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: badge.midX - bounds.midX, y: badge.midY - bounds.midY)
            CTLineDraw(line, context)
        }
        guard let output = context.makeImage() else { throw ReviewError.invalidData("标注图生成失败。") }
        return try png(output)
    }
}
