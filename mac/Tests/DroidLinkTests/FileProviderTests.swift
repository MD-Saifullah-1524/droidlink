import XCTest
import Foundation
import FileProvider
import UniformTypeIdentifiers
@testable import DroidLink

final class FileProviderTests: XCTestCase {

    func testFileMessageProtobufRoundtrip() throws {
        var msg = Droidlink_Protocol_FileMessage()
        msg.operation = .readChunkResponse
        msg.filePath = "Download/HugeVideo_4K.mp4"
        msg.offset = 5_000_000_000 // 5 GB offset (exceeds 4 GB / 32-bit uint limit)
        msg.fileSize = 12_000_000_000 // 12 GB file size
        msg.chunkSize = 8 * 1024 * 1024 // 8 MB chunk
        msg.fileData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        msg.isEof = false
        msg.etag = "1729000000_12000000000"

        let serialized = try msg.serializedData()
        let deserialized = try Droidlink_Protocol_FileMessage(serializedBytes: serialized)

        XCTAssertEqual(deserialized.operation, .readChunkResponse)
        XCTAssertEqual(deserialized.filePath, "Download/HugeVideo_4K.mp4")
        XCTAssertEqual(deserialized.offset, 5_000_000_000)
        XCTAssertEqual(deserialized.fileSize, 12_000_000_000)
        XCTAssertEqual(deserialized.chunkSize, 8 * 1024 * 1024)
        XCTAssertEqual(deserialized.fileData, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertFalse(deserialized.isEof)
        XCTAssertEqual(deserialized.etag, "1729000000_12000000000")
    }

    func testDroidLinkItemMetadata() throws {
        // 1. Root Container
        var rootInfo = Droidlink_Protocol_FileInfo()
        rootInfo.name = "Android"
        rootInfo.path = ""
        rootInfo.isDirectory = true
        let rootItem = DroidLinkItem(fileInfo: rootInfo)
        XCTAssertEqual(rootItem.itemIdentifier, .rootContainer)
        XCTAssertEqual(rootItem.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(rootItem.contentType, .folder)

        // 2. Child Directory
        var dcimInfo = Droidlink_Protocol_FileInfo()
        dcimInfo.name = "DCIM"
        dcimInfo.path = "DCIM"
        dcimInfo.isDirectory = true
        let dcimItem = DroidLinkItem(fileInfo: dcimInfo)
        XCTAssertEqual(dcimItem.itemIdentifier, NSFileProviderItemIdentifier("DCIM"))
        XCTAssertEqual(dcimItem.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(dcimItem.contentType, .folder)
        XCTAssertTrue(dcimItem.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(dcimItem.capabilities.contains(.allowsAddingSubItems))

        // 3. Nested File (> 4 GB)
        var fileInfo = Droidlink_Protocol_FileInfo()
        fileInfo.name = "backup.tar.gz"
        fileInfo.path = "Download/Backups/backup.tar.gz"
        fileInfo.size = 8_589_934_592 // 8 GB
        fileInfo.modifiedTime = 1729000000000
        fileInfo.isDirectory = false
        fileInfo.mimeType = "application/gzip"
        fileInfo.etag = "etag_backup_123"

        let fileItem = DroidLinkItem(fileInfo: fileInfo)
        XCTAssertEqual(fileItem.itemIdentifier, NSFileProviderItemIdentifier("Download/Backups/backup.tar.gz"))
        XCTAssertEqual(fileItem.parentItemIdentifier, NSFileProviderItemIdentifier("Download/Backups"))
        XCTAssertEqual(fileItem.filename, "backup.tar.gz")
        XCTAssertEqual(fileItem.documentSize?.int64Value, 8_589_934_592)
        XCTAssertTrue(fileItem.capabilities.contains(.allowsReading))
        XCTAssertTrue(fileItem.capabilities.contains(.allowsWriting))
        XCTAssertTrue(fileItem.capabilities.contains(.allowsDeleting))

        // 4. File with generic application/octet-stream but known extension (.pdf)
        var octetPdf = Droidlink_Protocol_FileInfo()
        octetPdf.name = "invoice.pdf"
        octetPdf.path = "Documents/invoice.pdf"
        octetPdf.mimeType = "application/octet-stream"
        let octetPdfItem = DroidLinkItem(fileInfo: octetPdf)
        XCTAssertEqual(octetPdfItem.contentType, .pdf)
    }

    func testFileProviderIPCRoundtrip() async throws {
        let testPort: UInt16 = 29995
        let server = FileProviderIPCServer(port: testPort)
        let client = FileProviderIPCClient(port: testPort)

        // Set up server mock relay
        server.onFileMessageRelay = { req in
            var resp = Droidlink_Protocol_FileMessage()
            switch req.operation {
            case .enumDirectoryRequest:
                resp.operation = .enumDirectoryResponse
                resp.filePath = req.filePath
                var item1 = Droidlink_Protocol_FileInfo()
                item1.name = "Download"
                item1.path = "Download"
                item1.isDirectory = true
                var item2 = Droidlink_Protocol_FileInfo()
                item2.name = "Documents"
                item2.path = "Documents"
                item2.isDirectory = true
                resp.files = [item1, item2]
                resp.nextPageToken = "token_page_2"

            case .readChunkRequest:
                resp.operation = .readChunkResponse
                resp.filePath = req.filePath
                resp.offset = req.offset
                resp.fileSize = 10_000_000_000
                resp.chunkSize = req.chunkSize
                resp.fileData = Data([0x01, 0x02, 0x03, 0x04])
                resp.isEof = (req.offset >= 9_990_000_000)

            default:
                resp.operation = .fileError
                resp.errorMessage = "Not mocked"
            }
            return resp
        }

        try server.start()
        defer {
            client.disconnect()
            server.stop()
        }
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms yield for socket listener ready

        // Test enumDirectory via client
        let (files, nextToken) = try client.enumDirectory(path: "", pageToken: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].name, "Download")
        XCTAssertEqual(files[1].name, "Documents")
        XCTAssertEqual(nextToken, "token_page_2")

        // Test metadata cache pre-population (should hit cache directly without server mock for getMetadata)
        let cachedDownloadInfo = try client.getMetadata(path: "Download")
        XCTAssertNotNil(cachedDownloadInfo)
        XCTAssertEqual(cachedDownloadInfo?.name, "Download")
        XCTAssertTrue(cachedDownloadInfo?.isDirectory == true)

        // Test readChunk via client with 64-bit offset (5 GB)
        let (data, isEof, totalSize) = try client.readChunk(
            path: "Download/HugeVideo.mp4",
            offset: 5_000_000_000,
            chunkSize: 8 * 1024 * 1024
        )
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(totalSize, 10_000_000_000)
        XCTAssertFalse(isEof)
    }

    @MainActor
    func testEnumeratorChangeSyncAnchor() async throws {
        let client = FileProviderIPCClient(port: 29996)
        let enumerator = DroidLinkEnumerator(enumeratedItemIdentifier: NSFileProviderItemIdentifier("DCIM"), ipcClient: client)
        
        let anchor = await withCheckedContinuation { continuation in
            enumerator.currentSyncAnchor { anchor in
                continuation.resume(returning: anchor)
            }
        }
        XCTAssertNotNil(anchor)
    }
}
