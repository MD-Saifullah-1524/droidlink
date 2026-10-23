import Foundation
@preconcurrency import FileProvider
import UniformTypeIdentifiers

/// The core macOS File Provider Replicated Extension for DroidLink.
/// Integrates Android user storage (/storage/emulated/0) directly into Finder.
@objc(DroidLinkFileProviderExtension)
final class DroidLinkFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let ipcClient = FileProviderIPCClient()

    init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        try? ipcClient.connect()
    }

    func invalidate() {
        ipcClient.disconnect()
    }

    // MARK: - Item Metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completionHandler(nil, NSFileProviderError(.serverUnreachable))
                return
            }

            if identifier == .rootContainer || identifier == .workingSet {
                var rootInfo = Droidlink_Protocol_FileInfo()
                rootInfo.name = "Android (DroidLink)"
                rootInfo.path = ""
                rootInfo.isDirectory = true
                completionHandler(DroidLinkItem(fileInfo: rootInfo), nil)
                return
            }

            let path = identifier.rawValue
            do {
                if let info = try self.ipcClient.getMetadata(path: path) {
                    completionHandler(DroidLinkItem(fileInfo: info), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, error)
            }
        }

        return progress
    }

    // MARK: - On-Demand Content Materialization (Download)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let path = itemIdentifier.rawValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
                return
            }

            do {
                guard let metadata = try self.ipcClient.getMetadata(path: path) else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }

                let totalSize = metadata.size
                let manager = NSFileProviderManager(for: self.domain)
                let tempDir: URL = {
                    if let dir = try? manager?.temporaryDirectoryURL() {
                        return dir
                    }
                    if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "CFV38KGZ97.com.droidlink.app") {
                        let groupTmp = groupURL.appendingPathComponent("tmp", isDirectory: true)
                        try? FileManager.default.createDirectory(at: groupTmp, withIntermediateDirectories: true)
                        return groupTmp
                    }
                    return FileManager.default.temporaryDirectory
                }()
                let tempURL = tempDir.appendingPathComponent("dl_mat_\(UUID().uuidString)_\(metadata.name)")

                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: tempURL)

                // Adaptive chunk size:
                // For BLE transfers, smaller chunks (64 KB) prevent timeouts and packet drops.
                // For large files on fast transports, larger chunks are used.
                let chunkSize: Int32 = {
                    if totalSize <= 2 * 1024 * 1024 {
                        return 64 * 1024       // 64 KB for quick response
                    } else if totalSize <= 20 * 1024 * 1024 {
                        return 128 * 1024      // 128 KB
                    } else if totalSize <= 256 * 1024 * 1024 {
                        return 512 * 1024      // 512 KB
                    } else {
                        return 1024 * 1024     // 1 MB
                    }
                }()

                var offset: Int64 = 0
                while offset < totalSize {
                    let (data, isEof, _) = try self.ipcClient.readChunk(
                        path: path,
                        offset: offset,
                        chunkSize: chunkSize
                    )

                    if data.isEmpty && !isEof {
                        break
                    }

                    try fileHandle.write(contentsOf: data)
                    offset += Int64(data.count)

                    if totalSize > 0 {
                        progress.completedUnitCount = Int64(Double(offset) / Double(totalSize) * 100.0)
                    }

                    if isEof {
                        break
                    }
                }

                // Explicitly sync to disk and close handle BEFORE fileproviderd ingests the file
                try? fileHandle.synchronize()
                try? fileHandle.close()

                progress.completedUnitCount = 100
                let item = DroidLinkItem(fileInfo: metadata)
                completionHandler(tempURL, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }

        return progress
    }

    // MARK: - File & Directory Creation (Upload)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                return
            }

            let parentPath: String
            if itemTemplate.parentItemIdentifier == .rootContainer || itemTemplate.parentItemIdentifier == .workingSet {
                parentPath = ""
            } else {
                parentPath = itemTemplate.parentItemIdentifier.rawValue
            }

            let fullPath = parentPath.isEmpty ? itemTemplate.filename : "\(parentPath)/\(itemTemplate.filename)"
            let isDirectory = itemTemplate.contentType == .folder

            do {
                let createdInfo = try self.ipcClient.createItem(path: fullPath, isDirectory: isDirectory)

                // If contents are provided, stream upload to Android in chunks
                if let localURL = url, !isDirectory {
                    let fileHandle = try FileHandle(forReadingFrom: localURL)
                    defer { try? fileHandle.close() }

                    let localSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let chunkSize: Int = 2 * 1024 * 1024 // 2 MB upload chunks
                    var offset: Int64 = 0

                    while true {
                        let chunkData = fileHandle.readData(ofLength: chunkSize)
                        let isEof = chunkData.count < chunkSize || (offset + Int64(chunkData.count) >= Int64(localSize))
                        _ = try self.ipcClient.writeChunk(
                            path: fullPath,
                            offset: offset,
                            data: chunkData,
                            isEof: isEof
                        )
                        offset += Int64(chunkData.count)
                        if isEof || chunkData.isEmpty { break }
                    }
                }

                let finalItem = DroidLinkItem(fileInfo: createdInfo)
                completionHandler(finalItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    // MARK: - Modification (Save / Edit)

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let path = item.itemIdentifier.rawValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                return
            }

            do {
                if let localURL = newContents {
                    let fileHandle = try FileHandle(forReadingFrom: localURL)
                    defer { try? fileHandle.close() }

                    let localSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let chunkSize: Int = 2 * 1024 * 1024
                    var offset: Int64 = 0

                    while true {
                        let chunkData = fileHandle.readData(ofLength: chunkSize)
                        let isEof = chunkData.count < chunkSize || (offset + Int64(chunkData.count) >= Int64(localSize))
                        _ = try self.ipcClient.writeChunk(
                            path: path,
                            offset: offset,
                            data: chunkData,
                            isEof: isEof
                        )
                        offset += Int64(chunkData.count)
                        if isEof || chunkData.isEmpty { break }
                    }
                }

                if let updated = try self.ipcClient.getMetadata(path: path) {
                    completionHandler(DroidLinkItem(fileInfo: updated), [], false, nil)
                } else {
                    completionHandler(item, [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, error)
            }
        }

        return progress
    }

    // MARK: - Deletion

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let path = identifier.rawValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completionHandler(NSFileProviderError(.serverUnreachable))
                return
            }

            do {
                try self.ipcClient.deleteItem(path: path)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        return progress
    }

    // MARK: - Directory Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        return DroidLinkEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            ipcClient: ipcClient
        )
    }
}
