import Foundation

final class SocketServer {
    let socketPath: String
    private var serverSocket: Int32 = -1
    private var acceptThread: Thread?
    private var isRunning = false

    var onCommand: ((IPCCommand) -> IPCResponse)?

    init() {
        let tmpDir = NSTemporaryDirectory()
        socketPath = (tmpDir as NSString).appendingPathComponent("moss-\(ProcessInfo.processInfo.processIdentifier).sock")
    }

    func start() {
        // Remove stale socket
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[SocketServer] Failed to create socket: \(errno)")
            return
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else {
            print("[SocketServer] Socket path too long")
            close(serverSocket)
            serverSocket = -1
            return
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for i in 0..<pathBytes.count {
                raw[i] = pathBytes[i]
            }
        }

        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("[SocketServer] Bind failed: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        guard listen(serverSocket, 128) >= 0 else {
            print("[SocketServer] Listen failed: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        isRunning = true
        print("[SocketServer] Listening on \(socketPath)")

        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.name = "moss-socket-accept"
        acceptThread?.start()
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if !isRunning { break }
                if errno == EINTR { continue }
                usleep(10_000)
                continue
            }

            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ socket: Int32) {
        defer { close(socket) }

        // Disable SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()

        while true {
            let count = read(socket, &buffer, buffer.count)
            if count <= 0 { break }

            accumulated.append(buffer, count: count)

            // Process complete lines (newline-delimited JSON)
            while let newlineIndex = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
                let commandData = accumulated[accumulated.startIndex..<newlineIndex]
                accumulated = Data(accumulated[accumulated.index(after: newlineIndex)...])

                guard let command = try? JSONDecoder().decode(IPCCommand.self, from: Data(commandData)) else {
                    let errResp = IPCResponse(success: false, message: "Invalid JSON")
                    sendResponse(errResp, to: socket)
                    continue
                }

                // Dispatch to main thread for handling
                let semaphore = DispatchSemaphore(value: 0)
                var response = IPCResponse(success: false, message: "Timeout")

                DispatchQueue.main.async { [weak self] in
                    response = self?.onCommand?(command) ?? IPCResponse(success: false, message: "No handler")
                    semaphore.signal()
                }

                _ = semaphore.wait(timeout: .now() + 5)
                sendResponse(response, to: socket)
            }
        }
    }

    private func sendResponse(_ response: IPCResponse, to socket: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { ptr in
            _ = write(socket, ptr.baseAddress!, ptr.count)
        }
    }
}
