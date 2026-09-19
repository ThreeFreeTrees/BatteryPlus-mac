// Spike 002 helper — locate the native battery status item's exact geometry.
// Status items live on layer 25; on modern macOS they are all owned by Control Center,
// but their bounds are still reported. Build: swiftc -O -o winlist winlist.swift
import Cocoa

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

print("=== status items (layer 25) ===")
var rows: [(String, CGRect)] = []
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard layer == 25 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard let d = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = d["X"], let y = d["Y"], let wd = d["Width"], let ht = d["Height"] else { continue }
    let r = CGRect(x: x, y: y, width: wd, height: ht)
    rows.append((owner, r))
}
rows.sort { $0.1.minX < $1.1.minX }
for (owner, r) in rows {
    print(String(format: "%-16@ x=%6.1f y=%5.1f w=%6.1f h=%5.1f", owner as NSString,
                 r.minX, r.minY, r.width, r.height))
}
print("=== screens available ===")
for s in NSScreen.screens {
    print("frame=\(s.frame) visible=\(s.visibleFrame) backingScale=\(s.backingScaleFactor)")
}
