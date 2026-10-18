import SwiftUI
import UIKit

struct WorkspaceFileDownloadRequest: Identifiable {
    let id = UUID()
    let path: String
}

extension View {
    /// Browser rows and every file preview share the same transfer and native export picker.
    func workspaceFileDownload(_ request: Binding<WorkspaceFileDownloadRequest?>,
                               workspace: WorkspaceService) -> some View {
        sheet(item: request) { item in
            WorkspaceFileDownloadSheet(workspace: workspace, path: item.path)
        }
    }
}

private struct WorkspaceFileDownloadSheet: View {
    let workspace: WorkspaceService
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var file: DownloadedWorkspaceFile?
    @State private var received: Int64 = 0
    @State private var total: Int64?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let file {
                WorkspaceFileExportPicker(url: file.url) { dismiss() }
                .ignoresSafeArea()
            } else {
                NavigationStack {
                    Form {
                        Section {
                            Label((path as NSString).lastPathComponent, icon: .file)
                                .lineLimit(2)
                            if let error {
                                Text(error).font(.subheadline).foregroundStyle(.secondary)
                                Button(t("common.retry")) { self.error = nil; attempt += 1 }
                            } else {
                                if let total {
                                    ProgressView(value: Double(received), total: Double(max(1, total)))
                                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ProgressView(t("files.download.preparing"))
                                }
                            }
                        }
                    }
                    .navigationTitle(t("files.download"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { AppToolbarItem(placement: .cancellationAction) {
                        Button(t("common.cancel")) { dismiss() }
                    } }
                }
            }
        }
        .tint(.primary)
        .task(id: attempt) {
            guard file == nil else { return }
            received = 0; total = nil
            do {
                let prepared = try await WorkspaceFileDownload.prepare(workspace: workspace, path: path) { received, total in
                    self.received = received; self.total = total
                }
                guard !Task.isCancelled else { prepared.remove(); return }
                file = prepared
            } catch {
                if !Task.isCancelled && !error.isRequestCancellation { self.error = error.localizedDescription }
            }
        }
        .onDisappear { file?.remove() }
    }
}

/// Exports the original disk file, preserving its extension and bytes. The system owns location
/// selection, overwrite confirmation, and file-provider coordination.
private struct WorkspaceFileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(completion: @escaping () -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
    }
}
