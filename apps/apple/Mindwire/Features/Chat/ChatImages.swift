import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import QuickLook

enum ChatImageEncoding {
    static let maximumCount = 8
    static let maximumBytes = 4 * 1_024 * 1_024

    nonisolated static func prepare(_ data: Data, name: String, maximumBytes: Int = maximumBytes) throws -> DaemonAttachment {
        guard data.count <= 50 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw BackendError.message("This image couldn't be opened. Choose another photo.")
        }
        for dimension in [2048, 1600, 1280, 960, 720, 480] {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            for quality in [0.92, 0.85, 0.7, 0.55] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { break }
                // A fresh image destination excludes GPS and source photo metadata.
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length <= maximumBytes {
                    return DaemonAttachment(name: (name as NSString).deletingPathExtension + ".jpg", mime: "image/jpeg", data: encoded as Data)
                }
            }
        }
        throw BackendError.message("This image couldn't be prepared for sending. Choose a smaller photo.")
    }

    nonisolated static func thumbnail(_ attachment: DaemonAttachment) -> UIImage? {
        guard let data = attachment.data,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor @Observable
final class ChatImageDraft {
    nonisolated static let maximumFileBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumTotalBytes = 48 * 1_024 * 1_024
    struct Item: Identifiable {
        let id = UUID()
        let attachment: DaemonAttachment
    }
    var selection: [PhotosPickerItem] = []
    var items: [Item] = []
    private(set) var importing = false
    var error: String?
    var attachments: [DaemonAttachment] { items.map(\.attachment) }

    func importSelection() async {
        guard !selection.isEmpty, !importing else { return }
        let selected = selection
        selection = []
        importing = true
        defer { importing = false }
        do {
            for item in selected.prefix(max(0, ChatImageEncoding.maximumCount - items.count)) {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw BackendError.message("This photo couldn't be loaded. Try it again.")
                }
                let name = "image-\(UUID().uuidString.prefix(8)).jpg"
                let task = Task.detached(priority: .userInitiated) { try ChatImageEncoding.prepare(data, name: name) }
                let attachment = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                try append(attachment)
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func restore(_ attachments: [DaemonAttachment]) { items = attachments.map { Item(attachment: $0) } }

    func importCamera(_ image: UIImage) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let task = Task.detached(priority: .userInitiated) {
                guard let data = image.jpegData(compressionQuality: 0.95) else { throw BackendError.message("This photo couldn't be opened.") }
                return try ChatImageEncoding.prepare(data, name: "Photo.jpg")
            }
            let attachment = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            try append(attachment)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            for url in urls {
                try Task.checkCancellation()
                let task = Task.detached(priority: .userInitiated) { try Self.readFile(url) }
                let attachment = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                try append(attachment)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    nonisolated private static func readFile(_ url: URL) throws -> DaemonAttachment {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        var result: Result<DaemonAttachment, Error>?
        var coordinationError: NSError?
        // Document providers (including iCloud Drive) coordinate downloads and
        // replacement writes before exposing a consistent file to the importer.
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { file in
            result = Result {
                try Task.checkCancellation()
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
                guard info.isRegularFile == true else { throw BackendError.message("Choose a file, or compress the folder first.") }
                guard (info.fileSize ?? 0) <= maximumFileBytes else { throw BackendError.message("Choose files up to 16 MB each.") }
                let data = try Data(contentsOf: file)
                guard data.count <= maximumFileBytes else { throw BackendError.message("Choose files up to 16 MB each.") }
                let type = info.contentType ?? UTType(filenameExtension: file.pathExtension)
                let attachment = DaemonAttachment(name: file.lastPathComponent,
                    mime: type?.preferredMIMEType ?? "application/octet-stream", data: data)
                if ["heic", "heif"].contains(file.pathExtension.lowercased()) || attachment.isImage && data.count > ChatImageEncoding.maximumBytes {
                    return try ChatImageEncoding.prepare(data, name: file.lastPathComponent)
                }
                return attachment
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackendError.message("This file couldn't be opened. Try selecting it again.") }
        return try result.get()
    }

    func append(_ attachment: DaemonAttachment) throws {
        guard items.count < ChatImageEncoding.maximumCount else { throw BackendError.message("Attach up to 8 files or photos in one message.") }
        let total = items.reduce(0) { $0 + ($1.attachment.data?.count ?? $1.attachment.bytes ?? 0) }
        guard total + (attachment.data?.count ?? 0) <= Self.maximumTotalBytes else {
            throw BackendError.message("Keep the attachments in one message under 48 MB.")
        }
        items.append(Item(attachment: attachment))
    }
}

struct ChatImageThumbnail: View {
    private struct LoadID: Hashable {
        let attachment: DaemonAttachment
        let session: ObjectIdentifier?
    }
    let attachment: DaemonAttachment
    var size = CGSize(width: 80, height: 80)
    @Environment(\.chatAttachmentSession) private var session
    @State private var thumbnail: UIImage?
    @State private var content: Data?
    @State private var showingImage = false
    @State private var previewFile: AttachmentPreviewFile?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Button { Task { await open() } } label: {
            Group {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                else if attachment.isImage {
                    if loading { ProgressView().chatActivityTint() }
                    else { AppIcon(.filePicture).foregroundStyle(.secondary) }
                } else {
                    HStack(spacing: Spacing.sm) {
                        AppIcon(attachment.isAudio ? .microphone : .fileText, size: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.name ?? "File").font(.subheadline.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.bytes ?? attachment.data?.count ?? 0), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if loading { ProgressView().chatActivityTint().controlSize(.small) }
                    }
                    .padding(.horizontal, Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: attachment.isImage ? size.width : max(200, size.width), height: attachment.isImage ? size.height : 64)
            .background(.quaternary, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(attachment.name ?? (attachment.isImage ? "Image" : "File"))
        .accessibilityIdentifier("chat.attachment")
        .task(id: LoadID(attachment: attachment, session: session.map(ObjectIdentifier.init))) {
            guard attachment.isImage else { return }
            loading = true
            defer { loading = false }
            do {
                let bytes = try await ChatAttachmentContent.data(attachment, session: session)
                var image = attachment; image.data = bytes
                thumbnail = await Task.detached(priority: .userInitiated) { ChatImageEncoding.thumbnail(image) }.value
                content = bytes
            } catch { /* A thumbnail can retry when tapped after reconnecting. */ }
        }
        .sheet(isPresented: $showingImage) {
            NavigationStack {
                if let data = content, let image = UIImage(data: data) {
                    ImageViewer(image: image)
                        .navigationTitle(attachment.name ?? "Image")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { showingImage = false } } }
                }
            }
        }
        .sheet(item: $previewFile, onDismiss: { previewFile = nil }) { file in
            ChatFilePreview(url: file.url).ignoresSafeArea()
                .onDisappear { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        }
        .alert("Couldn't open attachment", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private func open() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let bytes = try await ChatAttachmentContent.data(attachment, session: session)
            if attachment.isImage { content = bytes; showingImage = true }
            else {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-preview-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = ((attachment.name ?? "Attachment") as NSString).lastPathComponent
                let url = dir.appendingPathComponent(name)
                try bytes.write(to: url, options: .atomic)
                previewFile = .init(url: url)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct ChatImageDraftStrip: View {
    @Bindable var draft: ChatImageDraft
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.md) {
                ForEach(draft.items) { item in
                    ChatImageThumbnail(attachment: item.attachment)
                        .overlay(alignment: .topTrailing) {
                            Button { draft.items.removeAll { $0.id == item.id } } label: {
                                AppIcon(.xCircle)
                                    .foregroundStyle(.white).font(.title3)
                                    .background(.black.opacity(0.7), in: Circle())
                                    .padding(4)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Remove attachment")
                        }
                }
                if draft.importing { ProgressView().chatActivityTint().frame(width: 80, height: 80) }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ChatAttachmentSessionKey: EnvironmentKey {
    static let defaultValue: DaemonSession? = nil
}
extension EnvironmentValues {
    var chatAttachmentSession: DaemonSession? {
        get { self[ChatAttachmentSessionKey.self] }
        set { self[ChatAttachmentSessionKey.self] = newValue }
    }
}

@MainActor
enum ChatAttachmentContent {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>(); cache.totalCostLimit = 32 * 1_024 * 1_024; return cache
    }()
    private static var pending: [String: Task<Data, Error>] = [:]

    static func data(_ attachment: DaemonAttachment, session: DaemonSession?) async throws -> Data {
        if let data = attachment.data { return data }
        guard let session, let id = attachment.artifactId else { throw BackendError.message("This attachment is stored on the workspace. Reconnect to open it.") }
        let key = "\(MindwireAuth.shared.user?.id ?? "signed-out"):\(session.agentId):\(id)"
        if let bytes = cache.object(forKey: key as NSString) { return bytes as Data }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await session.call { try await $0.attachmentData(id) } }
        pending[key] = task
        defer { pending[key] = nil }
        let bytes = try await task.value
        cache.setObject(bytes as NSData, forKey: key as NSString, cost: bytes.count)
        return bytes
    }
}

enum ChatAttachmentSource { case photos, camera, files, voice }

struct ChatCameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera
        picker.cameraCaptureMode = .photo; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }
    }
}

private struct AttachmentPreviewFile: Identifiable { let id = UUID(); let url: URL }
private struct ChatFilePreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(url: url, close: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
            target: context.coordinator, action: #selector(Coordinator.done))
        return UINavigationController(rootViewController: preview)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) { }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        let close: () -> Void
        init(url: URL, close: @escaping () -> Void) { self.url = url; self.close = close }
        @objc func done() { close() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
