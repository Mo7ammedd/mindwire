import SwiftUI
#if targetEnvironment(macCatalyst)
import Vision
import UniformTypeIdentifiers
#else
import VisionKit
#endif

/// Keeps a scan until the camera sheet has finished dismissing. Starting a connection
/// earlier can dismiss the parent form or lose a fast validation alert in the transition.
@MainActor @Observable
final class QRScanPresentation {
    var isPresented = false
    private var pendingCode: String?

    func present() {
        guard !isPresented else { return }
        pendingCode = nil
        isPresented = true
    }

    func receive(_ code: String) {
        guard isPresented, pendingCode == nil else { return }
        pendingCode = code
        isPresented = false
    }

    func dismissed() -> String? {
        defer { pendingCode = nil }
        return pendingCode
    }
}

extension View {
    func qrScanner(_ presentation: QRScanPresentation, onScan: @escaping (String) -> Void) -> some View {
        modifier(QRScannerSheet(presentation: presentation, onScan: onScan))
    }
}

private struct QRScannerSheet: ViewModifier {
    @Bindable var presentation: QRScanPresentation
    let onScan: (String) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presentation.isPresented, onDismiss: {
            if let code = presentation.dismissed() { onScan(code) }
        }) {
            QRScanScreen(onScan: presentation.receive)
        }
    }
}

/// Reports the first QR payload to its presentation owner. Only that owner dismisses
/// a successful scan. Unsupported devices retain manual connection-link entry.
struct QRScanScreen: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    #if targetEnvironment(macCatalyst)
    @State private var importing = false
    @State private var reading = false
    @State private var error: String?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connect your computer") {
                    Text("Paste the pairing link, or open an image of its QR code.")
                        .foregroundStyle(.secondary)
                    TextField("Pairing link", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use pairing link") { onScan(code) }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reading)
                    Button("Open QR code image…", systemImage: "qrcode") { importing = true }
                        .disabled(reading)
                    if reading { ProgressView("Reading QR code…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pair a computer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                switch result {
                case .failure(let error): self.error = error.localizedDescription
                case .success(let url):
                    reading = true
                    error = nil
                    Task {
                        do {
                            let payload = try await Task.detached(priority: .userInitiated) {
                                let access = url.startAccessingSecurityScopedResource()
                                defer { if access { url.stopAccessingSecurityScopedResource() } }
                                let request = VNDetectBarcodesRequest()
                                request.symbologies = [.qr]
                                try VNImageRequestHandler(url: url).perform([request])
                                guard let payload = request.results?.first?.payloadStringValue else {
                                    throw BackendError.message("No QR code was found in this image.")
                                }
                                return payload
                            }.value
                            onScan(payload)
                        } catch { self.error = error.localizedDescription }
                        reading = false
                    }
                }
            }
        }
    }
    #else
    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if canScan {
                    Scanner(onScan: onScan)
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label(t("qr.title"), icon: .scan)
                    } description: {
                        Text(t("qr.unavailable"))
                    }
                }
            }
            .navigationTitle(t("qr.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
            }
        }
    }
    #endif
}

#if !targetEnvironment(macCatalyst)
private struct Scanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var handled = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    handled = true
                    onScan(payload)
                    break
                }
            }
        }
    }
}
#endif
