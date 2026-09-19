// client_test — speaks the helper protocol over the UNIX socket, for verification.
// Usage: client_test [socket-path] [command...]
//   client_test                          → PING, GET, SET battery 1, GET, SET battery 0, GET
//   client_test /tmp/bm.sock PING        → single command
import Foundation
import Darwin

let socketPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/var/run/batteryplus.sock"
let explicit = Array(CommandLine.arguments.dropFirst(2))

func send(_ command: String) -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "ERR socket() \(errno)" }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            for (index, byte) in pathBytes.enumerated() where index < 103 {
                destination[index] = CChar(bitPattern: byte)
            }
        }
    }
    let connected = withUnsafePointer(to: &address) { rawPointer in
        rawPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return "ERR connect() \(errno) — is the helper installed?" }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let out = (command + "\n").data(using: .utf8)!
    _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

    var buffer = [UInt8]()
    var byte: UInt8 = 0
    while buffer.count < 512 {
        let count = read(fd, &byte, 1)
        if count <= 0 { break }
        if byte == 0x0A { break }
        buffer.append(byte)
    }
    return String(bytes: buffer, encoding: .utf8) ?? "ERR no reply"
}

let sequence = explicit.isEmpty
    ? ["PING", "GET", "SET battery 1", "GET", "SET battery 0", "GET"]
    : explicit
for command in sequence {
    print(String(format: "%-16@ -> %@", command as NSString, send(command) as NSString))
}
