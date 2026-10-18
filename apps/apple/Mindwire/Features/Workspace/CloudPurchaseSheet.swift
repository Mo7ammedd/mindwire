import SwiftUI

/// Payment stays resumable if Safari is closed or the connection drops. Only a
/// confirmed server-side reconciliation returns a provisioned computer.
struct CloudPurchaseSheet: View {
    let computer: CloudComputer
    let onProvisioned: (String) -> Void
    @State private var message: String?
    @State private var finished = false

    var body: some View {
        Group {
            if let checkout = computer.checkout, checkout.url.scheme == "https",
               ["checkout.stripe.com", "api.oblien.com"].contains(checkout.url.host ?? "") {
                SafariView(url: checkout.url)
            } else {
                ContentUnavailableView("Preparing your computer", systemImage: "desktopcomputer",
                    description: Text("Your subscription is saved. This screen will update when the computer is ready."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text(message ?? "Waiting for payment confirmation. You can resume from Account if you close this window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .task {
            while !Task.isCancelled && !finished {
                do {
                    let current = try await CloudComputers.reconcile(computer.id)
                    if let workspace = current.workspaceId { finished = true; onProvisioned(workspace); return }
                    message = current.state == "paid" || current.state == "provisioning" ? "Payment confirmed. Preparing your Cloud Computer…" : nil
                } catch {
                    message = "Waiting for a connection. Your payment and computer are saved; retrying automatically."
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
