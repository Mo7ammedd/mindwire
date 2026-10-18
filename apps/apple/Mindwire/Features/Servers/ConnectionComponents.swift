import SwiftUI

enum ConnectionAddDestination: String, Identifiable {
    case computer, server, choose
    var id: Self { self }
    var type: ConnectionType? {
        switch self { case .computer: return .local; case .server: return .ssh; case .choose: return nil }
    }
}

/// The same native row layout as workspaces, agents and projects.
struct ConnectionDestinationRow: View {
    let type: ConnectionType
    var body: some View {
        EntityRow {
            Text(type == .local ? "Your computer" : "SSH server")
        } subtitle: {
            Text(type == .local ? "Mac, PC or laptop · scan to connect" : "Connect with an SSH key or password")
        } icon: {
            ModeIcon(type: type, size: 22)
        } accessory: {
            AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Connection {
    var displayAddress: String {
        switch self {
        case .local(let local): return local.deviceName
        case .ssh(let remote), .vps(let remote):
            return "\(remote.username)@\(remote.host)" + (remote.port == 22 ? "" : ":\(remote.port)")
        }
    }
    var pairedComputer: PairedComputer? {
        if case .local(let local) = self { return local.computer }
        return nil
    }
}

struct ComputerSetupHelpScreen: View {
    var body: some View {
        List {
            Section("First connection") {
                Text("Install Node.js, then run these commands in your computer’s terminal.")
                    .font(.subheadline).foregroundStyle(.secondary)
                command("Install & pair", "npm install -g mindwire\nmindwire connect")
                Text("Scan the QR code in Mindwire and approve your phone on the computer. You can then close that terminal; the service keeps running.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Keep connected") {
                Text("Choose automatic startup when Mindwire asks during pairing. It runs after you sign in to your computer and recovers if the tunnel drops.")
                Text("Keep your computer awake and online. Your phone can switch between Wi-Fi and mobile data; chats and terminals keep running while it reconnects.")
                Text("Automatic address recovery lets your phone find the computer even when its tunnel address changes. Mindwire retries after a dropped connection, a network change, or reopening the app. A sleeping computer becomes reachable when it wakes.")
                command("Choose your connection", "mindwire connection")
                Link("Connection options", destination: URL(string: "https://mindwire.sh/docs/guides/personal-computers")!)
            }
            Section("Secure connection") {
                Text("Your phone verifies the computer’s SSH identity and uses its approved key. The tunnel carries encrypted traffic and cannot read files, commands, or chats. Providers can see connection times, addresses, and traffic volume.")
                Text("With an Oblien tunnel, the computer’s account maintains the connection. Your phone can be signed out or use a different account; pairing approval controls access. Provider credentials stay on your computer.")
                    .foregroundStyle(.secondary)
            }
            Section("Automatic address recovery") {
                command("Cloudflare with address recovery", "mindwire connection automatic")
                Text("No Mindwire or Oblien login is needed. Pair once with QR; your computer publishes encrypted address updates and your phone uses its saved key to find it. Files, chats and terminals travel through your chosen provider.")
                    .font(.subheadline).foregroundStyle(.secondary)
                command("Keep your provider · add recovery", "mindwire discovery enable")
                Text("After enabling, open each saved phone once while its current connection works. You can self-host the directory in Mindwire Console; set its URL on the computer and your phone learns it securely when connected.")
                    .font(.subheadline).foregroundStyle(.secondary)
                command("Private directory", "mindwire discovery enable --directory-url https://your-directory.example/api/computer-directory/v1")
            }
            Section("Persistent connection options") {
                command("Oblien · sign in on your computer", "mindwire connection oblien")
                command("Cloudflare · your account and domain", "mindwire connection cloudflare")
                command("ngrok · your authtoken and reserved domain", "mindwire connection ngrok")
                command("Your VPN · reachable hostname", "mindwire connection vpn")
                command("Existing secure tunnel", "mindwire connection custom")
                Text("Oblien is optional. Provider plans and traffic limits apply. Quick Cloudflare tunnels work without an account, but their address can change after a restart.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Service commands") {
                command("Interactive controls", "mindwire")
                command("Retry the saved connection", "mindwire reconnect")
                command("Pair or repair · show a QR code", "mindwire connect pair")
                command("Start", "mindwire start")
                command("Check status & details", "mindwire status\nmindwire inspect")
                command("Automatic startup", "mindwire startup status\nmindwire startup enable")
                command("Repair automatic startup", "mindwire startup repair")
                command("Turn off automatic startup", "mindwire startup disable")
                command("Update", "npm install -g mindwire@latest\nmindwire update")
                command("Stop when idle", "mindwire stop")
                command("List paired devices", "mindwire devices")
            }
            Section {
                Text("Computer terminals run in Mindwire with your user account and shell. Leaving the screen disconnects the view; closing a terminal tab ends that shell.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Computer setup").navigationBarTitleDisplayMode(.inline)
    }

    private func command(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
        }
    }
}
