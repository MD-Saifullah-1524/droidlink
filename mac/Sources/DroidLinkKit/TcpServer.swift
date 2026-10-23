import Foundation
import SwiftProtobuf
import Darwin

/// High-performance POSIX BSD TCP connection handler.
/// Runs socket read, deframing, AES-256 decryption, and Protobuf deserialization on a background queue.
final class TcpClientConnection: @unchecked Sendable {
    let clientFd: Int32
    private let cryptoChannel: CryptoChannel?
    private let framer = MessageFramer()
    private var incomingBuffer = Data()
    private let queue: DispatchQueue
    private var readSource: (any DispatchSourceRead)?
    private var isClosed = false
    private let closeLock = NSLock()

    var onMessageReceived: (@Sendable (Droidlink_Protocol_DroidLinkMessage) -> Void)?
    var onDisconnected: (@Sendable () -> Void)?

    init(clientFd: Int32, cryptoChannel: CryptoChannel?, queue: DispatchQueue) {
        self.clientFd = clientFd
        self.cryptoChannel = cryptoChannel
        self.queue = queue

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        source.setCancelHandler {
            Darwin.close(clientFd)
        }
        self.readSource = source
        source.resume()
    }

    private func readFromClient() {
        closeLock.lock()
        let closed = isClosed
        closeLock.unlock()
        guard !closed else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = Darwin.read(clientFd, &buffer, buffer.count)
            if bytesRead > 0 {
                incomingBuffer.append(buffer, count: bytesRead)
                processBuffer()
            } else if bytesRead == 0 {
                print("🔌 Peer closed connection")
                fflush(stdout)
                close()
                onDisconnected?()
                break
            } else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                } else {
                    print("❌ Socket read error: \(errno)")
                    fflush(stdout)
                    close()
                    onDisconnected?()
                    break
                }
            }
        }
    }

    private func processBuffer() {
        do {
            let frames = try framer.deframe(from: &incomingBuffer)
            for framePayload in frames {
                handleFramePayload(framePayload)
            }
        } catch {
            print("⚠️ Deframing error: \(error)")
            fflush(stdout)
            incomingBuffer.removeAll()
        }
    }

    private func handleFramePayload(_ payload: Data) {
        do {
            let decryptedData: Data
            if let crypto = cryptoChannel {
                decryptedData = try crypto.decrypt(payload)
            } else {
                decryptedData = payload
            }
            let message = try Droidlink_Protocol_DroidLinkMessage(serializedBytes: decryptedData)
            onMessageReceived?(message)
        } catch {
            print("❌ Failed to decrypt or decode Protobuf message: \(error)")
            fflush(stdout)
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        incomingBuffer.removeAll()
    }
}

/// High-performance POSIX BSD TCP server with GCD dispatch sources.
/// Bypasses macOS 15+ Network.framework CLI sandbox restrictions for instant local connection.
@MainActor
final class TcpServer {
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var listenSource: (any DispatchSourceRead)?
    private var activeConnection: TcpClientConnection?
    private let networkQueue = DispatchQueue(label: "com.droidlink.tcpserver", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "com.droidlink.tcp.send", qos: .userInteractive)

    private let framer = MessageFramer()
    var cryptoChannel: CryptoChannel?
    private var pendingFileContinuations: [CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>] = []
    private let continuationLock = NSLock()

    var hasActiveClient: Bool { clientFd >= 0 }
    var isRunning: Bool { serverFd >= 0 }
    public private(set) var listeningPort: UInt16 = 0
    
    init() {
        ScreenMirroringManager.shared.onSendScreenMessage = { [weak self] msg in
            self?.sendScreen(message: msg)
        }
    }
    
    /// Starts the server, dynamically picking a free non-conflicting port starting from preferredPort
    func start(port: UInt16 = 29170, cryptoChannel: CryptoChannel) throws {
        self.cryptoChannel = cryptoChannel
        stop()
        
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        // List of candidate ports avoiding famous software (3000, 5000, 7000, 8000, 8080, 9000, etc.)
        let startPort = port > 0 ? port : 29170
        var boundPort: UInt16 = 0
        var boundSuccess = false
        
        // Try candidate ports in range [startPort, startPort + 30]
        for tryPort in startPort..<(startPort + 30) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = tryPort.bigEndian
            addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY
            
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if res == 0 {
                boundPort = tryPort
                boundSuccess = true
                break
            }
        }
        
        // Fallback: let OS assign any free ephemeral port
        if !boundSuccess {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // Ephemeral
            addr.sin_addr.s_addr = in_addr_t(0)
            
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard res == 0 else {
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
            }
        }
        
        // Inspect assigned port
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getSockResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        if getSockResult == 0 {
            self.listeningPort = UInt16(bigEndian: boundAddr.sin_port)
        } else {
            self.listeningPort = boundPort
        }
        
        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        
        self.serverFd = fd
        print("🚀 DroidLink Server listening on dynamic port \(self.listeningPort) (POSIX)")
        fflush(stdout)
        
        setupAdbReverse(port: self.listeningPort)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleIncomingConnection()
        }
        source.resume()
        self.listenSource = source
    }
    
    private func handleIncomingConnection() {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let newClientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(serverFd, $0, &len)
            }
        }
        
        guard newClientFd >= 0 else { return }
        
        let clientIp = String(cString: inet_ntoa(clientAddr.sin_addr))
        print("📱 New incoming connection from \(clientIp):\(UInt16(bigEndian: clientAddr.sin_port))")
        fflush(stdout)
        
        // Close previous connection if any
        closeActiveClient()
        
        // Set non-blocking on client socket
        let flags = fcntl(newClientFd, F_GETFL, 0)
        _ = fcntl(newClientFd, F_SETFL, flags | O_NONBLOCK)
        
        var bufSize: Int32 = 1024 * 1024
        setsockopt(newClientFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(newClientFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(newClientFd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(newClientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        
        self.clientFd = newClientFd

        let connection = TcpClientConnection(
            clientFd: newClientFd,
            cryptoChannel: self.cryptoChannel,
            queue: self.networkQueue
        )

        connection.onMessageReceived = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.dispatchMessage(message)
            }
        }

        connection.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.closeActiveClient()
                NotificationCenter.default.post(name: .droidlinkDeviceDisconnected, object: nil)
            }
        }

        self.activeConnection = connection
        NotificationCenter.default.post(name: .droidlinkDeviceConnected, object: nil)
        ScreenMirroringManager.shared.onTcpConnected()
    }
    
    private func dispatchMessage(_ message: Droidlink_Protocol_DroidLinkMessage) {
        switch message.payload {
        case .clipboard(let clip):
            print("📋 Protobuf Clipboard received: \(clip.data.text)")
            fflush(stdout)
            NotificationCenter.default.post(name: .droidlinkClipboardReceived, object: clip)
        case .notification(let notif):
            print("🔔 Notification received: \(notif.notification.title) - \(notif.notification.text)")
            fflush(stdout)
            NotificationCenter.default.post(name: .droidlinkNotificationReceived, object: notif)
        case .file(let fileMsg):
            print("📁 File message received: \(fileMsg.operation)")
            fflush(stdout)
            if fileMsg.operation == .fileChangeEvent {
                NotificationCenter.default.post(name: .droidlinkFileChanged, object: fileMsg)
            } else if let cont = popFileContinuation() {
                cont.resume(returning: fileMsg)
            } else {
                NotificationCenter.default.post(name: .droidlinkFileReceived, object: fileMsg)
            }
        case .screen(let screenMsg):
            Task { @MainActor in
                ScreenMirroringManager.shared.handleScreenMessage(screenMsg)
            }
        case .externalDisplay(let extMsg):
            Task { @MainActor in
                ExternalDisplayManager.shared.handleIncomingMessage(extMsg)
            }
        case .system(let sys):
            if sys.event == .goodbye {
                let isManual = sys.hasError && sys.error.message == "MANUAL_DISCONNECT"
                print("👋 Peer sent GOODBYE\(isManual ? " (MANUAL_DISCONNECT)" : ""). Closing connection.")
                fflush(stdout)
                if isManual {
                    PairingStorage.isManuallyDisconnected = true
                }
                closeActiveClient()
                NotificationCenter.default.post(name: .droidlinkDeviceDisconnected, object: nil)
            } else if sys.hasError && sys.error.message == "DEVICE_STATUS" {
                if let status = DeviceStatusInfo.fromJsonString(sys.error.details) {
                    print("📱 Received Android telemetry via TCP: \(status.deviceName) (\(status.deviceModel)) - Battery: \(status.batteryLevel)%")
                    fflush(stdout)
                    NotificationCenter.default.post(name: .droidlinkDeviceStatusReceived, object: status)
                }
            } else {
                print("ℹ️ System message received via TCP: \(sys.event)")
                fflush(stdout)
            }
        default:
            print("ℹ️ Received message type: \(message.type)")
            fflush(stdout)
        }
    }
    
    /// Sends a ScreenMessage wrapped in DroidLinkMessage over TCP
    func sendScreen(message: Droidlink_Protocol_ScreenMessage) {
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .screenStream
        rootMsg.screen = message
        send(message: rootMsg)
    }

    /// Sends an ExternalDisplayMessage wrapped in DroidLinkMessage over TCP
    func sendExternalDisplay(message: Droidlink_Protocol_ExternalDisplayMessage) {
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .externalDisplay
        rootMsg.externalDisplay = message
        send(message: rootMsg)
    }

    /// Sends telemetry message to Android client over TCP
    public func sendTelemetry(_ status: DeviceStatusInfo) {
        guard clientFd >= 0, let jsonStr = status.toJsonString() else { return }
        var errMsg = Droidlink_Protocol_ErrorMessage()
        errMsg.code = .errorUnknown
        errMsg.message = "DEVICE_STATUS"
        errMsg.details = jsonStr

        var sysMsg = Droidlink_Protocol_SystemMessage()
        sysMsg.event = .sysError
        sysMsg.error = errMsg

        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .system
        rootMsg.system = sysMsg

        send(message: rootMsg)
        print("📊 Sent Mac telemetry to Android via TCP: \(status.deviceName) (\(status.deviceModel)) - \(status.batteryLevel)%")
        fflush(stdout)
    }
    
    /// Sends a Protobuf message framed and encrypted to the active client
    func send(message: Droidlink_Protocol_DroidLinkMessage) {
        let fd = self.clientFd
        guard fd >= 0 else {
            print("⚠️ Cannot send message: no active connection")
            fflush(stdout)
            return
        }
        let crypto = self.cryptoChannel
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            self.performSend(message: message, fd: fd, crypto: crypto)
        }
    }

    nonisolated private func performSend(message: Droidlink_Protocol_DroidLinkMessage, fd: Int32, crypto: CryptoChannel?) {
        guard fd >= 0 else { return }
        do {
            let serialized = try message.serializedData()
            let encrypted: Data
            if let crypto = crypto {
                encrypted = try crypto.encrypt(serialized)
            } else {
                encrypted = serialized
            }
            
            let localFramer = MessageFramer()
            let frame = try localFramer.frame(encrypted)
            frame.withUnsafeBytes { rawBuffer in
                if let ptr = rawBuffer.baseAddress {
                    var totalWritten = 0
                    let totalSize = frame.count
                    var retries = 0
                    let maxRetries = 50
                    while totalWritten < totalSize {
                        let written = Darwin.write(fd, ptr.advanced(by: totalWritten), totalSize - totalWritten)
                        if written <= 0 {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) && retries < maxRetries {
                                retries += 1
                                usleep(1000)
                                continue
                            }
                            if retries >= maxRetries {
                                print("⚠️ TCP send buffer congested; resetting client connection to preserve stream framing")
                            } else {
                                print("❌ Socket write error: \(errno)")
                            }
                            fflush(stdout)
                            DispatchQueue.main.async { [weak self] in
                                self?.closeActiveClient()
                            }
                            break
                        }
                        totalWritten += written
                        retries = 0
                    }
                }
            }
        } catch {
            print("❌ Failed to serialize/encrypt frame: \(error)")
            fflush(stdout)
        }
    }
    
    private func closeActiveClient() {
        if let conn = activeConnection {
            conn.close()
            activeConnection = nil
        }
        clientFd = -1

        ExternalDisplayManager.shared.stopExternalDisplay(notifyRemote: false)

        let toResume = drainFileContinuations()
        for continuation in toResume {
            continuation.resume(throwing: NSError(domain: "TcpServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Connection closed"]))
        }
    }

    private func addFileContinuation(_ continuation: CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>) {
        continuationLock.lock()
        pendingFileContinuations.append(continuation)
        continuationLock.unlock()
    }

    private func popFileContinuation() -> CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return pendingFileContinuations.isEmpty ? nil : pendingFileContinuations.removeFirst()
    }

    private func drainFileContinuations() -> [CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>] {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let toResume = pendingFileContinuations
        pendingFileContinuations.removeAll()
        return toResume
    }

    /// Sends a FileMessage to Android and awaits the response asynchronously with a 10s timeout
    func requestFileOperation(_ fileMsg: Droidlink_Protocol_FileMessage) async throws -> Droidlink_Protocol_FileMessage {
        guard clientFd >= 0 else {
            throw NSError(domain: "TcpServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active connection to Android"])
        }
        return try await withThrowingTaskGroup(of: Droidlink_Protocol_FileMessage.self) { group in
            group.addTask { [weak self] in
                guard let self = self else {
                    throw NSError(domain: "TcpServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server deallocated"])
                }
                return try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        self.addFileContinuation(continuation)

                        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
                        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
                        rootMsg.timestamp = rootMsg.id
                        rootMsg.type = .fileTransfer
                        rootMsg.file = fileMsg
                        self.send(message: rootMsg)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                throw NSError(domain: "TcpServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "File operation timed out"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// Sends an explicit GOODBYE Protobuf message to client and tears down the connection
    func sendGoodbyeAndStop(isManual: Bool = false) {
        if clientFd >= 0 {
            var sysMsg = Droidlink_Protocol_SystemMessage()
            sysMsg.event = .goodbye
            if isManual {
                var err = Droidlink_Protocol_ErrorMessage()
                err.code = .errorUnknown
                err.message = "MANUAL_DISCONNECT"
                sysMsg.error = err
            }
            var rootMsg = Droidlink_Protocol_DroidLinkMessage()
            rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.type = .system
            rootMsg.system = sysMsg
            send(message: rootMsg)
            usleep(50000) // 50ms buffer flush
        }
        stop()
    }
    
    /// Stops the server and cancels any open connection
    func stop() {
        closeActiveClient()
        if let source = listenSource {
            source.cancel()
            listenSource = nil
        }
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        listeningPort = 0
    }

    /// Automatically establishes ADB reverse port forwarding over USB if an ADB device is connected
    private func setupAdbReverse(port: UInt16) {
        let adbCandidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        guard let adbPath = adbCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("⚡ ADB reverse tunnel active: tcp:\(port) -> tcp:\(port)")
                    fflush(stdout)
                }
            } catch {
                // Ignore if ADB daemon not running or device not plugged in
            }
        }
    }
}