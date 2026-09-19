// smc_probe — read SMC keys (charge-limit among them) without any third-party helper.
//
// Why: on this machine the charge limit ("Charged to 80% Limit") is in no public API — not in
// IOKit, not in system_profiler, not in pmset. AlDente's helper talks to AppleSMC via the classic
// user-client protocol (kSMCGetKeyInfo / kSMCReadKey / kSMCWriteKey), and its binary contains the
// string "notPrivileged", so this probe also reports whether an unprivileged read is even allowed.
//
// Usage:
//   smc_probe                 -> read the charge-related keys that exist
//   smc_probe --list          -> list every key name the SMC knows (first 400)
//   smc_probe BCLM CHWA       -> read specific keys (4 chars each)

import Foundation
import IOKit

// MARK: - SMC protocol types (layout matters; matches the long-standing published structs)

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPowerLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    // The C struct this mirrors is 12 bytes: one attribute byte plus three padding bytes. Without
    // them Swift packs the whole SMCKeyData struct to 76 bytes and the driver rejects every call
    // with kIOReturnBadArgument (0xE00002C2) — which looks like a privilege wall but is not.
    var pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPowerLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

let kSMCHandleYPCEvent: UInt32 = 2
let kSMCReadKey: UInt8 = 5
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyCount: UInt8 = 7
let kSMCGetKeyFromIndex: UInt8 = 8
let kSMCGetKeyInfo: UInt8 = 9

func fourCharCode(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in s.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
    return result
}

func fourCharString(_ code: UInt32) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

final class SMC {
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { print("  AppleSMC service not found"); return nil }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == kIOReturnSuccess else {
            print("  IOServiceOpen failed: 0x\(String(status, radix: 16))")
            return nil
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout SMCKeyData) -> kern_return_t {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let status = withUnsafeMutablePointer(to: &input) { inPtr -> kern_return_t in
            withUnsafeMutablePointer(to: &output) { outPtr -> kern_return_t in
                IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                          inPtr, MemoryLayout<SMCKeyData>.stride,
                                          outPtr, &outputSize)
            }
        }
        lastStatus = status
        if status == kIOReturnSuccess { input = output }
        return status
    }

    /// Exposed so the debug path can inspect raw call results.
    func rawCall(_ data: inout SMCKeyData) -> kern_return_t { call(&data) }

    /// Primes the connection: GetKeyInfo is answered with kSMCKeyNotFound until one successful
    /// GetKeyFromIndex call has happened on the same connection.
    func prime() { if !primed { _ = keyName(at: 0); primed = true } }

    private(set) var lastStatus: kern_return_t = kIOReturnSuccess

    /// The key count is published under "#KEY" as four big-endian bytes — not in data32.
    func keyCount() -> Int? {
        guard let result = read("#KEY"), result.bytes.count >= 4 else { return nil }
        let b = result.bytes
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func keyName(at index: UInt32) -> String? {
        var input = SMCKeyData()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = index
        guard call(&input) == kIOReturnSuccess else { return nil }
        let name = fourCharString(input.key)
        return name.isEmpty ? nil : name
    }

    /// Reads a key: returns (type, size, bytes) or nil when the key does not exist.
    ///
    /// The connection has to be primed first: on this hardware `GetKeyInfo` answers
    /// `kSMCKeyNotFound` (132) for keys that demonstrably exist until a `GetKeyFromIndex` call has
    /// succeeded on the same connection. That looks exactly like "the key does not exist" and sent
    /// this probe down a wrong path for a while.
    private var primed = false

    func read(_ key: String) -> (type: String, size: UInt32, bytes: [UInt8], result: UInt8)? {
        prime()
        var infoRequest = SMCKeyData()
        infoRequest.key = fourCharCode(key)
        infoRequest.data8 = kSMCGetKeyInfo
        guard call(&infoRequest) == kIOReturnSuccess else { return nil }
        let info = infoRequest.keyInfo
        // Presence is keyInfo — the driver's `result` field lies (132 for keys that exist).
        guard info.dataSize > 0, info.dataType != 0, info.dataSize <= 32 else {
            return ("", 0, [], infoRequest.result)
        }

        // The value read must use a FRESH request struct. Reusing the GetKeyInfo response (same
        // fields, just data8 = 5) makes the driver answer kSMCKeyNotFound for every key — which is
        // precisely how this probe spent hours concluding that SMC reads were privilege-gated.
        var request = SMCKeyData()
        request.key = fourCharCode(key)
        request.keyInfo.dataSize = info.dataSize
        request.keyInfo.dataType = info.dataType
        request.data8 = kSMCReadKey
        guard call(&request) == kIOReturnSuccess else { return nil }

        var bytes: [UInt8] = []
        withUnsafeBytes(of: request.bytes) { raw in
            bytes = Array(raw.prefix(Int(info.dataSize)))
        }
        return (fourCharString(info.dataType), info.dataSize, bytes, request.result)
    }
}

// MARK: - main

guard let smc = SMC() else {
    print("  could not open AppleSMC (root is usually required on Apple Silicon)")
    exit(1)
}
print("  struct layout: size=\(MemoryLayout<SMCKeyData>.size) stride=\(MemoryLayout<SMCKeyData>.stride) "
      + "keyInfo=\(MemoryLayout<SMCKeyInfo>.size) vers=\(MemoryLayout<SMCVersion>.size) "
      + "offset(vers)=\(MemoryLayout<SMCKeyData>.offset(of: \.vers) ?? -1) "
      + "offset(pLimit)=\(MemoryLayout<SMCKeyData>.offset(of: \.pLimitData) ?? -1) "
      + "offset(keyInfo)=\(MemoryLayout<SMCKeyData>.offset(of: \.keyInfo) ?? -1) "
      + "offset(bytes)=\(MemoryLayout<SMCKeyData>.offset(of: \.bytes) ?? -1)")
print("  AppleSMC opened OK (unprivileged)")

if let count = smc.keyCount() {
    print("  SMC reports \(count) keys")
} else {
    let status = smc.lastStatus
    print("  key-count call failed: 0x\(String(status, radix: 16)) "
          + (status == kIOReturnNotPrivileged ? "(not privileged — needs root)"
             : status == kIOReturnBadArgument ? "(bad argument — protocol/layout problem)"
             : "(unknown)"))
}

let arguments = Array(CommandLine.arguments.dropFirst())

if let debugIndex = arguments.firstIndex(of: "--debug"), debugIndex + 1 < arguments.count {
    let wanted = arguments[debugIndex + 1]
    print("  debug \(wanted)")
    print("  my fourCharCode = 0x\(String(fourCharCode(wanted), radix: 16))")

    // find the raw key value the driver itself returned for this name
    var rawFromDriver: UInt32?
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), !n.hasPrefix("\0") else { break }
        if n == wanted {
            var probe = SMCKeyData()
            probe.data8 = kSMCGetKeyFromIndex
            probe.data32 = UInt32(i)
            _ = smc.rawCall(&probe)
            rawFromDriver = probe.key
            print("  driver key at index \(i) = 0x\(String(probe.key, radix: 16)) '\(fourCharString(probe.key))'")
            break
        }
    }

    // ask for key info using each encoding
    var requests: [(String, UInt32)] = [("my encoding", fourCharCode(wanted))]
    if let raw = rawFromDriver { requests.insert(("driver value", raw), at: 0) }
    for (label, code) in requests {
        var request = SMCKeyData()
        request.key = code
        request.data8 = kSMCGetKeyInfo
        let status = smc.rawCall(&request)
        print("  GetKeyInfo via \(label) 0x\(String(code, radix: 16)): status=0x\(String(status, radix: 16)) "
              + "result=\(request.result) size=\(request.keyInfo.dataSize) "
              + "type='\(fourCharString(request.keyInfo.dataType))'")
    }
    exit(0)
}

if let sweepIndex = arguments.firstIndex(of: "--cmd-sweep") {
    let key = sweepIndex + 1 < arguments.count ? arguments[sweepIndex + 1] : "AC-N"
    smc.prime()
    // learn the key's real size/type once
    var info = SMCKeyData()
    info.key = fourCharCode(key)
    info.data8 = kSMCGetKeyInfo
    _ = smc.rawCall(&info)
    let size = info.keyInfo.dataSize
    let type = fourCharString(info.keyInfo.dataType)
    print("  key \(key): size=\(size) type='\(type)' — sweeping the command byte")
    for command in UInt8(1)...20 {
        var request = SMCKeyData()
        request.key = fourCharCode(key)
        request.keyInfo.dataSize = size
        request.keyInfo.dataType = info.keyInfo.dataType
        request.data8 = command
        let status = smc.rawCall(&request)
        var bytes: [UInt8] = []
        withUnsafeBytes(of: request.bytes) { raw in bytes = Array(raw.prefix(Int(max(size, 1)))) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let flag = (request.result == 0 && bytes.contains { $0 != 0 }) ? "  <-- returns data" : ""
        print("    cmd \(command): status=0x\(String(status, radix: 16)) result=\(request.result) bytes=[\(hex)]\(flag)")
    }
    exit(0)
}

if let probeIndex = arguments.firstIndex(of: "--probe-reads") {
    let limit = probeIndex + 1 < arguments.count ? Int(arguments[probeIndex + 1]) ?? 60 : 60
    smc.prime()
    var names: [String] = []
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), !n.hasPrefix("\0") else { break }
        names.append(n)
    }
    var readable = 0, refused = 0
    print("  probing reads across \(min(limit, names.count)) keys")
    for name in names.prefix(limit) {
        var request = SMCKeyData()
        request.key = fourCharCode(name)
        request.data8 = kSMCGetKeyInfo
        _ = smc.rawCall(&request)
        let size = request.keyInfo.dataSize
        guard size > 0, size <= 32 else { continue }
        request.data8 = kSMCReadKey
        _ = smc.rawCall(&request)
        var bytes: [UInt8] = []
        withUnsafeBytes(of: request.bytes) { raw in bytes = Array(raw.prefix(Int(size))) }
        let value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        if request.result == 0 && value != 0 {
            readable += 1
            print("    READABLE \(name) type=\(fourCharString(request.keyInfo.dataType)) bytes=[\(hex)]")
        } else {
            refused += 1
        }
    }
    print("  readable=\(readable) refused-or-zero=\(refused)")
    exit(0)
}

if let debugIndex = arguments.firstIndex(of: "--debug-read"), debugIndex + 1 < arguments.count {
    let key = arguments[debugIndex + 1]
    smc.prime()
    var request = SMCKeyData()
    request.key = fourCharCode(key)
    request.data8 = kSMCGetKeyInfo
    var status = smc.rawCall(&request)
    print("  GetKeyInfo: status=0x\(String(status, radix: 16)) result=\(request.result) "
          + "size=\(request.keyInfo.dataSize) type='\(fourCharString(request.keyInfo.dataType))'")

    request.data8 = kSMCReadKey
    status = smc.rawCall(&request)
    var bytes: [UInt8] = []
    withUnsafeBytes(of: request.bytes) { raw in
        bytes = Array(raw.prefix(Int(request.keyInfo.dataSize)))
    }
    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  ReadKey:    status=0x\(String(status, radix: 16)) result=\(request.result) "
          + "size=\(request.keyInfo.dataSize) bytes=[\(hex)]")
    exit(0)
}

if let snapshotIndex = arguments.firstIndex(of: "--snapshot") {
    let path = snapshotIndex + 1 < arguments.count ? arguments[snapshotIndex + 1] : "smc_snapshot.txt"
    var names: [String] = []
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), !n.hasPrefix("\0") else { break }
        names.append(n)
    }
    var lines: [String] = []
    for name in names.sorted() {
        guard let r = smc.read(name) else { continue }
        let hex = r.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        lines.append("\(name)\t\(r.type)\t\(hex)")
    }
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    print("  wrote \(lines.count) keys to \(path)")
    exit(0)
}

if arguments.contains("--root-report") {
    // One compact report to run as root: the sanity keys, the charge-limit candidate, and any key
    // in the whole table holding exactly 80 or 100 (the user's limit is 80%).
    print("sanity (these must read non-zero if values are readable at all):")
    for key in ["B0FC", "B0RM", "B0AC", "B0AV", "BLCM", "BLCC", "BLTA", "B0CT", "B0CS"] {
        if let r = smc.read(key), r.size > 0 {
            var value: UInt64 = 0
            for (i, b) in r.bytes.enumerated() where i < 8 { value |= UInt64(b) << (8 * i) }
            let hex = r.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  \(key) type=\(r.type) size=\(r.size) value=\(value) bytes=[\(hex)]")
        } else {
            print("  \(key): absent")
        }
    }

    var names: [String] = []
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), !n.hasPrefix("\0") else { break }
        names.append(n)
    }
    var hits: [String] = []
    for name in names {
        guard let r = smc.read(name), r.size == 1 || r.size == 2 else { continue }
        var value: UInt64 = 0
        for (i, b) in r.bytes.enumerated() where i < 8 { value |= UInt64(b) << (8 * i) }
        if value == 80 || value == 100 { hits.append("\(name)=\(value)") }
    }
    print("keys in the whole table whose value is 80 or 100: \(hits.joined(separator: " "))")
    exit(0)
}

if let primeIndex = arguments.firstIndex(of: "--prime-test") {
    let n = primeIndex + 1 < arguments.count ? Int(arguments[primeIndex + 1]) ?? 0 : 0
    print("  priming with \(n) GetKeyFromIndex calls, then reading B0FC / BLCM / CHWA")
    for i in 0..<n { _ = smc.keyName(at: UInt32(i)) }
    for key in ["B0FC", "BLCM", "CHWA", "B0RM"] {
        if let r = smc.read(key) {
            var value: UInt64 = 0
            for (i, b) in r.bytes.enumerated() where i < 8 { value |= UInt64(b) << (8 * i) }
            print("    \(key): result=\(r.result) type=\(r.type) size=\(r.size) value=\(value)")
        } else {
            print("    \(key): call failed")
        }
    }
    exit(0)
}

if arguments.contains("--scan") {
    // Read every key whose name could plausibly carry the charge limit and print its value.
    var names: [String] = []
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), !n.hasPrefix("\0") else { break }
        names.append(n)
    }
    print("  \(names.count) keys; scanning charge-related ones")
    let candidates = names.filter { name in
        let upper = name.uppercased()
        return upper.contains("CH") || upper.hasPrefix("BL") || upper.hasPrefix("B0")
            || upper.hasPrefix("BF") || upper.contains("LIM") || upper.contains("MAX")
    }
    print("  \(candidates.count) candidates")
    for name in candidates {
        guard let result = smc.read(name), result.result == 0 else { continue }
        var value: UInt64 = 0
        for (i, byte) in result.bytes.enumerated() where i < 8 { value |= UInt64(byte) << (8 * i) }
        let hex = result.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "    %@ type=%@ size=%d value=%-8llu [%@]",
                     name, result.type, result.size, value, hex))
    }
    exit(0)
}

if arguments.contains("--list") {
    // Do not depend on "#KEY": on Apple Silicon it reads back zeros. Walk GetKeyFromIndex directly
    // until it stops answering, which is the part of the protocol that demonstrably works.
    var names: [String] = []
    for i in 0..<3000 {
        guard let n = smc.keyName(at: UInt32(i)), n != "\0\0\0\0", !n.hasPrefix("\0") else { break }
        names.append(n)
    }
    print("  enumerated \(names.count) key names (unprivileged)")
    print("  first 40: \(names.prefix(40).joined(separator: " "))")
    let interesting = names.filter { name in
        let upper = name.uppercased()
        return upper.contains("CHG") || upper.contains("LIMIT") || upper.hasPrefix("B")
            || upper.hasPrefix("CH") || upper.hasPrefix("AC")
    }
    print("  charge/battery-ish: \(interesting.joined(separator: " "))")
    exit(0)
}

// Keys that plausibly carry the charge limit / charging behaviour.
let candidates = arguments.isEmpty
    ? ["BCLM", "BFCL", "CHWA", "CH0B", "CH0C", "CH0I", "ACEN", "ACLC", "ACFP", "CHSC", "CHBI"]
    : arguments

for key in candidates {
    guard let result = smc.read(key) else { print("  \(key): call failed"); continue }
    if result.result != 0 {
        print("  \(key): not present (result \(result.result))")
        continue
    }
    var value: UInt64 = 0
    for (i, byte) in result.bytes.enumerated() where i < 8 {
        value |= UInt64(byte) << (8 * i)
    }
    let hex = result.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  \(key): type=\(result.type) size=\(result.size) bytes=[\(hex)] value=\(value)")
}
