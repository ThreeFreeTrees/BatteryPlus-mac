// BatteryIcon.swift — the battery glyph, drawn to match the native macOS menu bar icon exactly.
//
// Why not an SF Symbol: measured against 2x captures of the native icon, SF Symbols match the outer
// geometry (51x24 px) but their fill comes in five discrete steps, and
// `NSImage(systemSymbolName:variableValue:)` was verified to be a no-op in this rendering path (the
// measured fill stayed at 97% for variableValue 0.05 → 0.95). The native icon fills *continuously*,
// so we draw it.
//
// Measured from the native icon at 2x (macOS 27, 24 pt menu bar), calibrated by sweeping each
// parameter and minimising a measured ink difference against live captures:
//   total glyph   25.5 x 12.0 pt   (51 x 24 px)          aspect 2.125
//   body          23.0 x 12.0 pt   corner radius 4.0 pt
//   gap            1.0 pt          body and nub are separate shapes — no shared edge
//   nub            1.25 x 3.5 pt   vertically centred, corner radius 0.75 pt
//   charged part   full-alpha glyph colour, continuous fill (boundary = charge % of body width)
//   remainder      same colour at 0.48 alpha
//   no stroke      the uncharged part has no brighter outline (verified by profile)
//   charging       a large white bolt with a ~1 pt *transparent* knockout around it: in a template
//                  image the outline cannot be a second colour, because the system recolours the
//                  image, so the gap is punched through as alpha instead
//
// Colour: the glyph is drawn in one flat colour. By default it is a *template* image, so macOS
// paints it white on a dark menu bar and black on a light one — which is the "same colour in Low
// Power Mode and out of it" requirement, never tinted. The menu bar item asks for a non-template
// render instead: measured in the live menu bar, a template image reaches only ~0.94 luminance in
// its filled part where the system's own icon reaches ~0.96, and no alpha above 1 can close that
// gap. Drawing the colour ourselves at the measured alpha matches the system's icon exactly; the
// trade-off is that we then choose white/black from the menu bar's appearance ourselves.

import AppKit

enum BatteryGlyph {
    // Calibrated against native 2x captures by sweeping each parameter and minimising the measured
    // ink difference (spikes/002-glyph-fidelity): radius 4.0 and emptyAlpha 0.48 each halved the
    // error versus the first estimate; nub 1.25x3.5 was marginally best.
    static let bodyWidth: CGFloat = 23.0
    static let height: CGFloat = 12.0
    static let gap: CGFloat = 1.0
    static let nubWidth: CGFloat = 1.5
    static let nubHeight: CGFloat = 4.0
    static let cornerRadius: CGFloat = 4.0
    static let nubCornerRadius: CGFloat = 0.75
    static let emptyAlpha: CGFloat = 0.48
    static let totalWidth: CGFloat = bodyWidth + gap + nubWidth
    static let scale: CGFloat = 2

    // charging bolt, as fractions of the glyph box: a tall bolt that overflows the pill. The
    // height factor is calibrated so the rendered box matches the native charging glyph exactly
    // (51x28 px = 14 pt tall, against the 12 pt pill).
    static let boltHeightFactor: CGFloat = 1.17
    static let boltAspect: CGFloat = 0.60
    static let boltCentreFactor: CGFloat = 0.52
    static let boltOutline: CGFloat = 1.4

    /// Draws the glyph. `fraction` is 0...1; `charging` overlays the bolt the way the system does.
    /// Metrics default to the measured values and can be overridden — that is how the spike
    /// calibrated them against native captures.
    static func image(fraction: Double, color: NSColor = .white, charging: Bool = false,
                      bodyWidth: CGFloat = BatteryGlyph.bodyWidth,
                      height: CGFloat = BatteryGlyph.height,
                      gap: CGFloat = BatteryGlyph.gap,
                      nubWidth: CGFloat = BatteryGlyph.nubWidth,
                      nubHeight: CGFloat = BatteryGlyph.nubHeight,
                      cornerRadius: CGFloat = BatteryGlyph.cornerRadius,
                      emptyAlpha: CGFloat = BatteryGlyph.emptyAlpha,
                      boltHeightFactor: CGFloat = BatteryGlyph.boltHeightFactor,
                      boltAspect: CGFloat = BatteryGlyph.boltAspect,
                      boltCentreFactor: CGFloat = BatteryGlyph.boltCentreFactor,
                      boltOutline: CGFloat = BatteryGlyph.boltOutline,
                      boltPoints: [(CGFloat, CGFloat)] = BatteryGlyph.boltPoints,
                      template: Bool = true) -> NSImage {
        let clamped = max(0, min(1, fraction))
        let totalWidth = bodyWidth + gap + nubWidth
        // The charging bolt is taller than the pill and overflows it, exactly as the native icon
        // does (its glyph box measures 51x28 px, i.e. 14 pt tall, against the pill's 12 pt). The
        // canvas has to be big enough to hold it, with the pill centred inside.
        let boltHeight = charging ? height * boltHeightFactor : 0
        let canvasHeight = max(height, boltHeight)
        let pillY = (canvasHeight - height) / 2
        let pixelWidth = Int((totalWidth * scale).rounded())
        let pixelHeight = Int((canvasHeight * scale).rounded())

        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: totalWidth, height: height))
        }
        context.scaleBy(x: scale, y: scale)

        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        let components = (r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        // The colour's own alpha scales the whole glyph. A template image is drawn by the system at
        // ~0.94 of the alpha we ask for, so a caller that wants to match the system's own icon
        // passes a slightly translucent colour and renders non-template.
        let colourAlpha = rgb.alphaComponent

        func fill(_ path: CGPath, alpha: CGFloat) {
            context.saveGState()
            context.addPath(path)
            context.setFillColor(red: components.r, green: components.g, blue: components.b, alpha: alpha * colourAlpha)
            context.fillPath()
            context.restoreGState()
        }

        let bodyPath = CGPath(roundedRect: CGRect(x: 0, y: pillY, width: bodyWidth, height: height),
                              cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // 1. the uncharged remainder: the whole body at reduced alpha
        fill(bodyPath, alpha: emptyAlpha)

        // 2. the charged part: same colour, full alpha, clipped to the body's rounded shape
        if clamped > 0 {
            context.saveGState()
            context.addPath(bodyPath)
            context.clip()
            let chargedWidth = bodyWidth * CGFloat(clamped)
            context.addPath(CGPath(rect: CGRect(x: 0, y: pillY, width: chargedWidth, height: height),
                                   transform: nil))
            context.setFillColor(red: components.r, green: components.g, blue: components.b, alpha: colourAlpha)
            context.fillPath()
            context.restoreGState()
        }

        // 3. the nub: flat where it meets the body, rounded at its outer tip. Measured from the
        //    native icon per column: 8 px tall at the body side, 6 px in the middle, 4 px at the
        //    tip — i.e. a "D" shape, not a rectangle (a rectangle was the earlier, visible mistake).
        let nubX = bodyWidth + gap
        let nubMidY = pillY + height / 2
        let halfNub = nubHeight / 2
        let kappa: CGFloat = 0.5523   // circle/ellipse approximation constant
        let nubPath = CGMutablePath()
        nubPath.move(to: CGPoint(x: nubX, y: nubMidY - halfNub))
        nubPath.addLine(to: CGPoint(x: nubX, y: nubMidY + halfNub))
        nubPath.addCurve(to: CGPoint(x: nubX + nubWidth, y: nubMidY),
                         control1: CGPoint(x: nubX + kappa * nubWidth, y: nubMidY + halfNub),
                         control2: CGPoint(x: nubX + nubWidth, y: nubMidY + kappa * halfNub))
        nubPath.addCurve(to: CGPoint(x: nubX, y: nubMidY - halfNub),
                         control1: CGPoint(x: nubX + nubWidth, y: nubMidY - kappa * halfNub),
                         control2: CGPoint(x: nubX + kappa * nubWidth, y: nubMidY - halfNub))
        nubPath.closeSubpath()
        fill(nubPath, alpha: emptyAlpha)

        // 4. charging bolt: punch a transparent gap around the silhouette, then fill the bolt.
        //    Drawn as a polygon rather than an image mask from `bolt.fill` — the same primitives the
        //    rest of this function uses, so there is no dependency on AppKit image compositing.
        if charging {
            let boltWidth = boltHeight * boltAspect
            let centre = CGPoint(x: bodyWidth * boltCentreFactor, y: canvasHeight / 2)
            let box = CGRect(x: centre.x - boltWidth / 2, y: centre.y - boltHeight / 2,
                             width: boltWidth, height: boltHeight)
            let bolt = boltPath(in: box, points: boltPoints)

            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineWidth(boltOutline * 2)
            context.setLineJoin(.round)
            context.addPath(bolt)
            context.strokePath()
            context.restoreGState()

            fill(bolt, alpha: 1)
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: totalWidth, height: canvasHeight))
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: totalWidth, height: canvasHeight))
        image.isTemplate = template
        return image
    }

    /// A lightning bolt silhouette normalised into `rect` (y up). Proportions follow the system's
    /// `bolt.fill` and are calibrated against a native charging capture — see the parameter sweep in
    /// spikes/002-glyph-fidelity. The default point set is symmetric about the mid-line, which is
    /// what gives the bolt its characteristic bar thickness.
    static let boltPoints: [(CGFloat, CGFloat)] = [
        (0.72, 1.00),   // top tip
        (0.00, 0.44),   // left shoulder
        (0.38, 0.44),   // upper inner notch (off the mid-line: on it, the bolt degenerates
                        // into a thin waist, which measured 9 px against the native's 16 px)
        (0.28, 0.00),   // bottom tip
        (1.00, 0.56),   // right shoulder
        (0.62, 0.56),   // lower inner notch
    ]

    static func boltPath(in rect: CGRect, points: [(CGFloat, CGFloat)] = BatteryGlyph.boltPoints) -> CGPath {
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let position = CGPoint(x: rect.minX + point.0 * rect.width,
                                   y: rect.minY + point.1 * rect.height)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }
}

// CLI for the spike lives in Sources/BatteryIconCLI/main.swift (`make icon`), so that this file
// stays free of top-level code and can be compiled into the app.
