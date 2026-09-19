// find_glyphs — locates each glyph segment in a menu bar strip and reports its bounding box,
// so two icons in the same image can be compared like for like (same capture, same scale).
//
// Usage: find_glyphs <strip.png> [--threshold 0.45]
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count > 1,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: find_glyphs <image.png>"); exit(1)
}
var threshold = 0.45
if let index = args.firstIndex(of: "--threshold"), index + 1 < args.count,
   let parsed = Double(args[index + 1]) { threshold = parsed }

let width = image.width, height = image.height
var buffer = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func luminance(_ x: Int, _ y: Int) -> Double {
    let offset = (y * width + x) * 4
    return (0.2126 * Double(buffer[offset]) + 0.7152 * Double(buffer[offset+1])
            + 0.0722 * Double(buffer[offset+2])) / 255.0
}

// columns containing glyph material (bright parts of the icon, including the dim remainder)
var columns = [Bool](repeating: false, count: width)
for x in 0..<width {
    for y in 0..<height where luminance(x, y) > threshold { columns[x] = true; break }
}

print("image            : \(width)x\(height) px, threshold \(threshold)")
var segments: [(Int, Int)] = []
var start = -1
var gap = 0
for x in 0..<width {
    if columns[x] {
        if start < 0 { start = x }
        gap = 0
    } else if start >= 0 {
        gap += 1
        if gap > 6 {   // icons are separated by more than a few pixels
            segments.append((start, x - gap))
            start = -1
            gap = 0
        }
    }
}
if start >= 0 { segments.append((start, min(width - 1, width - 1))) }

print("glyph segments   : \(segments.count)")
for (index, segment) in segments.enumerated() {
    var minY = height, maxY = -1
    for x in segment.0...segment.1 {
        for y in 0..<height where luminance(x, y) > threshold {
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    let segmentWidth = segment.1 - segment.0 + 1
    let segmentHeight = maxY - minY + 1
    print(String(format: "  #%d  x=%3d..%-3d  y=%2d..%-2d   %3d x %-3d px   aspect %.3f",
                 index + 1, segment.0, segment.1, minY, maxY,
                 segmentWidth, segmentHeight, Double(segmentWidth) / Double(segmentHeight)))
}
