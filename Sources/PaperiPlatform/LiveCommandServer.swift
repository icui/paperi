import Foundation

/// Line-oriented Unix-domain socket for `paperi msg`. One request per
/// connection: space-separated arguments terminated by a newline; the reply is
/// one JSON object. The socket is created mode 0600 in the user's support dir.
@MainActor public final class LiveCommandServer {
    nonisolated public static var defaultPath: String { LiveManager.supportDirectory.appendingPathComponent("paperi.sock").path }

    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: @MainActor ([String]) -> [String: Any]

    public init(path: String = LiveCommandServer.defaultPath, handler: @escaping @MainActor ([String]) -> [String: Any]) {
        self.path = path; self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if Self.ping(path: path) { throw ServerError.alreadyRunning }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw ServerError.system("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw ServerError.system("listen", errno) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 16_384 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0a) { break }
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = handler(line.split(separator: " ").map(String.init))
        let payload = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        _ = (payload + Data([0x0a])).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    public enum ServerError: Error, CustomStringConvertible {
        case alreadyRunning, pathTooLong, system(String, Int32), unreachable
        public var description: String {
            switch self {
            case .alreadyRunning: "another paperi run is already listening"
            case .pathTooLong: "socket path too long"
            case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
            case .unreachable: "paperi run is not running (no socket)"
            }
        }
    }

    nonisolated private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return address
    }

    nonisolated static func ping(path: String) -> Bool { (try? send(["status"], path: path)) != nil }

    /// Client side for `paperi msg`.
    nonisolated public static func send(_ args: [String], path: String = defaultPath, timeout: Int = 30) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        defer { close(fd) }
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ServerError.unreachable }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = Data((args.joined(separator: " ") + "\n").utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        return reply
    }
}
