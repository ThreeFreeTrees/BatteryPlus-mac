// batteryplus-helper — privileged battery setters (root, launchd-managed).
//
// Why this exists: writing the energy mode needs `com.apple.private.iokit.updatemodepreference`
// (a restricted entitlement we cannot self-sign) or root, and writing the charge limit needs SMC
// access that is only meaningful as root. AlDente solves the same problems with a privileged
// helper; SMJobBless is unavailable to us (it requires an Apple-issued certificate), so this is the
// same architecture with a direct install: root-owned binary + LaunchDaemon + IPC.
//
// Security model:
//   * the whole operation space is: 4 fixed pmset commands (SET <battery|ac> <0|1>), plus exactly
//     one SMC write (SETLIMIT <50-100> → key BfSC, the charge-limit percentage). No arbitrary
//     keys, no shell, no user input reaches an argv or a key name
//   * the socket is owned by the user and mode 0600, so only that user's processes can connect
//   * the peer uid is re-verified with getpeereid() on every connection (defence in depth)
//   * pmset is spawned with fixed argv; the SMC request is built from a validated integer
//   * requests are a single line, strictly parsed, max 128 bytes; anything else is refused
//   * every write is followed by a read-back — a return code alone is never trusted
//
// Usage: batteryplus-helper <allowed-uid> [socket-path]

import Foundation
import Darwin
import IOKit

let version = "0.2"
let arguments = CommandLine.arguments

guard arguments.count >= 2, let allowedUID = uid_t(arguments[1]) else {
    FileHandle.standardError.write("usage: batteryplus-helper <allowed-uid> [socket-path]\n".data(using: .utf8)!)
    exit(2)
}
let socketPath = arguments.count >= 3 ? arguments[2] : "/var/run/batteryplus.sock"
let kIOReturnSuccess: Int32 = 0

func log(_ message: String) {
    FileHandle.standardError.write(("[batteryplus-helper] " + message + "\n").data(using: .utf8)!)
}

// MARK: - pmset

/// Runs pmset with a fixed argv built from a strictly validated scope/value pair.
/// Returns (terminationStatus, combined output). Never uses a shell.
func runPMSet(arguments argv: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = argv
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch {
        return (-1, "spawn failed: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Reads `pmset -g custom` and returns the four energy-mode settings as "name=value" tokens.
func readModes() -> String {
    let (_, output) = runPMSet(arguments: ["-g", "custom"])
    var results: [String] = []
    var section = ""
    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Battery Power:") { section = "battery"; continue }
        if line.hasPrefix("AC Power:") { section = "ac"; continue }
        if line.hasPrefix("UPS Power:") { section = "ups"; continue }
        if line.hasPrefix("lowpowermode"), !section.isEmpty {
            let value = line.split(separator: " ").last.map(String.init) ?? "?"
            results.append("\(section)=\(value)")
        }
    }
    return results.joined(separator: " ")
}

// MARK: - SMC (charge limit)

// The charge limit lives in the SMC key BfSC ("battery full state of charge", ui8 percentage).
// Reading it needs no privileges — the app does that itself, unprivileged. WRITING is only
// meaningful as root, which is why it is here. The protocol quirks (exactly 80-byte struct, priming,
// fresh struct for value operations) are documented in spikes/004-charge-limit/README.md.

private let kSMCHandleYPCEvent = UInt32(2)
private let kSMCReadKey = UInt8(5)
private let kSMCWriteKey = UInt8(6)
private let kSMCGetKeyFromIndex = UInt8(8)
private let kSMCGetKeyInfo = UInt8(9)
private let chargeLimitKey = "BfSC"

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    var pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0     // must total 12 bytes
}

private struct SMCKeyData {
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

final class SMCSession {
    private var connection: io_connect_t = 0
    private var primed = false

    private static func fourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }

    func open() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    func close() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    private func call(_ data: inout SMCKeyData) -> Int32 {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let status = withUnsafeMutablePointer(to: &data) { inPtr -> Int32 in
            withUnsafeMutablePointer(to: &output) { outPtr -> Int32 in
                IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                          inPtr, MemoryLayout<SMCKeyData>.stride,
                                          outPtr, &outputSize)
            }
        }
        if status == kIOReturnSuccess { data = output }
        return status
    }

    private func prime() {
        guard !primed else { return }
        var request = SMCKeyData()
        request.data8 = kSMCGetKeyFromIndex
        _ = call(&request)
        primed = true
    }

    /// Returns the key's metadata and value bytes, or nil if the key is absent.
    func read(_ key: String) -> (size: UInt32, bytes: [UInt8])? {
        prime()
        let code = Self.fourCharCode(key)
        var infoRequest = SMCKeyData()
        infoRequest.key = code
        infoRequest.data8 = kSMCGetKeyInfo
        guard call(&infoRequest) == kIOReturnSuccess else { return nil }
        let info = infoRequest.keyInfo
        guard info.dataSize > 0, info.dataType != 0, info.dataSize <= 32 else { return nil }

        var request = SMCKeyData()                     // must be fresh (measured quirk)
        request.key = code
        request.keyInfo.dataSize = info.dataSize
        request.keyInfo.dataType = info.dataType
        request.data8 = kSMCReadKey
        guard call(&request) == kIOReturnSuccess else { return nil }

        var bytes: [UInt8] = []
        withUnsafeBytes(of: request.bytes) { raw in
            bytes = Array(raw.prefix(Int(info.dataSize)))
        }
        return (info.dataSize, bytes)
    }

    /// Writes a single-byte value into `key`. The caller must read back — nothing here is trusted.
    func writeByte(_ key: String, value: UInt8) -> Bool {
        prime()
        let code = Self.fourCharCode(key)
        var infoRequest = SMCKeyData()
        infoRequest.key = code
        infoRequest.data8 = kSMCGetKeyInfo
        guard call(&infoRequest) == kIOReturnSuccess else { return false }
        let info = infoRequest.keyInfo
        guard info.dataSize > 0, info.dataType != 0, info.dataSize <= 32 else { return false }

        var request = SMCKeyData()                     // fresh, same rule as the read
        request.key = code
        request.keyInfo.dataSize = info.dataSize
        request.keyInfo.dataType = info.dataType
        request.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &request.bytes) { raw in
            for index in 0..<min(Int(info.dataSize), 32) {
                raw[index] = (index == 0) ? value : 0
            }
        }
        return call(&request) == kIOReturnSuccess
    }
}

/// Reads the charge limit percentage via a fresh session, or nil on failure.
/// Convenience wrapper: opens a session for one operation and closes it afterwards.
func withSMCSession<R>(_ body: (SMCSession) -> R?) -> R? {
    let session = SMCSession()
    guard session.open() else { return nil }
    defer { session.close() }
    return body(session)
}

func readChargeLimitValue() -> Int? {
    withSMCSession { session in
        guard let result = session.read(chargeLimitKey), let first = result.bytes.first else { return nil }
        return first <= 100 ? Int(first) : nil
    }
}

func writeChargeLimitValue(_ value: Int) -> Bool {
    withSMCSession { session in
        session.writeByte(chargeLimitKey, value: UInt8(value))
    } ?? false
}

// MARK: - request handling

func handle(_ client: Int32) {
    var peerUID: uid_t = 0, peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == allowedUID || peerUID == 0 else {
        _ = sendLine(client, "ERR forbidden peer uid \(peerUID)")
        log("refused connection from uid \(peerUID)")
        return
    }

    guard let request = readLine(client) else { return }
    let parts = request.split(separator: " ").map(String.init)

    switch parts.first?.uppercased() {
    case "PING":
        sendLine(client, "OK pong \(version) uid=\(allowedUID)")

    case "GET":
        sendLine(client, "OK " + readModes())

    case "SET":
        // strictly: SET <battery|ac> <0|1>
        guard parts.count == 3,
              parts[1] == "battery" || parts[1] == "ac",
              parts[2] == "0" || parts[2] == "1" else {
            sendLine(client, "ERR usage: SET <battery|ac> <0|1>")
            return
        }
        let flag = parts[1] == "battery" ? "-b" : "-c"
        let (status, output) = runPMSet(arguments: [flag, "lowpowermode", parts[2]])
        let modes = readModes()   // read back: the caller must never trust a return code alone
        if status == 0 {
            sendLine(client, "OK set \(parts[1])=\(parts[2]) now \(modes)")
        } else {
            sendLine(client, "ERR pmset exit \(status) \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

    case "SETLIMIT":
        // strictly: SETLIMIT <50-100> — the charge-limit percentage, written to SMC key BfSC
        guard parts.count == 2, let value = Int(parts[1]), (50...100).contains(value) else {
            sendLine(client, "ERR usage: SETLIMIT <50-100>")
            return
        }
        let written = writeChargeLimitValue(value)
        let readBack = readChargeLimitValue()   // never trust the write alone
        if written, let readBack {
            sendLine(client, "OK limit=\(value) readback=\(readBack)")
        } else {
            sendLine(client, "ERR smc write failed (readback=\(readBack.map(String.init) ?? "?"))")
        }

    default:
        sendLine(client, "ERR unknown command")
    }
}

func sendLine(_ fd: Int32, _ text: String) {
    let data = (text + "\n").data(using: .utf8)!
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

func readLine(_ fd: Int32, limit: Int = 128) -> String? {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8]()
    var byte: UInt8 = 0
    while buffer.count < limit {
        let count = read(fd, &byte, 1)
        if count <= 0 { break }
        if byte == 0x0A { break }
        buffer.append(byte)
    }
    return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
}

// MARK: - server

func makeListener(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { log("socket() failed: \(errno)"); return nil }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            for (index, byte) in pathBytes.enumerated() where index < 103 {
                destination[index] = CChar(bitPattern: byte)
            }
        }
    }

    unlink(path)
    let bound = withUnsafePointer(to: &address) { rawPointer in
        rawPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { log("bind(\(path)) failed: \(errno)"); close(fd); return nil }

    // Only the intended user may connect.
    if chown(path, allowedUID, 0) != 0 { log("chown failed: \(errno)") }
    if chmod(path, 0o600) != 0 { log("chmod failed: \(errno)") }

    guard listen(fd, 8) == 0 else { log("listen failed: \(errno)"); close(fd); return nil }
    return fd
}

guard let listener = makeListener(path: socketPath) else { exit(1) }
log("listening on \(socketPath) for uid \(allowedUID) (v\(version), running as uid \(getuid()))")

signal(SIGPIPE, SIG_IGN)
while true {
    let client = accept(listener, nil, nil)
    if client < 0 { continue }
    handle(client)
    close(client)
}