import SwiftUI

/// Distribution is independent of pairing. Only advertise an app download when this build
/// supplies its real HTTPS destination; a command-line binary is not a desktop installer.
enum AssistantComputerDownload {
    static var url: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MindwireDesktopDownloadURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// A General presentation for AddServerScreen's existing pairing operation and QR scanner.
struct AssistantComputerSetup: View {
    @Binding var code: String
    let pairing: Bool
    let status: String
    let scan: () -> Void
    let connect: () -> Void
    @State private var enteringLink = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        AssistantPage {
            AssistantSetupProgress(step: 0)
            AssistantDeviceArtwork(destination: .computer)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            AssistantHeading(title: t("assistant.pair.title"))
            VStack(alignment: .leading, spacing: 20) {
                if let url = AssistantComputerDownload.url {
                    instruction(1, title: t("assistant.pair.download"))
                    HStack(spacing: 20) {
                        Button { openURL(url) } label: { Label(t("assistant.pair.getApp"), icon: .download) }
                        ShareLink(item: url) { AppIcon(.share).accessibilityLabel(t("assistant.pair.share")) }
                    }
                    .font(.subheadline.weight(.semibold)).tint(.primary).padding(.leading, 44)
                }
                instruction(AssistantComputerDownload.url == nil ? 1 : 2,
                            title: t("assistant.pair.open"), detail: t("assistant.pair.open.body"))
                Divider()
                instruction(AssistantComputerDownload.url == nil ? 2 : 3,
                            title: t("assistant.pair.scan"), detail: t("assistant.pair.scan.body"))
                DisclosureGroup("Use Terminal instead") {
                    HStack(spacing: 12) {
                        Text("mindwire connect pair").font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            UIPasteboard.general.string = "mindwire connect pair"
                        } label: { AppIcon(.copy, size: 20).frame(minWidth: 44, minHeight: 44) }
                            .tint(.primary).accessibilityLabel(t("assistant.pair.copyCommand"))
                    }
                    .padding(.leading, 16).padding(.trailing, 4)
                    .background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
                    .padding(.top, 12)
                }
                .font(.subheadline).tint(.primary)
            }
            .padding(20).background(AssistantStyle.surface.opacity(0.65), in: .rect(cornerRadius: 24))
            if enteringLink || !code.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("assistant.pair.link")).font(.subheadline.weight(.semibold))
                    TextField("mindwire://pair…", text: $code, axis: .vertical)
                        .lineLimit(1...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(16).background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
                        .accessibilityLabel(t("assistant.pair.link"))
                    Button(t("assistant.pair.connect"), action: connect)
                        .font(.headline).tint(.primary)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if pairing {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("computer-pairing-progress")
            }
        } footer: {
            AssistantPrimaryButton(title: t("assistant.pair.scan"), icon: .scan, busy: pairing, action: scan)
                .accessibilityIdentifier("computer-add-scan")
            Button(t("assistant.pair.paste")) { enteringLink = true }
                .font(.subheadline).tint(.secondary).padding(.vertical, 6)
        }
        .disabled(pairing)
    }

    private func instruction(_ number: Int, title: String, detail: String = "") -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number)).font(.subheadline.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(AssistantStyle.surface, in: .circle)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
