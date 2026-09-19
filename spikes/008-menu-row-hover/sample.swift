// sample.swift — print the colour at given pixel positions of a PNG (original image coordinates).
import AppKit
import Foundation

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    print("cannot read image"); exit(1)
}
print("size: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
var index = 2
while index + 1 < CommandLine.arguments.count {
    let x = Int(CommandLine.arguments[index]) ?? 0
    let y = Int(CommandLine.arguments[index + 1]) ?? 0
    if let colour = bitmap.colorAt(x: x, y: y) {
        let r = Int(colour.redComponent * 255), g = Int(colour.greenComponent * 255), b = Int(colour.blueComponent * 255)
        print("  (\(x),\(y)) rgb(\(r),\(g),\(b))")
    } else {
        print("  (\(x),\(y)) out of range")
    }
    index += 2
}
