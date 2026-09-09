// Standalone T0 experiment; does not read or mutate the UI Review library.
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics

func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "MotionProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}
func savePNG(_ image: CGImage, to url: URL) throws {
    let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    try require(CGImageDestinationFinalize(output), "PNG export failed")
}

@main struct Probe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let names = ["cfr30", "vfr", "rotated90", "benchmark60"]
        var results: [[String: Any]] = []
        for name in names {
            let asset = AVURLAsset(url: root.appendingPathComponent(name + ".mp4"))
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            if name == "rotated90" {
                try require(abs(transform.b) > 0.9 && abs(transform.c) > 0.9,
                            "Rotation fixture has no 90-degree track transform")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            try require(reader.startReading(), "Reader start failed: \(String(describing: reader.error))")
            var decodePTS: [CMTime] = []
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMSampleBufferGetImageBuffer(sample) != nil && time.isNumeric {
                    decodePTS.append(time)
                }
            }
            try require(reader.status == .completed, "Reader did not complete")
            let pts = decodePTS.sorted { CMTimeCompare($0, $1) < 0 }
            let referenceData = try Data(contentsOf: root.appendingPathComponent(name + ".pts.json"))
            let referenceJSON = try JSONSerialization.jsonObject(with: referenceData) as! [String: Any]
            let frames = referenceJSON["frames"] as! [[String: Any]]
            let expectedPTS = frames.compactMap { ($0["best_effort_timestamp_time"] as? String).flatMap(Double.init) }.sorted()
            try require(pts.count == expectedPTS.count, "PTS sample count differs: \(name), AVFoundation=\(pts.count), ffprobe=\(expectedPTS.count), AV first=\(pts.prefix(4).map(\.seconds)), last=\(pts.suffix(4).map(\.seconds))")
            let indexError = zip(pts, expectedPTS).map { abs($0.seconds - $1) }.max() ?? 0
            try require(indexError < 0.000002, "PTS differs from independent ffprobe index")
            let reordered = zip(decodePTS, decodePTS.dropFirst()).contains { CMTimeCompare($0, $1) > 0 }
            var durations = Set<Int>()
            for j in 1..<pts.count { durations.insert(Int(((pts[j].seconds - pts[j-1].seconds) * 1_000_000).rounded())) }
            try require(name != "vfr" || durations.count > 1, "VFR fixture is not variable frame rate")
            var times: [Double] = [], maxError = 0.0
            let samples = min(30, pts.count)
            for j in 0..<samples {
                // Fresh asset/generator per request; filesystem caches are not flushed.
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: root.appendingPathComponent(name + ".mp4")))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let requested = pts[j * (pts.count - 1) / (samples - 1)]
                let start = DispatchTime.now().uptimeNanoseconds
                let frame = try await generator.image(at: requested)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                maxError = max(maxError, abs(frame.actualTime.seconds - requested.seconds))
                if j == 0 {
                    try savePNG(frame.image, to: root.appendingPathComponent(name + ".av.png"))
                }
            }
            try require(maxError < 0.000001, "Exact frame request mismatch")
            let actualSource = CGImageSourceCreateWithURL(root.appendingPathComponent(name + ".av.png") as CFURL, nil)!
            let referenceSource = CGImageSourceCreateWithURL(root.appendingPathComponent(name + ".reference.png") as CFURL, nil)!
            let actual = CGImageSourceCreateImageAtIndex(actualSource, 0, nil)!
            let reference = CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)!
            try require(actual.width == reference.width && actual.height == reference.height, "Display dimensions differ")
            let a = rgba(actual), b = rgba(reference)
            var differences: [Int] = [], actualCorners: [[Int]] = [], referenceCorners: [[Int]] = []
            // Independent ffmpeg autorotation oracle, sampled well inside asymmetric corner patches.
            for fy in [0.04, 0.96] {
                for fx in [0.04, 0.96] {
                    let offset = (Int(Double(actual.height) * fy) * actual.width + Int(Double(actual.width) * fx)) * 4
                    actualCorners.append((0..<3).map { Int(a[offset+$0]) })
                    referenceCorners.append((0..<3).map { Int(b[offset+$0]) })
                    for channel in 0..<3 { differences.append(abs(Int(a[offset+channel]) - Int(b[offset+channel]))) }
                }
            }
            let maxPixelDifference = differences.max() ?? 0
            // Color management differs between the decoders. Check marker identity,
            // not numerical RGB equality; this is an orientation test, not a color-fidelity test.
            func marker(_ rgb: [Int]) -> String {
                let high = rgb.max()!
                return rgb.map { $0 > max(80, high / 2) ? "1" : "0" }.joined()
            }
            try require(actualCorners.map(marker) == referenceCorners.map(marker),
                        "Corner marker identities differ: \(name), actual=\(actualCorners), reference=\(referenceCorners)")
            // Validate the proposed letterbox-to-source mapping with an asymmetric rectangle.
            let w = Double(actual.width), h = Double(actual.height)
            let scale = min(688 / w, 420 / h), ox = (688 - w*scale)/2, oy = (420-h*scale)/2
            let rect = CGRect(x: w*0.13, y: h*0.21, width: w*0.52, height: h*0.37)
            let screenX = ox + rect.minX*scale, screenY = oy + rect.minY*scale
            let roundTripError = max(abs((screenX-ox)/scale-rect.minX), abs((screenY-oy)/scale-rect.minY))
            try require(roundTripError < 1e-8, "Coordinate round trip mismatch")
            times.sort()
            results.append([
                "fixture": name, "sampleCount": pts.count, "decodeOrderReordered": reordered,
                "frameIntervalsMicroseconds": durations.sorted(), "indexMaxErrorSeconds": indexError,
                "exactRequests": samples, "exactMaxErrorSeconds": maxError,
                "freshGeneratorP95Milliseconds": times[Int(ceil(Double(times.count)*0.95))-1],
                "freshGeneratorMaxMilliseconds": times.last!,
                "encodedSize": [Int(size.width), Int(size.height)], "displaySize": [actual.width, actual.height],
                "transform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
                "cornerPixelMaxDifference": maxPixelDifference, "coordinateRoundTripErrorPixels": roundTripError,
                "actualCornersRGB": actualCorners, "referenceCornersRGB": referenceCorners,
                "status": "pass"
            ])
            print("PASS \(name): \(pts.count) samples, \(samples) exact frame requests")
        }
        let document: [String: Any] = ["scope": "synthetic media T0, no live player or production UI", "results": results]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"))
    }
}
