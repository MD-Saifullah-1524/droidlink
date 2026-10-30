import Foundation
@preconcurrency import FileProvider
import os.log

private let logger = Logger(subsystem: "com.droidlink.app", category: "FileProviderEnumerator")

/// Enumerator for browsing folders inside macOS Finder.
final class DroidLinkEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let ipcClient: FileProviderIPCClient

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, ipcClient: FileProviderIPCClient) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.ipcClient = ipcClient
        super.init()
    }

    func invalidate() {
        // Cleanup if needed
    }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if enumeratedItemIdentifier == .workingSet {
            // DroidLink does not track offline-pinned working set items.
            // Returning rootContainer items here causes fileproviderd hierarchy conflicts.
            observer.finishEnumerating(upTo: nil)
            return
        }

        let dirPath: String
        if enumeratedItemIdentifier == .rootContainer {
            dirPath = ""
        } else {
            dirPath = enumeratedItemIdentifier.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let pageToken: String?
        if page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage ||
            page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage ||
            page.rawValue.isEmpty {
            pageToken = nil
        } else if let tokenStr = String(data: page.rawValue, encoding: .utf8), !tokenStr.isEmpty {
            pageToken = tokenStr
        } else {
            pageToken = nil
        }

        logger.info("📂 enumerateItems starting for '\(dirPath)' (pageToken: \(pageToken ?? "none"))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                observer.finishEnumerating(upTo: nil)
                return
            }

            do {
                let (files, nextToken) = try self.ipcClient.enumDirectory(path: dirPath, pageToken: pageToken)
                let items = files.map { DroidLinkItem(fileInfo: $0) }

                logger.info("✅ enumerateItems for '\(dirPath)' got \(items.count) items (hasNext: \(nextToken != nil))")

                observer.didEnumerate(items)

                let nextPage: NSFileProviderPage?
                if let next = nextToken, let pageData = next.data(using: .utf8) {
                    nextPage = NSFileProviderPage(pageData)
                } else {
                    nextPage = nil
                }

                observer.finishEnumerating(upTo: nextPage)
            } catch {
                logger.error("❌ DroidLinkEnumerator failed for '\(dirPath)': \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchorData = "\(Date().timeIntervalSince1970)".data(using: .utf8)
        completionHandler(anchorData.map { NSFileProviderSyncAnchor($0) })
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if enumeratedItemIdentifier == .workingSet {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        let dirPath: String
        if enumeratedItemIdentifier == .rootContainer {
            dirPath = ""
        } else {
            dirPath = enumeratedItemIdentifier.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        logger.info("🔄 enumerateChanges called for '\(dirPath)'")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            do {
                let (files, _) = try self.ipcClient.enumDirectory(path: dirPath, pageToken: nil)
                let items = files.map { DroidLinkItem(fileInfo: $0) }
                observer.didUpdate(items)

                let newAnchorData = "\(Date().timeIntervalSince1970)".data(using: .utf8)!
                let newAnchor = NSFileProviderSyncAnchor(newAnchorData)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                logger.info("✅ enumerateChanges reported \(items.count) updated items for '\(dirPath)'")
            } catch {
                logger.warning("⚠️ enumerateChanges signaling syncAnchorExpired for '\(dirPath)': \(error.localizedDescription)")
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            }
        }
    }
}
