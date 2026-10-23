import Foundation
import FileProvider
import AppKit

enum StorageMountType {
    case none
    case fileProvider
}

/// Manages mounting and lifecycle of Android storage in macOS Finder using Apple's NSFileProvider API.
/// Files remain on the Android device and are fetched on-demand directly into macOS Finder
/// under ~/Library/CloudStorage (appearing in the Finder sidebar like iCloud Drive or OneDrive).
@MainActor
final class FileProviderDomainManager: ObservableObject {
    static let shared = FileProviderDomainManager()

    @Published private(set) var isMounted: Bool = false
    @Published private(set) var currentDomainIdentifier: String?
    @Published var lastErrorMessage: String?
    @Published private(set) var mountType: StorageMountType = .none

    let ipcServer = FileProviderIPCServer()

    private init() {
        Task {
            await refreshMountStatus()
        }
    }

    /// Queries fileproviderd to check if the DroidLink FileProvider domain is already registered.
    func refreshMountStatus() async {
        do {
            let domains = try await NSFileProviderManager.domains()
            if let active = domains.first(where: { $0.identifier.rawValue.starts(with: "com.droidlink.provider") }) {
                self.currentDomainIdentifier = active.identifier.rawValue
                self.isMounted = true
                self.mountType = .fileProvider
                try? ipcServer.start()
                print("ℹ️ Found existing DroidLink FileProvider domain: \(active.displayName)")
                return
            }
        } catch {
            print("⚠️ refreshMountStatus error: \(error)")
        }

        self.isMounted = false
        self.mountType = .none
    }

    /// Mounts the Android storage directly in macOS Finder sidebar as a native CloudStorage File Provider.
    func registerDomain(deviceId: String, deviceName: String) async throws {
        let displayName = "\(deviceName) (DroidLink)"
        let domainId = NSFileProviderDomainIdentifier("com.droidlink.provider.\(deviceId)")

        print("🚀 registerDomain called for device '\(deviceName)' (id: \(deviceId))")
        fflush(stdout)

        // 1. Start IPC server so the extension can communicate with the host app / Android device
        try ipcServer.start()

        // 2. Register NSFileProviderDomain with macOS fileproviderd
        let domain = NSFileProviderDomain(identifier: domainId, displayName: displayName)
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        print("🔍 Existing FileProvider domains (\(existing.count)): \(existing.map { "\($0.identifier.rawValue) - \($0.displayName)" })")
        fflush(stdout)

        do {
            if !existing.contains(where: { $0.identifier == domainId }) {
                print("⚡ Calling NSFileProviderManager.add(domain) for '\(displayName)'...")
                fflush(stdout)
                try await NSFileProviderManager.add(domain)
                print("✅ NSFileProviderManager.add(domain) succeeded!")
                fflush(stdout)
            } else {
                print("ℹ️ Domain '\(displayName)' already registered in NSFileProviderManager")
                fflush(stdout)
            }

            self.mountType = .fileProvider
            self.currentDomainIdentifier = domainId.rawValue
            self.isMounted = true
            self.lastErrorMessage = nil
            PairingStorage.isFinderStorageEnabled = true
            print("✅ DroidLink FileProvider domain registered: \(displayName)")
            fflush(stdout)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            print("❌ registerDomain failed: \(error)")
            fflush(stdout)
            throw error
        }
    }

    /// Unmounts Android storage from macOS Finder.
    func unregisterDomain(deviceId: String) async throws {
        let domainId = NSFileProviderDomainIdentifier("com.droidlink.provider.\(deviceId)")
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Android")
        try await NSFileProviderManager.remove(domain)

        ipcServer.stop()
        self.currentDomainIdentifier = nil
        self.isMounted = false
        self.mountType = .none
        self.lastErrorMessage = nil
        PairingStorage.isFinderStorageEnabled = false
        print("🛑 DroidLink FileProvider domain unmounted from Finder.")
    }

    /// Opens the mounted Android storage folder directly in macOS Finder under ~/Library/CloudStorage.
    func revealInFinder(deviceId: String) async {
        let domainId = NSFileProviderDomainIdentifier("com.droidlink.provider.\(deviceId)")
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Android")
        
        if let manager = NSFileProviderManager(for: domain) {
            do {
                let rootURL = try await manager.getUserVisibleURL(for: .rootContainer)
                print("📂 Opening in Finder via getUserVisibleURL: \(rootURL)")
                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                return
            } catch {
                print("⚠️ getUserVisibleURL error: \(error), falling back to CloudStorage directory")
            }
        }

        // Direct check: ~/Library/CloudStorage/
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) {
            if let match = contents.first(where: { $0.contains("DroidLink") || $0.contains(deviceId) }) {
                let targetURL = cloudStorage.appendingPathComponent(match)
                print("📂 Opening in Finder from CloudStorage: \(targetURL)")
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                return
            }
        }

        // Fallback: open ~/Library/CloudStorage directly
        if FileManager.default.fileExists(atPath: cloudStorage.path) {
            NSWorkspace.shared.activateFileViewerSelecting([cloudStorage])
        }
    }
}
