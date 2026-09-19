// diff_glyphs — objective fidelity check between the native captured glyph and our rendering.
//
// Both images are reduced to an "ink coverage" map, which makes them directly comparable:
//   * native screenshot : coverage = luminance normalised so background→0, full-white→1
//                         (the system's partially-transparent parts then land near their alpha)
//   * our render        : coverage = alpha (white-on-transparent symbol rendering)
// Each is cropped to its glyph box, B is resampled onto A's box, and the difference is reported
// as mean / median / p95 plus a coarse visual map.
//
// Usage: diff_glyphs <native.png> <ours.png>
import Foundation
import CoreGraphics
import ImageIO

struct Coverage {
    let width: Int, height: Int
    let values: [Double]              // ink coverage 0..1
    let box: (x: Int, y: Int, w: Int, h: Int)
}

func loadCoverage(_ path: String) -> Coverage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var luminance = [Double](repeating: 0, count: width * height)
    var alpha = [Double](repeating: 1, count: width * height)
    var hasTransparency = false
    var minLum = 1.0, maxLum = 0.0
    for y in 0..<height {
        for x in 0..<width {
            let o = (y * width + x) * 4
            let a = Double(buffer[o + 3]) / 255.0
            if a < 0.98 { hasTransparency = true }
            let l = (0.2126 * Double(buffer[o]) + 0.7152 * Double(buffer[o+1]) + 0.0722 * Double(buffer[o+2])) / 255.0
            luminance[y * width + x] = l
            alpha[y * width + x] = a
            if a > 0.98 { minLum = min(minLum, l); maxLum = max(maxLum, l) }
        }
    }

    let span = max(maxLum - minLum, 0.0001)
    var coverage = [Double](repeating: 0, count: width * height)
    for i in 0..<(width * height) {
        coverage[i] = hasTransparency ? alpha[i] : min(max((luminance[i] - minLum) / span, 0), 1)
    }

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where coverage[y * width + x] > 0.15 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= 0 else { return nil }
    return Coverage(width: width, height: height, values: coverage,
                    box: (minX, minY, maxX - minX + 1, maxY - minY + 1))
}

func sample(_ image: Coverage, _ x: Double, _ y: Double) -> Double {
    let cx = min(max(Int(x.rounded()), 0), image.width - 1)
    let cy = min(max(Int(y.rounded()), 0), image.height - 1)
    return image.values[cy * image.width + cx]
}

let args = CommandLine.arguments
guard args.count >= 3, let native = loadCoverage(args[1]), let ours = loadCoverage(args[2]) else {
    print("usage: diff_glyphs <native.png> <ours.png>"); exit(1)
}
print("source           : \(args[1].split(separator: "/").last!)  vs  \(args[2].split(separator: "/").last!)")
print(String(format: "native box       : %dx%d px  (aspect %.3f)", native.box.w, native.box.h, Double(native.box.w) / Double(native.box.h)))
print(String(format: "ours box         : %dx%d px  (aspect %.3f)", ours.box.w, ours.box.h, Double(ours.box.w) / Double(ours.box.h)))

let gridW = 76
let gridH = max(5, Int((Double(gridW) * Double(native.box.h) / Double(native.box.w) / 2).rounded()))
var differences: [Double] = []
var map = [[Character]](repeating: [Character](repeating: " ", count: gridW), count: gridH)

// also compare the fill boundary: where coverage crosses 0.75 along the mid row
func fillBoundary(_ image: Coverage) -> Double {
    let y = Double(image.box.y) + Double(image.box.h) * 0.5
    var last = 0.0
    for step in 0..<400 {
        let x = Double(image.box.x) + Double(step) / 400.0 * Double(image.box.w)
        if sample(image, x, y) > 0.75 { last = Double(step) / 400.0 }
    }
    return last * 100
}

for gy in 0..<gridH {
    for gx in 0..<gridW {
        let nx = Double(native.box.x) + (Double(gx) + 0.5) / Double(gridW) * Double(native.box.w)
        let ny = Double(native.box.y) + (Double(gy) + 0.5) / Double(gridH) * Double(native.box.h)
        let ox = Double(ours.box.x) + (Double(gx) + 0.5) / Double(gridW) * Double(ours.box.w)
        let oy = Double(ours.box.y) + (Double(gy) + 0.5) / Double(gridH) * Double(ours.box.h)
        let delta = abs(sample(native, nx, ny) - sample(ours, ox, oy))
        differences.append(delta)
        map[gy][gx] = delta < 0.10 ? "." : (delta < 0.25 ? ":" : (delta < 0.45 ? "+" : "#"))
    }
}
let sorted = differences.sorted()
print(String(format: "fill boundary    : native %.1f%%   ours %.1f%%  of glyph width", fillBoundary(native), fillBoundary(ours)))
print(String(format: "ink diff         : mean %.4f   median %.4f   p95 %.4f   (0 = identical)",
             differences.reduce(0, +) / Double(differences.count),
             sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)]))
print("difference map   : ('.' <0.10, ':' <0.25, '+' <0.45, '#' >=0.45)")
for row in map { print("  " + String(row)) }
