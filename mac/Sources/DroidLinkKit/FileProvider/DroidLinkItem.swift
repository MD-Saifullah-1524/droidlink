import Foundation
import FileProvider
import UniformTypeIdentifiers

/// Represents a file or directory inside macOS Finder backed by Android user storage.
final class DroidLinkItem: NSObject, NSFileProviderItem {
    let fileInfo: Droidlink_Protocol_FileInfo

    init(fileInfo: Droidlink_Protocol_FileInfo) {
        self.fileInfo = fileInfo
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        let path = fileInfo.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "." {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let path = fileInfo.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "." {
            return .rootContainer
        }
        if let lastSlashIndex = path.lastIndex(of: "/") {
            let parent = String(path[..<lastSlashIndex])
            if parent.isEmpty || parent == "." {
                return .rootContainer
            }
            return NSFileProviderItemIdentifier(parent)
        }
        return .rootContainer
    }

    var filename: String {
        if fileInfo.name.isEmpty {
            return URL(fileURLWithPath: fileInfo.path).lastPathComponent
        }
        return fileInfo.name
    }

    var contentType: UTType {
        if fileInfo.isDirectory {
            return .folder
        }
        if !fileInfo.mimeType.isEmpty, let utType = UTType(mimeType: fileInfo.mimeType) {
            return utType
        }
        let ext = URL(fileURLWithPath: filename).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return utType
        }
        return .data
    }

    var documentSize: NSNumber? {
        if fileInfo.isDirectory {
            return nil
        }
        return NSNumber(value: fileInfo.size)
    }

    var creationDate: Date? {
        if fileInfo.creationTime > 0 {
            return Date(timeIntervalSince1970: Double(fileInfo.creationTime) / 1000.0)
        }
        return contentModificationDate
    }

    var contentModificationDate: Date? {
        if fileInfo.modifiedTime > 0 {
            return Date(timeIntervalSince1970: Double(fileInfo.modifiedTime) / 1000.0)
        }
        return Date()
    }

    var capabilities: NSFileProviderItemCapabilities {
        if fileInfo.isReadOnly {
            return [.allowsReading]
        }
        return [
            .allowsReading,
            .allowsWriting,
            .allowsRenaming,
            .allowsDeleting,
            .allowsReparenting
        ]
    }

    var itemVersion: NSFileProviderItemVersion {
        let etagData = fileInfo.etag.data(using: .utf8) ?? Data()
        return NSFileProviderItemVersion(contentVersion: etagData, metadataVersion: etagData)
    }
}
