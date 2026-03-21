import Foundation

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class SocketClient {
    private var socketFD: Int32 = -1
    private let path: String

    init(path: String) {
        self.path = path
    }

    deinit {
        if socketFD >= 0 {
            close(socketFD)
        }
    }

    func connect() throws {
        // Verify socket exists and is owned by current user
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path is not a Unix socket: \(path)")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket not owned by current user")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create socket")
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLen - 1)
            }
        }

        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let err = errno
            Darwin.close(socketFD)
            socketFD = -1
            throw CLIError(message: "Failed to connect: \(String(cString: strerror(err)))")
        }
    }

    struct Response: Codable {
        let success: Bool
        let message: String
    }

    func send(surfaceId: String, command: String, value: String?) throws -> Response {
        guard socketFD >= 0 else {
            throw CLIError(message: "Not connected")
        }

        struct Command: Codable {
            let surface_id: String
            let command: String
            let value: String?
        }

        let cmd = Command(surface_id: surfaceId, command: command, value: value)
        guard var payload = try? JSONEncoder().encode(cmd) else {
            throw CLIError(message: "Failed to encode command")
        }
        payload.append(UInt8(ascii: "\n"))

        // Send
        let sent = payload.withUnsafeBytes { ptr in
            Darwin.write(socketFD, ptr.baseAddress!, ptr.count)
        }
        guard sent > 0 else {
            throw CLIError(message: "Failed to write to socket")
        }

        // Read response with timeout
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.contains(UInt8(ascii: "\n")) { break }
        }

        // Strip trailing newline
        if data.last == UInt8(ascii: "\n") {
            data.removeLast()
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CLIError(message: "Invalid response from server")
        }

        return response
    }
}
