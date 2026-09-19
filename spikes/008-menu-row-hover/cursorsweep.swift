// cursorsweep.swift — move the real cursor through a list of points, quickly, to reproduce hover bugs.
// Usage: cursorsweep x,y x,y ... (screen coordinates, top-left origin)
import CoreGraphics
import Foundation

var index = 1
while index < CommandLine.arguments.count {
    let parts = CommandLine.arguments[index].split(separator: ",").compactMap { Double($0) }
    if parts.count == 2 {
        CGWarpMouseCursorPosition(CGPoint(x: parts[0], y: parts[1]))
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(6_000)                 // 6 ms between points: a fast sweep, no dwell
    }
    index += 1
}
if let current = CGEvent(source: nil)?.location {
    print("cursor now at \(Int(current.x)),\(Int(current.y))")
}
