// Spike 002 helper — pixel statistics + glyph bounding box for captured menu bar images.
// Usage: pxstats <image.png> [--white-threshold 0.75]
// Prints image size, mean luminance, and the bounding box of "glyph" pixels
// (near-white on a dark bar, near-black on a light bar — auto-detected).
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count > 1, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("usage: pxstats <image.png>"); exit(1)
}
var threshold = 0.72
if let i = args.firstIndex(of: "--white-threshold"), i + 1 < args.count, let t = Double(args[i + 1]) { threshold = t }

let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

func lum(_ x: Int, _ y: Int) -> Double {
    let o = (y * w + x) * 4
    return (0.2126 * Double(buf[o]) + 0.7152 * Double(buf[o+1]) + 0.0722 * Double(buf[o+2])) / 255.0
}

var sum = 0.0
for y in 0..<h { for x in 0..<w { sum += lum(x, y) } }
let mean = sum / Double(w * h)
let barsAreDark = mean < 0.5
let wantBright = barsAreDark   // glyph is white on a dark bar, black on a light bar

func isGlyph(_ x: Int, _ y: Int) -> Bool {
    let l = lum(x, y)
    return wantBright ? l > threshold : l < (1 - threshold)
}

var minX = w, minY = h, maxX = -1, maxY = -1, count = 0
for y in 0..<h {
    for x in 0..<w where isGlyph(x, y) {
        count += 1
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}

print("image            : \(w)x\(h) px")
print("mean luminance   : \(String(format: "%.4f", mean))  (\(barsAreDark ? "dark bar → glyph is light" : "light bar → glyph is dark"))")
print("glyph pixels     : \(count)")
if maxX >= 0 {
    print("glyph bbox       : x=\(minX) y=\(minY) w=\(maxX-minX+1) h=\(maxY-minY+1)")
    // column profile of glyph pixels — shows the fill boundary inside the pill
    var prof: [Int] = []
    for x in minX...maxX {
        var c = 0
        for y in minY...maxY where isGlyph(x, y) { c += 1 }
        prof.append(c)
    }
    let maxC = prof.max() ?? 1
    var art = ""
    for x in stride(from: 0, to: prof.count, by: max(1, prof.count / 60)) {
        let v = Double(prof[x]) / Double(maxC)
        art += v > 0.75 ? "#" : (v > 0.4 ? "+" : (v > 0.1 ? "." : " "))
    }
    print("column profile   : |\(art)|")
} else {
    print("glyph bbox       : none found (raise/lower --white-threshold)")
}
