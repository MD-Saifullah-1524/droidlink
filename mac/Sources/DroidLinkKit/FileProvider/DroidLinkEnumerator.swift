import Foundation
import FileProvider

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
        let dirPath: String
        if enumeratedItemIdentifier == .rootContainer || enumeratedItemIdentifier == .workingSet {
            dirPath = ""
        } else {
            dirPath = enumeratedItemIdentifier.rawValue
        }

        let pageToken: String?
        if page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage ||
            page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage {
            pageToken = nil
        } else {
            pageToken = String(data: page.rawValue, encoding: .utf8)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                observer.finishEnumerating(upTo: nil)
                return
            }

            do {
                let (files, nextToken) = try self.ipcClient.enumDirectory(path: dirPath, pageToken: pageToken)
                let items = files.map { DroidLinkItem(fileInfo: $0) }

                observer.didEnumerate(items)

                let nextPage: NSFileProviderPage?
                if let next = nextToken, let pageData = next.data(using: .utf8) {
                    nextPage = NSFileProviderPage(pageData)
                } else {
                    nextPage = nil
                }

                observer.finishEnumerating(upTo: nextPage)
            } catch {
                print("DroidLinkEnumerator failed: \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Live change observer updates
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
}
