import SwiftUI
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's native `TerminalView`. PTY bytes from a `TerminalSession`
/// are fed straight into the emulator (full ANSI parsing, scrollback, cursor — all native), and
/// the user's keystrokes are forwarded back through the session. `theme` recolors the emulator;
/// `isActive` drives focus so only the visible tab owns the keyboard.
struct WorkspaceTerminalView: View {
    let session: TerminalSession
    var theme: TerminalTheme = .default
    var fontSize: CGFloat = 13
    var isActive = true
    @State private var connectionState: TerminalConnectionState = .connected
    @State private var showingStatus = false

    var body: some View {
        NativeWorkspaceTerminalView(session: session, theme: theme, fontSize: fontSize, isActive: isActive,
                                    onConnectionChange: { connectionState = $0 })
            .overlay(alignment: .topTrailing) {
                if showingStatus { status.padding(10) }
            }
            .task(id: connectionState) {
                showingStatus = false
                switch connectionState {
                case .connected: return
                case .connecting, .reconnecting:
                    // A brief handoff stays invisible and never moves terminal content.
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                case .failed, .ended: break
                }
                guard !Task.isCancelled else { return }
                showingStatus = true
            }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch connectionState {
            case .connected: EmptyView()
            case .connecting, .reconnecting:
                ProgressView().controlSize(.mini).tint(.white)
                Text(connectionState == .connecting ? "Connecting…" : "Reconnecting…")
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.danger)
                Text(message).lineLimit(3).frame(maxWidth: 260, alignment: .leading)
                Button("Retry") { session.retryConnection() }.buttonStyle(.plain).fontWeight(.semibold)
            case .ended:
                Text("Session ended")
            }
        }
        .font(.system(size: 12)).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }
}

private struct NativeWorkspaceTerminalView: UIViewRepresentable {
    let session: TerminalSession
    var theme: TerminalTheme = .default
    var fontSize: CGFloat = 13
    var isActive: Bool = true
    var onConnectionChange: (TerminalConnectionState) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        // Explicit readable monospaced font — SwiftTerm's default renders too small.
        let term = SwiftTerm.TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        term.terminalDelegate = context.coordinator
        context.coordinator.terminal = term
        apply(theme, to: term)

        session.onOutput = { [weak term, weak coordinator = context.coordinator] data in
            guard let term else { return }
            DispatchQueue.main.async {
                coordinator?.feedingOutput = true
                term.feed(byteArray: [UInt8](data)[...])
                coordinator?.feedingOutput = false
            }
        }
        session.onConnectionChange = { [weak coordinator = context.coordinator] state in
            DispatchQueue.main.async { coordinator?.onConnectionChange(state) }
        }
        let state = session.connectionState
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.onConnectionChange(state) }
        // NOTE: we deliberately do NOT start the session here. At makeUIView time the view still
        // has a .zero frame, so SwiftTerm hasn't computed its cols/rows yet — starting now would
        // create the PTY at the 80×24 default and the shell would wrap at 80 cols regardless of the
        // real size. Instead we start on the first `sizeChanged` (below), once the true size is
        // known, so the PTY is created correctly. Live resizes after that flow through normally.
        return term
    }

    func updateUIView(_ term: SwiftTerm.TerminalView, context: Context) {
        if term.font.pointSize != fontSize {
            term.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        apply(theme, to: term)
        if isActive {
            if !term.isFirstResponder { _ = term.becomeFirstResponder() }
        } else if term.isFirstResponder {
            _ = term.resignFirstResponder()
        }
    }

    private func apply(_ theme: TerminalTheme, to term: SwiftTerm.TerminalView) {
        term.installColors(theme.ansi)
        term.nativeBackgroundColor = theme.background
        term.nativeForegroundColor = theme.foreground
        term.caretColor = theme.caret
        term.backgroundColor = theme.background
        #if targetEnvironment(macCatalyst)
        // Keep keyboard/first-responder input; only remove UIKit's rectangular focus halo.
        term.focusEffect = nil
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session, onConnectionChange: onConnectionChange) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        weak var terminal: SwiftTerm.TerminalView?
        private var didStart = false
        var feedingOutput = false
        let onConnectionChange: (TerminalConnectionState) -> Void

        init(session: TerminalSession, onConnectionChange: @escaping (TerminalConnectionState) -> Void) {
            self.session = session; self.onConnectionChange = onConnectionChange
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if feedingOutput && session.handlesDeviceQueries { return }
            session.send(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return } // ignore pre-layout 0×0 reports
            // First real size: seed the session's dimensions THEN start it, so the PTY is created
            // at the true size. Subsequent calls are ordinary live resizes.
            if !didStart {
                didStart = true
                session.resize(cols: newCols, rows: newRows)
                session.start()
            } else {
                session.resize(cols: newCols, rows: newRows)
            }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
