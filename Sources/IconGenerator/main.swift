// IconGenerator — renders the app icon: the battery glyph's own shape, filled with a rainbow gradient,
// shaded like a glossy object, with a white "+" centred in the body.
//
// The geometry is the menu bar glyph's, unchanged (Sources/BatteryPlus/BatteryIcon.swift): a 23×12 body,
// 1 pt gap, a 1.5×4 nub and a 4 pt corner radius — so the icon is literally the same shape at a bigger
// size rather than a lookalike.
//
// Usage: batteryicon-rainbow <iconset-output-dir>
// Writes every size macOS asks for; the caller turns the folder into an .icns with iconutil.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - geometry, in the glyph's own units

private let bodyUnits: CGFloat = 23.0
private let heightUnits: CGFloat = 12.0
private let gapUnits: CGFloat = 1.0
private let nubWidthUnits: CGFloat = 1.5
private let nubHeightUnits: CGFloat = 4.0
private let radiusUnits: CGFloat = 4.0
private let nubRadiusUnits: CGFloat = 0.75
private let totalUnits = bodyUnits + gapUnits + nubWidthUnits

/// Sizes below this are drawn boldly: fine shading and thin details just turn to mud at 16–32 px.
private let crispBelow: CGFloat = 48

private func rainbow() -> CGGradient? {
    let colors = [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen,
                  .systemTeal, .systemBlue, .systemPurple].map { $0.cgColor }
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                      locations: [0.0, 0.17, 0.33, 0.5, 0.66, 0.83, 1.0])
}

private func renderIcon(side: CGFloat) -> CGImage? {
    let pixels = Int(side)
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    let bold = side < crispBelow

    // macOS composites a custom .icns onto its own generic grey tile, so the tile has to be part of the
    // artwork: a full-bleed rounded square (Apple's grid: content ≈ 82 % of the canvas, corners at
    // ≈ 22.5 % of that side) with a graphite gradient, a rim light and a shadow.
    let tileSide = side * 0.82
    let tileInset = (side - tileSide) / 2
    let tileRadius = tileSide * 0.225
    let tileRect = CGRect(x: tileInset, y: tileInset, width: tileSide, height: tileSide)
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    let tileColors = [NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.23, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor]
    if let tileGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: tileColors as CFArray, locations: [0.0, 1.0]) {
        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        context.drawLinearGradient(tileGradient,
                                   start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
                                   end: CGPoint(x: tileRect.midX, y: tileRect.minY), options: [])
        // centre-bright shading: the tile lifts towards the middle and falls away at the edges
        let centreColors = [NSColor.white.withAlphaComponent(0.14).cgColor,
                            NSColor.white.withAlphaComponent(0.04).cgColor,
                            NSColor.white.withAlphaComponent(0.0).cgColor]
        if let centre = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: centreColors as CFArray, locations: [0.0, 0.45, 1.0]) {
            context.drawRadialGradient(centre,
                                       startCenter: CGPoint(x: tileRect.midX, y: tileRect.midY), startRadius: 0,
                                       endCenter: CGPoint(x: tileRect.midX, y: tileRect.midY), endRadius: tileSide * 0.62,
                                       options: [])
        }
        context.restoreGState()
    }
    // rim light along the top edge, so the tile has an edge on dark backgrounds
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.fill(CGRect(x: tileRect.minX, y: tileRect.maxY - side * 0.006,
                        width: tileRect.width, height: side * 0.006))
    context.restoreGState()

    // the glyph on the tile: bigger than before, and the BODY centred on the tile — that is what puts
    // the "+" on the square's centre, with the gap and nub hanging off to the right.
    let unit = tileSide * 0.76 / bodyUnits
    let body = CGRect(x: 0, y: 0, width: bodyUnits * unit, height: heightUnits * unit)
    let nub = CGRect(x: 0, y: 0, width: nubWidthUnits * unit, height: nubHeightUnits * unit)
    let radius = radiusUnits * unit
    let originX = tileRect.midX - body.width / 2
    let originY = tileRect.midY - body.height / 2
    let bodyRect = body.offsetBy(dx: originX, dy: originY)
    let nubRect = nub.offsetBy(dx: originX + body.width + gapUnits * unit,
                               dy: originY + (body.height - nub.height) / 2)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // The nub is the battery's terminal: flat where it faces the body, rounded on the outside — a "D",
    // not a little rectangle with soft corners. Built from two explicit quarter-circle beziers rather
    // than addArc: that API's direction flag reads inverted in this y-up space and produced a bowtie.
    let nubOuterRadius = nubRect.width / 2
    let control = 0.5523 * nubOuterRadius
    let nubPath = CGMutablePath()
    nubPath.move(to: CGPoint(x: nubRect.minX, y: nubRect.minY))
    nubPath.addLine(to: CGPoint(x: nubRect.maxX - nubOuterRadius, y: nubRect.minY))
    nubPath.addCurve(to: CGPoint(x: nubRect.maxX, y: nubRect.midY),
                     control1: CGPoint(x: nubRect.maxX - nubOuterRadius + control, y: nubRect.minY),
                     control2: CGPoint(x: nubRect.maxX, y: nubRect.midY - control))
    nubPath.addCurve(to: CGPoint(x: nubRect.maxX - nubOuterRadius, y: nubRect.maxY),
                     control1: CGPoint(x: nubRect.maxX, y: nubRect.midY + control),
                     control2: CGPoint(x: nubRect.maxX - nubOuterRadius + control, y: nubRect.maxY))
    nubPath.addLine(to: CGPoint(x: nubRect.minX, y: nubRect.maxY))
    nubPath.closeSubpath()

    // drop shadow under the whole shape, so it reads on light and dark backgrounds alike
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
    context.addPath(bodyPath)
    context.addPath(nubPath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    guard let spectrum = rainbow() else { return nil }

    // rainbow fill: one gradient across the whole icon, so body and nub line up
    let gradientStart = CGPoint(x: bodyRect.minX, y: bodyRect.midY)
    let gradientEnd = CGPoint(x: nubRect.maxX, y: bodyRect.midY)
    for path in [bodyPath, nubPath] {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(spectrum, start: gradientStart, end: gradientEnd, options: [])
        context.restoreGState()
    }

    // shading: light from the top, weight at the bottom — a glossy cylinder rather than flat colour
    if !bold {
        let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [NSColor.white.withAlphaComponent(0.42).cgColor,
                                        NSColor.white.withAlphaComponent(0.05).cgColor,
                                        NSColor.black.withAlphaComponent(0.06).cgColor,
                                        NSColor.black.withAlphaComponent(0.30).cgColor] as CFArray,
                               locations: [0.0, 0.42, 0.62, 1.0])
        if let shade {
            context.saveGState()
            context.addPath(bodyPath)
            context.addPath(nubPath)
            context.clip()
            context.drawLinearGradient(shade,
                                       start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
                                       end: CGPoint(x: bodyRect.midX, y: bodyRect.minY), options: [])
            context.restoreGState()
        }
        // specular line along the top edge
        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let lineHeight = max(1, side * 0.012)
        let highlight = CGRect(x: bodyRect.minX, y: bodyRect.maxY - lineHeight * 2.2,
                               width: bodyRect.width, height: lineHeight)
        context.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        context.fill(highlight)
        context.restoreGState()
    }

    // outline, for definition at small sizes
    context.saveGState()
    context.setLineWidth(max(1, side * (bold ? 0.018 : 0.008)))
    context.setStrokeColor(NSColor.black.withAlphaComponent(bold ? 0.30 : 0.18).cgColor)
    context.addPath(bodyPath)
    context.addPath(nubPath)
    context.strokePath()
    context.restoreGState()

    // the "+": centred in the body, white with a soft shadow
    let plusSize = bodyRect.height * (bold ? 0.62 : 0.50)
    let thickness = plusSize * (bold ? 0.26 : 0.20)
    let centre = CGPoint(x: bodyRect.midX, y: bodyRect.midY)
    let plusPath = CGMutablePath()
    let horizontal = CGRect(x: centre.x - plusSize / 2, y: centre.y - thickness / 2,
                            width: plusSize, height: thickness)
    let vertical = CGRect(x: centre.x - thickness / 2, y: centre.y - plusSize / 2,
                          width: thickness, height: plusSize)
    for bar in [horizontal, vertical] {
        plusPath.addPath(CGPath(roundedRect: bar, cornerWidth: thickness * 0.30, cornerHeight: thickness * 0.30, transform: nil))
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.006), blur: side * 0.012,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
    context.addPath(plusPath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    return context.makeImage()
}

// MARK: - write the iconset

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: batteryicon-rainbow <iconset-output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sizes: [(name: String, side: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in sizes {
    guard let image = renderIcon(side: entry.side) else {
        FileHandle.standardError.write("failed to render \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("\(entry.name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to write \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(entry.name).png (\(Int(entry.side)) px)")
}