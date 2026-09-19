// bolt_outline — measures the native charging bolt's silhouette from a capture, row by row.
//
// The bolt body is white, like the charged part of the pill, so it cannot be segmented by
// brightness alone. What *is* detectable is the transparent knockout ring around it: dark pixels
// inside the pill. Those give the bolt's left and right boundary per row, which is exactly what a
// polygon needs.
//
// Usage: bolt_outline <native_charging.png>
import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count > 1,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: bolt_outline <image.png>"); exit(1)
}

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

// pill box: pixels that are clearly not background (the pill is at ~0.61 or ~0.96, background ~0.29)
var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width where luminance(x, y) > 0.5 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
print("bolt/pill box    : x=\(minX)..\(maxX)  y=\(minY)..\(maxY)  (\(maxX-minX+1)x\(maxY-minY+1) px)")

// The bolt overflows the pill, so the box above is the bolt's. The pill is the band of rows whose
// middle is covered by pill material; only those rows can be scanned without hitting the background
// outside the pill.
var pillMinY = -1, pillMaxY = -1
for y in minY...maxY {
    var covered = 0, total = 0
    for x in (minX + 4)...(maxX - 4) {
        total += 1
        let value = luminance(x, y)
        if value > 0.5 { covered += 1 }
    }
    if total > 0, Double(covered) / Double(total) > 0.85 {
        if pillMinY < 0 { pillMinY = y }
        pillMaxY = y
    }
}
print("pill rows        : y=\(pillMinY)..\(pillMaxY)  (\(pillMaxY - pillMinY + 1) px tall)")
print("bolt edges inside the pill (dark knockout ring), per row:")
print("  y   y-frac  left..right px     left..right frac of bolt box width")
let scanLeft = minX + 4, scanRight = maxX - 4
for y in pillMinY...pillMaxY {
    var first = -1, last = -1
    for x in scanLeft...scanRight where luminance(x, y) < 0.5 {
        if first < 0 { first = x }
        last = x
    }
    guard first >= 0 else { continue }
    let yFraction = Double(y - minY) / Double(maxY - minY)
    let leftFraction = Double(first - minX) / Double(maxX - minX)
    let rightFraction = Double(last - minX) / Double(maxX - minX)
    print(String(format: "  %3d  %.2f    %3d..%-3d          %.3f .. %.3f",
                 y, yFraction, first, last, leftFraction, rightFraction))
}
