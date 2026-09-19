// render_candidates — renders battery.100percent as a VARIABLE symbol at a given fill level
// across point sizes/weights, and reports each rendering's pixel bounding box at 2x,
// so we can pick the size that matches the native glyph (measured: 25.5 x 12.0 pt at 62%).
//
// Usage: render_candidates <fill 0..1> [outdir]
import AppKit

let fill = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 0.62) : 0.62
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/battery_candidates"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func boundingBox(of image: NSImage, scale: CGFloat = 2) -> (Int, Int, Int, Int, Int, Int)? {
    let width = Int(ceil(image.size.width * scale))
    let height = Int(ceil(image.size.height * scale))
    guard width > 0, height > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    NSGraphicsContext.restoreGraphicsState()

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where buffer[(y * width + x) * 4 + 3] > 24 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= 0 else { return nil }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1, width, height)
}

print("native target    : 25.5 x 12.0 pt  (51 x 24 px at 2x), fill 61-62%, nub 1.5pt wide, gap 1.0pt")
print("symbol           : battery.100percent, variableValue=\(fill)")
print("")
print("pointSize weight    bbox px        bbox pt        Δwidth  Δheight")
var best: (String, Double, Int, Int)?
for pointSize in stride(from: 20.0, through: 44.0, by: 1.0) {
    for (weightName, weight) in [("regular", NSFont.Weight.regular), ("medium", .medium), ("semibold", .semibold)] {
        guard let base = NSImage(systemSymbolName: "battery.100percent", variableValue: fill,
                                 accessibilityDescription: nil),
              let configured = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)),
              let box = boundingBox(of: configured) else { continue }
        let widthPoints = Double(box.2) / 2, heightPoints = Double(box.3) / 2
        let deltaWidth = abs(widthPoints - 25.5), deltaHeight = abs(heightPoints - 12.0)
        print(String(format: "%5.1f     %-10@ %2dx%-2d px     %5.1fx%.1f pt    %+5.1f   %+5.1f",
                     pointSize, weightName as NSString, box.2, box.3, widthPoints, heightPoints, deltaWidth, deltaHeight))
        let score = deltaWidth + deltaHeight
        if best == nil || score < best!.1 {
            best = (String(format: "%.1f %@", pointSize, weightName), score, box.2, box.3)
            // save the winner for pixel comparison
            if let tiff = configured.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outDir + "/candidate_best.png"))
            }
        }
    }
}
if let best { print("\nbest match       : pointSize/weight = \(best.0)  (bbox \(best.2)x\(best.3) px, score \(String(format: "%.1f", best.1)))") }
