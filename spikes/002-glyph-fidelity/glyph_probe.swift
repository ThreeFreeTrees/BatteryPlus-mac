// glyph_probe — measures a menu bar battery glyph precisely from a 2x capture.
// Usage: glyph_probe <image.png> [--threshold 0.72]
//
// Prints:
//   * glyph bounding box in pixels and points
//   * a scanline map of the middle rows (P = bright/outline+fill, g = dim/empty portion, . = background)
//   * edge profiles: first/last glyph column per row (corner radius + stroke width evidence)
//   * fill boundary: where the bright fill ends and the dim remainder begins
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count > 1, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("usage: glyph_probe <image.png>"); exit(1)
}
var threshold = 0.72
if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let t = Double(args[i + 1]) { threshold = t }

let width = image.width, height = image.height
var buffer = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func luminance(_ x: Int, _ y: Int) -> Double {
    let o = (y * width + x) * 4
    return (0.2126 * Double(buffer[o]) + 0.7152 * Double(buffer[o+1]) + 0.0722 * Double(buffer[o+2])) / 255.0
}

// Classify: bright (outline/fill), dim (the "empty" part of the pill), background.
var luminanceValues: [Double] = []
for y in 0..<height { for x in 0..<width { luminanceValues.append(luminance(x, y)) } }
let mean = luminanceValues.reduce(0, +) / Double(luminanceValues.count)
let brightMode = mean < 0.5
let brightCut = brightMode ? threshold : (1 - threshold)
let dimCut = brightMode ? threshold * 0.45 : 1 - threshold * 0.45

func classify(_ x: Int, _ y: Int) -> Character {
    let l = luminance(x, y)
    if brightMode {
        if l >= brightCut { return "P" }
        if l >= dimCut { return "g" }
        return "."
    } else {
        if l <= brightCut { return "P" }
        if l <= dimCut { return "g" }
        return "."
    }
}

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where classify(x, y) == "P" {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}

print("image            : \(width)x\(height) px (\(Double(width)/2)x\(Double(height)/2) pt @2x)")
print("mean luminance   : \(String(format: "%.4f", mean)) → \(brightMode ? "dark bar, glyph is bright" : "light bar, glyph is dark")")
if maxX < 0 {
    print("glyph bbox       : none found with threshold \(threshold) (polarity auto-detect may be inverted for a glyph-dominated crop; raw profiles below)")
}
print(String(format: "glyph bbox       : x=%d y=%d  %dx%d px  =  %.1fx%.1f pt",
             minX, minY, maxX - minX + 1, maxY - minY + 1,
             Double(maxX - minX + 1) / 2, Double(maxY - minY + 1) / 2))

// Raw luminance profiles — printed before any classification so they are always available.
if let i = args.firstIndex(of: "--row"), i + 1 < args.count, let row = Int(args[i + 1]), row < height {
    var line = "row \(row) lum   : "
    for x in 0..<width { line += String(format: "%d:%.2f ", x, luminance(x, row)) }
    print(line)
}
if let i = args.firstIndex(of: "--col"), i + 1 < args.count, let col = Int(args[i + 1]), col < width {
    var line = "col \(col) lum   : "
    for y in 0..<height { line += String(format: "%d:%.2f ", y, luminance(col, y)) }
    print(line)
}
if maxX < 0 { exit(0) }

// Scanline map: sample the middle 7 rows, printing every column of the glyph box.
let midY = (minY + maxY) / 2
print("scanline map     : (P=bright fill/outline, g=dim remainder, .=background)")
for y in stride(from: max(minY, midY - 3), through: min(maxY, midY + 3), by: 1) {
    var line = ""
    for x in minX...maxX { line.append(classify(x, y)) }
    print(String(format: "  y=%3d %@", y, line))
}

// Fill boundary on the centre row: last bright run's end (before the dim remainder).
var lastBright = minX
for x in minX...maxX where classify(x, midY) == "P" { lastBright = x }
// Account for the outline stroke: find the last bright column that belongs to the fill
// (contiguous with the left edge) rather than the right-hand outline.
var fillEnd = minX
for x in (minX + 1)...maxX {
    if classify(x, midY) == "P" { fillEnd = x } else if x > minX + 4 { break }
}
let interior = maxX - minX + 1 - 4   // subtract ~2px outline each side
let fillPercent = Double(fillEnd - minX + 1) / Double(interior) * 100
print(String(format: "fill boundary    : last bright @ x=%d  → fill ≈ %.0f%% of interior width", fillEnd, fillPercent))

// Edge profile: first and last glyph column per row → corner radius, stroke width.
print("edge profile     : row: firstGlyphCol..lastGlyphCol (width)")
for y in stride(from: minY, through: min(maxY, minY + 14), by: 1) {
    var first = -1, last = -1
    for x in minX...maxX where classify(x, y) != "." {
        if first < 0 { first = x }
        last = x
    }
    if first >= 0 { print("  y=\(y): \(first)..\(last) (\(last - first + 1) px)") }
}

// Raw luminance profiles — for reading stroke widths and the nub geometry directly.
if let i = args.firstIndex(of: "--row"), i + 1 < args.count, let row = Int(args[i + 1]), row < height {
    var line = "row \(row) lum   : "
    for x in 0..<width { line += String(format: "%d:%.2f ", x, luminance(x, row)) }
    print(line)
}
if let i = args.firstIndex(of: "--col"), i + 1 < args.count, let col = Int(args[i + 1]), col < width {
    var line = "col \(col) lum   : "
    for y in 0..<height { line += String(format: "%d:%.2f ", y, luminance(col, y)) }
    print(line)
}
