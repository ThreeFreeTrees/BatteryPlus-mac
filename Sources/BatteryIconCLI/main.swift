// batteryicon-dump — renders the glyph to a PNG so it can be pixel-diffed against a native
// capture. Used by the calibration sweeps in spikes/002-glyph-fidelity.
//
//   build/batteryicon <fraction> <out.png> [--charging] [--radius R] [--nubw W] [--nubh H]
//                                           [--gap G] [--empty A] [--bodyw W] [--nubr R]
import AppKit

// AppKit needs an application instance for some rendering paths (symbol images in particular);
// without it the charging bolt silently rasterised blank.
_ = NSApplication.shared

/// Reports how much of a symbol actually rasterises — the check that would have caught the
/// blank-bolt bug immediately instead of via an unexplained diff.
func symbolCoverage(_ name: String, pointSize: CGFloat = 96) -> String {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) else {
        return "\(name): unavailable"
    }
    let size = configured.size
    let width = max(2, Int(ceil(size.width * 2))), height = max(2, Int(ceil(size.height * 2)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return "\(name): no context"
    }
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    configured.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(), let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return "\(name): no bitmap" }
    let length = CFDataGetLength(data)
    var opaque = 0
    for index in stride(from: 3, to: length, by: 4) where bytes[index] > 128 { opaque += 1 }
    return String(format: "%@: %.1fx%.1f pt, %d opaque px of %d", name, size.width, size.height,
                  opaque, width * height)
}

func value(_ flag: String, _ fallback: CGFloat) -> CGFloat {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count,
          let parsed = Double(CommandLine.arguments[i + 1]) else { return fallback }
    return CGFloat(parsed)
}

/// Parses `--boltpoints "x,y;x,y;..."` so alternative bolt silhouettes can be fitted without
/// editing code.
func boltPointsOverride() -> [(CGFloat, CGFloat)]? {
    guard let index = CommandLine.arguments.firstIndex(of: "--boltpoints"),
          index + 1 < CommandLine.arguments.count else { return nil }
    let points = CommandLine.arguments[index + 1].split(separator: ";").compactMap { pair -> (CGFloat, CGFloat)? in
        let parts = pair.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (CGFloat(parts[0]), CGFloat(parts[1]))
    }
    return points.count >= 3 ? points : nil
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("usage: batteryicon <fraction> <out.png> [flags]\n".data(using: .utf8)!)
    exit(1)
}

if arguments.contains("--selftest") {
    print("symbol check     : \(symbolCoverage("bolt.fill"))")
    print("symbol check     : \(symbolCoverage("battery.100percent"))")
}

let image = BatteryGlyph.image(
    fraction: Double(arguments[1]) ?? 0.5,
    color: NSColor.white.withAlphaComponent(value("--ca", 1.0)),
    charging: arguments.contains("--charging"),
    bodyWidth: value("--bodyw", BatteryGlyph.bodyWidth),
    height: value("--h", BatteryGlyph.height),
    gap: value("--gap", BatteryGlyph.gap),
    nubWidth: value("--nubw", BatteryGlyph.nubWidth),
    nubHeight: value("--nubh", BatteryGlyph.nubHeight),
    cornerRadius: value("--radius", BatteryGlyph.cornerRadius),
    emptyAlpha: value("--empty", BatteryGlyph.emptyAlpha),
    boltHeightFactor: value("--bolth", BatteryGlyph.boltHeightFactor),
    boltAspect: value("--bolta", BatteryGlyph.boltAspect),
    boltCentreFactor: value("--boltc", BatteryGlyph.boltCentreFactor),
    boltOutline: value("--bolto", BatteryGlyph.boltOutline),
    boltPoints: boltPointsOverride() ?? BatteryGlyph.boltPoints)

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2])")
