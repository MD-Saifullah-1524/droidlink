import Foundation
import SwiftProtobuf
import Darwin

/// Shared IPC layer between DroidLink host app and DroidLinkFileProvider.appex.
/// Uses a high-throughput Unix Domain Socket located in the shared App Group directory.
public final class FileProviderIPC: @unchecked Sendable {
    public static let port: UInt16 = 9995
}

// MARK: - IPC Client (used inside DroidLinkFileProvider.appex)

public final class FileProviderIPCClient: @unchecked Sendable {
    private var clientFd: Int32 = -1
    private let framer = MessageFramer()
    private let lock = NSRecursiveLock()

    // Fast in-memory cache for folder listings and metadata
    private var directoryCache: [String: (files: [Droidlink_Protocol_FileInfo], nextToken: String?, timestamp: Date)] = [:]
    private var metadataCache: [String: (info: Droidlink_Protocol_FileInfo, timestamp: Date)] = [:]
    private let cacheTTL: TimeInterval = 30.0 // 30 second cache for fast browsing without thrashing
    private let serverPort: UInt16

    private func normalizeKey(_ path: String) -> String {
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public init(port: UInt16 = FileProviderIPC.port) {
        self.serverPort = port
    }

    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        if clientFd >= 0 { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = serverPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }

        self.clientFd = fd
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if clientFd >= 0 {
            Darwin.close(clientFd)
            clientFd = -1
        }
    }

    func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        directoryCache.removeAll()
        metadataCache.removeAll()
    }

    /// Performs a synchronous or async request-response over the local domain socket.
    func sendRequest(_ request: Droidlink_Protocol_FileMessage) throws -> Droidlink_Protocol_FileMessage {
        lock.lock()
        defer { lock.unlock() }

        if clientFd < 0 {
            try connect()
        }

        let data = try request.serializedData()
        let framed = try framer.frame(data)

        var totalSent = 0
        while totalSent < framed.count {
            let written = framed.withUnsafeBytes { raw in
                Darwin.write(clientFd, raw.baseAddress! + totalSent, framed.count - totalSent)
            }
            if written <= 0 {
                Darwin.close(clientFd)
                clientFd = -1
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
            }
            totalSent += written
        }

        // Read response
        var incoming = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while true {
            let frames = try framer.deframe(from: &incoming)
            if let firstFrame = frames.first {
                return try Droidlink_Protocol_FileMessage(serializedBytes: firstFrame)
            }

            let bytesRead = Darwin.read(clientFd, &readBuf, readBuf.count)
            if bytesRead <= 0 {
                Darwin.close(clientFd)
                clientFd = -1
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET)
            }
            incoming.append(readBuf, count: bytesRead)
        }
    }

    // High-level operations

    func enumDirectory(path: String, pageToken: String?) throws -> (files: [Droidlink_Protocol_FileInfo], nextPageToken: String?) {
        let cleanPath = normalizeKey(path)
        let cacheKey = "\(cleanPath):\(pageToken ?? "")"
        lock.lock()
        if let cached = directoryCache[cacheKey], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            let res = (cached.files, cached.nextToken)
            lock.unlock()
            return res
        }
        lock.unlock()

        var req = Droidlink_Protocol_FileMessage()
        req.operation = .enumDirectoryRequest
        req.filePath = cleanPath
        if let token = pageToken {
            req.pageToken = token
        }

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        let now = Date()
        lock.lock()
        for file in resp.files {
            let itemKey = normalizeKey(file.path)
            if !itemKey.isEmpty {
                metadataCache[itemKey] = (file, now)
            }
        }
        let result = (resp.files, resp.nextPageToken.isEmpty ? nil : resp.nextPageToken)
        directoryCache[cacheKey] = (result.0, result.1, now)
        lock.unlock()
        return result
    }

    func getMetadata(path: String) throws -> Droidlink_Protocol_FileInfo? {
        let key = normalizeKey(path)
        lock.lock()
        if let cached = metadataCache[key], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            let info = cached.info
            lock.unlock()
            return info
        }
        lock.unlock()

        var req = Droidlink_Protocol_FileMessage()
        req.operation = .getMetadataRequest
        req.filePath = key

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            return nil
        }

        if let info = resp.fileInfo {
            lock.lock()
            metadataCache[key] = (info, Date())
            lock.unlock()
            return info
        }
        return nil
    }

    func readChunk(path: String, offset: Int64, chunkSize: Int32) throws -> (data: Data, isEof: Bool, totalSize: Int64) {
        var req = Droidlink_Protocol_FileMessage()
        req.operation = .readChunkRequest
        req.filePath = path
        req.offset = offset
        req.chunkSize = chunkSize

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        return (resp.fileData, resp.isEof, resp.fileSize)
    }

    public func writeChunk(path: String, offset: Int64, data: Data, isEof: Bool) throws -> Int64 {
        var req = Droidlink_Protocol_FileMessage()
        req.operation = .writeChunkRequest
        req.filePath = path
        req.offset = offset
        req.fileData = data
        req.isEof = isEof

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        lock.lock()
        metadataCache.removeValue(forKey: normalizeKey(path))
        lock.unlock()
        return resp.fileSize
    }

    func createItem(path: String, isDirectory: Bool) throws -> Droidlink_Protocol_FileInfo {
        var req = Droidlink_Protocol_FileMessage()
        req.operation = .createItemRequest
        req.filePath = path
        req.isDirectory = isDirectory

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        invalidateCache()
        return resp.fileInfo ?? Droidlink_Protocol_FileInfo()
    }

    func deleteItem(path: String) throws {
        var req = Droidlink_Protocol_FileMessage()
        req.operation = .deleteItemRequest
        req.filePath = path

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        invalidateCache()
    }

    func moveItem(sourcePath: String, targetPath: String) throws {
        var req = Droidlink_Protocol_FileMessage()
        req.operation = .moveItemRequest
        req.filePath = sourcePath
        req.targetPath = targetPath

        let resp = try sendRequest(req)
        if resp.operation == .fileError {
            throw NSError(domain: "DroidLinkFileProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage])
        }

        invalidateCache()
    }
}

// MARK: - IPC Server (used in main DroidLink.app to relay to Android)

final class FileProviderIPCServer: @unchecked Sendable {
    private var listenFd: Int32 = -1
    private var serverSource: (any DispatchSourceRead)?
    private let framer = MessageFramer()

    /// Relay closure that sends a FileMessage to Android and returns the response.
    var onFileMessageRelay: ((Droidlink_Protocol_FileMessage) async throws -> Droidlink_Protocol_FileMessage)?
    private let listeningPort: UInt16

    init(port: UInt16 = FileProviderIPC.port) {
        self.listeningPort = port
    }

    var isRunning: Bool { listenFd >= 0 }

    func start() throws {
        guard !isRunning else {
            print("📁 IPC Server already running on port \(listeningPort), skipping restart.")
            return
        }
        stop()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listeningPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EADDRINUSE)
        }

        guard Darwin.listen(fd, 32) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        self.listenFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.handleIncomingConnection()
        }
        source.resume()
        self.serverSource = source
        print("📁 FileProvider IPC Server listening on 127.0.0.1:\(FileProviderIPC.port)")
        fflush(stdout)
    }

    func stop() {
        serverSource?.cancel()
        serverSource = nil
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    private func handleIncomingConnection() {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFd, $0, &len)
            }
        }

        guard clientFd >= 0 else { return }

        Task { [weak self] in
            await self?.serviceClient(clientFd)
        }
    }

    private func serviceClient(_ clientFd: Int32) async {
        defer { Darwin.close(clientFd) }

        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while true {
            let bytesRead = Darwin.read(clientFd, &readBuf, readBuf.count)
            if bytesRead <= 0 { break }

            buffer.append(readBuf, count: bytesRead)
            let frames: [Data]
            do {
                frames = try framer.deframe(from: &buffer)
            } catch {
                print("Error deframing: \(error)")
                break
            }

            for frame in frames {
                do {
                    let req = try Droidlink_Protocol_FileMessage(serializedBytes: frame)
                    let response: Droidlink_Protocol_FileMessage

                    if let relay = onFileMessageRelay {
                        do {
                            response = try await relay(req)
                        } catch {
                            var errResp = Droidlink_Protocol_FileMessage()
                            errResp.operation = .fileError
                            errResp.errorMessage = error.localizedDescription
                            response = errResp
                        }
                    } else {
                        var errResp = Droidlink_Protocol_FileMessage()
                        errResp.operation = .fileError
                        errResp.errorMessage = "Android device not connected"
                        response = errResp
                    }

                    let respData = try response.serializedData()
                    let respFramed = try framer.frame(respData)
                    var totalSent = 0
                    while totalSent < respFramed.count {
                        let written = respFramed.withUnsafeBytes { raw in
                            Darwin.write(clientFd, raw.baseAddress! + totalSent, respFramed.count - totalSent)
                        }
                        if written <= 0 { break }
                        totalSent += written
                    }
                } catch {
                    print("Error servicing IPC request: \(error)")
                }
            }
        }
    }
}
