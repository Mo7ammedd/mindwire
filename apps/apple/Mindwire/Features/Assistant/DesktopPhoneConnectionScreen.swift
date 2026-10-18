import SwiftUI

#if targetEnvironment(macCatalyst)
struct DesktopPhoneConnectionScreen: View {
    static let windowID = "mindwire-connect-phone"
    @State private var model = DesktopPhoneConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mindwire.appearance") private var appearance = "system"
    @State private var removing: DesktopCLICommand.Phone?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                AppLogo(size: 38).padding(.top, 16)
                VStack(spacing: 8) {
                    Text(model.phase == .connected ? "You're connected" : "Connect your phone")
                        .font(.system(size: 24, weight: .semibold))
                    Text(model.status).font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                }
                connection.disabled(model.changing)
                if let error = model.actionError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                }
                if model.startupKnown {
                    Toggle("Start Mindwire at login", isOn: Binding(get: { model.startupEnabled }, set: model.setStartup))
                        .toggleStyle(.switch).controlSize(.small).disabled(model.changing)
                        .font(.system(size: 12))
                }
                if !model.phones.isEmpty { phones }
            }
            .padding(32).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 620, idealHeight: 700)
        .background(AssistantDesktopStyle.canvas).tint(Palette.accent)
        .background { PhoneConnectionWindowConfiguration().frame(width: 0, height: 0) }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshPhones() } }
        }
        .confirmationDialog("Disconnect \(removing?.name ?? "phone")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let phone = removing {
                Button("Disconnect phone", role: .destructive) { model.revoke(phone); removing = nil }
            }
        } message: { Text("This removes the phone's access to this computer.") }
    }

    @ViewBuilder private var connection: some View {
        switch model.phase {
        case .preparing, .saving:
            ProgressView().controlSize(.large).frame(height: 260)
        case .scanning:
            if let code = model.code {
                Image(uiImage: code).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 232, height: 232).padding(20)
                    .background(.white, in: .rect(cornerRadius: 20))
                    .accessibilityLabel("Mindwire connection QR code")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expired = model.expiresAt.map { $0 <= context.date } ?? false
                    VStack(spacing: 12) {
                        if let expiry = model.expiresAt {
                            Text(expired ? "Code expired" : "Code expires \(expiry.formatted(.relative(presentation: .numeric)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button("Copy link") { UIPasteboard.general.string = model.link }
                                .disabled(expired || model.link == nil)
                            Button("New code", action: model.start)
                        }
                        .buttonStyle(.bordered).controlSize(.regular).tint(.primary)
                    }
                }
            } else {
                Button("Show QR code", action: model.start).buttonStyle(.borderedProminent)
            }
        case .approval:
            if let approval = model.approval {
                VStack(spacing: 20) {
                    Image(systemName: "iphone").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
                    Text(approval.name).font(.system(size: 18, weight: .medium)).lineLimit(2)
                    Text("This phone will be able to use files, apps, and agents on your computer.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    DisclosureGroup("Device fingerprint") {
                        Text(approval.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.font(.system(size: 12))
                    if approval.replacements.isEmpty {
                        Button("Allow connection") { model.decide(allow: true) }.buttonStyle(.borderedProminent)
                    } else {
                        Text("A phone with this name was connected before.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Replace previous phone") { model.decide(allow: true, replace: true) }.buttonStyle(.borderedProminent)
                        Button("Add as another phone") { model.decide(allow: true) }.buttonStyle(.bordered)
                    }
                    Button("Don't allow") { model.decide(allow: false) }.buttonStyle(.bordered).tint(.primary)
                }
                .padding(24).frame(maxWidth: .infinity)
                .background(AssistantDesktopStyle.surface, in: .rect(cornerRadius: 16))
                .disabled(model.changing)
            }
        case .connected:
            Image(systemName: "checkmark.circle").font(.system(size: 64, weight: .light))
                .foregroundStyle(Palette.accent).frame(height: 160)
            Button("Connect another phone", action: model.start).buttonStyle(.bordered).tint(.primary)
        case .failed:
            Image(systemName: "iphone").font(.system(size: 52, weight: .light)).foregroundStyle(.tertiary).frame(height: 130)
            Button("Try again", action: model.start).buttonStyle(.borderedProminent)
        }
    }

    private var phones: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your phones").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refreshPhones() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Refresh phones").disabled(model.refreshing)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.phones.enumerated()), id: \.element.id) { index, phone in
                    if index > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").font(.system(size: 18)).foregroundStyle(.secondary)
                        Text(phone.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(phone.connected == true ? "Connected" : "Paired").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button { removing = phone } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).help("Disconnect \(phone.name)").disabled(model.changing)
                    }.padding(12)
                }
            }
            .background(AssistantDesktopStyle.surface, in: .rect(cornerRadius: 12))
        }
    }
}

private struct PhoneConnectionWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) {}

    final class Observer: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            scene.title = "Connect your phone"
            scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 620)
            scene.titlebar?.toolbarStyle = .unifiedCompact
        }
    }
}
#endif

struct DesktopConnectPhoneButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        #if targetEnvironment(macCatalyst)
        Button {
            openWindow(id: DesktopPhoneConnectionScreen.windowID, value: DesktopPhoneConnectionScreen.windowID)
        } label: { Label("Connect your phone", systemImage: "iphone") }
            .help("Connect your phone").accessibilityIdentifier("desktop.connectPhone")
        #else
        EmptyView()
        #endif
    }
}
