import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewModel

@MainActor
final class ShareViewModel: ObservableObject {
    enum TransferStatus: Equatable {
        case loading
        case ready(fileName: String, fileSize: Int64, url: URL)
        case sending(progress: Double, bytesSent: Int64, totalBytes: Int64)
        case completed
        case error(String)
    }

    @Published var status: TransferStatus = .loading
    @Published var deviceName: String = "Android Device"

    private var activeTask: Task<Void, Never>?
    var onComplete: (() -> Void)?
    var onCancel: (() -> Void)?

    func startTransfer(fileUrl: URL, fileName: String, totalSize: Int64) {
        guard case .ready = status else { return }

        activeTask = Task {
            do {
                self.status = .sending(progress: 0.0, bytesSent: 0, totalBytes: totalSize)

                let client = FileProviderIPCClient()
                do {
                    try client.connect()
                } catch {
                    self.status = .error("DroidLink is not running. Please open DroidLink on your Mac.")
                    return
                }

                let bufferSize = 1024 * 1024 // 1 MB chunks
                let hasAccess = fileUrl.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess { fileUrl.stopAccessingSecurityScopedResource() }
                    client.disconnect()
                }

                let handle = try FileHandle(forReadingFrom: fileUrl)
                var offset: Int64 = 0

                while !Task.isCancelled {
                    let chunk = handle.readData(ofLength: bufferSize)
                    let isEof = (chunk.count < bufferSize) || (totalSize > 0 && offset + Int64(chunk.count) >= totalSize)

                    _ = try client.writeChunk(
                        path: "Downloads/DroidLink/\(fileName)",
                        offset: offset,
                        data: chunk,
                        isEof: isEof
                    )

                    offset += Int64(chunk.count)
                    let progress = totalSize > 0 ? min(1.0, Double(offset) / Double(totalSize)) : 1.0

                    self.status = .sending(
                        progress: progress,
                        bytesSent: offset,
                        totalBytes: totalSize
                    )

                    if isEof || chunk.isEmpty { break }
                }

                try? handle.close()

                if Task.isCancelled {
                    self.status = .error("Transfer was cancelled.")
                    return
                }

                self.status = .completed
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.onComplete?()
            } catch {
                self.status = .error("Transfer failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        onCancel?()
    }
}

// MARK: - ShareView (SwiftUI UI)

struct ShareView: View {
    @ObservedObject var viewModel: ShareViewModel

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "paperplane.circle.fill")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to Android")
                        .font(.headline)
                    Text("Destination: Downloads/DroidLink")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Status Body
            switch viewModel.status {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing file...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 90)

            case .ready(let name, let size, let url):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.blue)
                        Text(name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        Text(byteFormatter.string(fromByteCount: size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Cancel") {
                            viewModel.cancel()
                        }
                        .keyboardShortcut(.cancelAction)

                        Spacer()

                        Button("Send") {
                            viewModel.startTransfer(fileUrl: url, fileName: name, totalSize: size)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 8)
                }
                .frame(height: 90)

            case .sending(let progress, let sent, let total):
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(byteFormatter.string(fromByteCount: sent)) of \(byteFormatter.string(fromByteCount: total))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Cancel") {
                        viewModel.cancel()
                    }
                    .padding(.top, 4)
                }
                .frame(height: 90)

            case .completed:
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.green)
                    Text("Sent to Android!")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .frame(height: 90)

            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.red)
                    Button("Close") {
                        viewModel.cancel()
                    }
                    .padding(.top, 4)
                }
                .frame(height: 90)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

// MARK: - ShareViewController

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let viewModel = ShareViewModel()

    override func loadView() {
        let hostingView = NSHostingView(rootView: ShareView(viewModel: viewModel))
        self.view = hostingView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        viewModel.onComplete = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }

        viewModel.onCancel = { [weak self] in
            let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            self?.extensionContext?.cancelRequest(withError: error)
        }

        extractAndPrepareFile()
    }

    private func extractAndPrepareFile() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem],
              let firstItem = items.first,
              let provider = firstItem.attachments?.first else {
            viewModel.status = .error("No files selected to share.")
            return
        }

        // Identify appropriate type identifier
        let matchingIdentifier = provider.registeredTypeIdentifiers.first { id in
            id != UTType.text.identifier && id != UTType.plainText.identifier
        } ?? provider.registeredTypeIdentifiers.first ?? UTType.item.identifier

        provider.loadFileRepresentation(forTypeIdentifier: matchingIdentifier) { [weak self] url, error in
            guard let self = self else { return }

            if let error = error {
                Task { @MainActor in
                    self.viewModel.status = .error("Could not read file: \(error.localizedDescription)")
                }
                return
            }

            guard let tempUrl = url else {
                // Fallback to loadItem if loadFileRepresentation did not provide a URL
                provider.loadItem(forTypeIdentifier: matchingIdentifier, options: nil) { item, itemError in
                    if let fileUrl = item as? URL {
                        self.processFileUrl(fileUrl)
                    } else {
                        Task { @MainActor in
                            self.viewModel.status = .error("Selected item is not a supported file.")
                        }
                    }
                }
                return
            }

            // Copy to secure temporary directory inside extension sandbox so it persists during transfer
            let tempDir = FileManager.default.temporaryDirectory
            let targetCopy = tempDir.appendingPathComponent(tempUrl.lastPathComponent)
            try? FileManager.default.removeItem(at: targetCopy)
            do {
                try FileManager.default.copyItem(at: tempUrl, to: targetCopy)
                self.processFileUrl(targetCopy)
            } catch {
                self.processFileUrl(tempUrl)
            }
        }
    }

    private func processFileUrl(_ fileUrl: URL) {
        let fileName = fileUrl.lastPathComponent
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        Task { @MainActor in
            self.viewModel.status = .ready(fileName: fileName, fileSize: fileSize, url: fileUrl)
            // Auto-start transfer for frictionless AirDrop-style sharing
            self.viewModel.startTransfer(fileUrl: fileUrl, fileName: fileName, totalSize: fileSize)
        }
    }
}
