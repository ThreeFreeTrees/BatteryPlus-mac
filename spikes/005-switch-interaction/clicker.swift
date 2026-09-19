// clicker — post a synthetic mouse click at a screen point, for interaction tests.
//
// `computer_use` cannot do this on this machine: its capture fails (no Screen Recording permission),
// and it needs a capture before it will click. CGEvent posting is the direct route.
//
// Usage: clicker <x> <y> [delaySeconds]
//   Coordinates are in POINTS with a top-left origin on the main display (CGEvent's convention).

import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("usage: clicker <x> <y> [delaySeconds]\n".data(using: .utf8)!)
    exit(1)
}
let delay = args.count > 3 ? Double(args[3]) ?? 0 : 0
let point = CGPoint(x: x, y: y)
print("clicker: will click (\(x), \(y)) after \(delay)s")

if delay > 0 { Thread.sleep(forTimeInterval: delay) }

// move first so hover/enter events fire the way they do for a real pointer
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: point, mouseButton: .left)
move?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)

let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                   mouseCursorPosition: point, mouseButton: .left)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                 mouseCursorPosition: point, mouseButton: .left)
down?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.04)
up?.post(tap: .cghidEventTap)

print("clicker: posted down/up at (\(x), \(y))")
