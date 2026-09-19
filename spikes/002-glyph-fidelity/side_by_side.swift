// side_by_side — composites the native capture and our rendering into one zoomed image
// so the fidelity can be judged by eye, not just by the difference metric.
//
// Usage: side_by_side <native.png> <ours.png> <out.png> [zoom]
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: side_by_side <native.png> <ours.png> <out.png> [zoom]"); exit(1) }
let zoom = args.count > 4 ? (Double(args[4]) ?? 8) : 8

func loadCG(_ path: String) -> CGImage? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

guard let native = loadCG(args[1]), let ours = loadCG(args[2]) else { print("could not load images"); exit(1) }

let gapPixels = 6.0
let outWidth = Int((Double(max(native.width, ours.width)) * zoom) + gapPixels * 2)
let outHeight = Int((Double(native.height + ours.height) * zoom) + gapPixels * 3)
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// dark background so a white glyph reads; a middle band marks the boundary between the two
context.setFillColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

func draw(_ image: CGImage, y: Double) {
    context.saveGState()
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: gapPixels, y: y, width: Double(image.width) * zoom,
                                   height: Double(image.height) * zoom))
    context.restoreGState()
}

// ours on top, native below (both upscaled with nearest-neighbour so pixels are visible)
draw(ours, y: gapPixels + Double(native.height) * zoom + gapPixels)
draw(native, y: gapPixels)

guard let output = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: output)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])  (\(outWidth)x\(outHeight) px, \(Int(zoom))x zoom, ours on top / native below)")
