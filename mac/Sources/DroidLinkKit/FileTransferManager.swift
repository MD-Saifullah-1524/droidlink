import Foundation
import SwiftProtobuf
import AppKit

/// Manages incoming file transfers from Android to macOS, saving them to ~/Downloads/Droidlink
public final class FileTransferManager: @unchecked Sendable {
    public static let shared = FileTransferManager()

    private let lock = NSLock()
    private var activeHandles: [String: FileHandle] = [:]
    private var activeUrls: [String: URL] = [:]
    private var observer: (any NSObjectProtocol)?

    private init() {
        startObserving()
    }

    deinit {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Destination directory: ~/Downloads/Droidlink
    public var destinationDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let target = downloads.appendingPathComponent("Droidlink")
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return target
    }

    public func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .droidlinkFileReceived,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            guard let self = self, let fileMsg = notif.object as? Droidlink_Protocol_FileMessage else { return }
            self.handleIncomingFileMessage(fileMsg)
        }
    }

    private func sanitizeFileName(_ path: String) -> String {
        let raw = URL(fileURLWithPath: path).lastPathComponent
        let sanitized = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "file_\(Int(Date().timeIntervalSince1970))" : sanitized
    }

    private func handleIncomingFileMessage(_ fileMsg: Droidlink_Protocol_FileMessage) {
        guard fileMsg.operation == .writeChunkRequest else { return }

        let fileName = sanitizeFileName(fileMsg.filePath)
        let transferKey = fileMsg.fileID.isEmpty ? fileName : fileMsg.fileID
        let targetUrl = destinationDirectory.appendingPathComponent(fileName)

        lock.lock()
        defer { lock.unlock() }

        do {
            var handle = activeHandles[transferKey]
            if handle == nil || fileMsg.offset == 0 {
                // Prepare destination file
                if !FileManager.default.fileExists(atPath: targetUrl.path) || fileMsg.offset == 0 {
                    FileManager.default.createFile(atPath: targetUrl.path, contents: nil)
                }
                let newHandle = try FileHandle(forWritingTo: targetUrl)
                activeHandles[transferKey] = newHandle
                activeUrls[transferKey] = targetUrl
                handle = newHandle
            }

            if let handle = handle {
                try handle.seek(toOffset: UInt64(max(0, fileMsg.offset)))
                try handle.write(contentsOf: fileMsg.fileData)

                if fileMsg.isEof {
                    try handle.synchronize()
                    try handle.close()
                    activeHandles.removeValue(forKey: transferKey)
                    activeUrls.removeValue(forKey: transferKey)

                    print("✅ Saved incoming file to: \(targetUrl.path)")
                    fflush(stdout)

                    DispatchQueue.main.async {
                        NotificationManager.shared.postFileReceivedNotification(
                            fileName: fileName,
                            fileUrl: targetUrl
                        )
                    }
                }
            }
        } catch {
            print("❌ Failed writing incoming file chunk for \(fileName): \(error)")
            fflush(stdout)
            if let handle = activeHandles.removeValue(forKey: transferKey) {
                try? handle.close()
            }
            activeUrls.removeValue(forKey: transferKey)
        }
    }
}
