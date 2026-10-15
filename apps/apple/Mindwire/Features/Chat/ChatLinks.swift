import SwiftUI
import MarkdownUI

private struct ChatProjectPathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var chatProjectPath: String? {
        get { self[ChatProjectPathKey.self] }
        set { self[ChatProjectPathKey.self] = newValue }
    }
}

/// Markdown destinations belong to the chat's workspace, never the phone's filesystem.
enum ChatLinkDestination: Hashable, Identifiable {
    case web(URL)
    case file(WorkspaceFileLink)

    var id: Self { self }

    static func resolve(_ url: URL) throws -> Self {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw ChatLinkError.invalid
        }
        let scheme = parts.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            guard let host = parts.host, !host.isEmpty else { throw ChatLinkError.invalid }
            return .web(url)
        }
        if scheme == nil, parts.host != nil {
            var web = parts
            web.scheme = "https"
            guard let url = web.url else { throw ChatLinkError.invalid }
            return .web(url)
        }
        var path = parts.path
        if scheme == nil, path.hasPrefix("www."), let url = URL(string: "https://" + url.absoluteString) {
            return .web(url)
        }
        switch scheme {
        case nil: break
        case "file":
            guard parts.host == nil || parts.host == "" || parts.host == "localhost" else { throw ChatLinkError.unsupported }
        case "sandbox":
            guard parts.host == nil, path.hasPrefix("/") else { throw ChatLinkError.invalid }
        default:
            // Foundation treats `README.md:12` as a scheme. Codex uses this syntax for citations.
            let candidate = (parts.scheme ?? "") + ":" + parts.path
            guard parts.host == nil, (parts.scheme?.contains(".") == true),
                  WorkspaceFileLink.pathLocation(candidate).line != nil else { throw ChatLinkError.unsupported }
            path = candidate
        }
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ChatLinkError.invalid
        }
        let location = WorkspaceFileLink.pathLocation(path)
        let line = WorkspaceFileLink.fragmentLine(parts.fragment) ?? location.line
        return .file(WorkspaceFileLink(path: location.path, line: line))
    }
}

struct WorkspaceFileLink: Hashable {
    let path: String
    var line: Int? = nil

    private static let suffix = try! NSRegularExpression(pattern: #":([1-9][0-9]*)(?::[1-9][0-9]*)?$"#)
    private static let fragment = try! NSRegularExpression(pattern: #"^(?:L|line-)?([1-9][0-9]*)(?:C[0-9]+|-L?[0-9]+)?$"#)

    fileprivate static func pathLocation(_ path: String) -> (path: String, line: Int?) {
        let value = path as NSString
        guard let match = suffix.firstMatch(in: path, range: NSRange(location: 0, length: value.length)),
              let line = Int(value.substring(with: match.range(at: 1))) else { return (path, nil) }
        return (value.substring(to: match.range.location), line)
    }

    fileprivate static func fragmentLine(_ value: String?) -> Int? {
        guard let value, let match = fragment.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else { return nil }
        return Int((value as NSString).substring(with: match.range(at: 1)))
    }

    func resolvedPath(root: String, home: String?) throws -> String {
        let base = try Self.expandHome(root, home: home)
        let path = try Self.expandHome(path, home: home)
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        guard absolute.hasPrefix("/") else { throw ChatLinkError.missingContext }
        return Self.normalizedAbsolutePath(absolute)
    }

    /// Shorten labels only within this project; the original path stays intact for file access.
    func displayPath(relativeTo root: String?) -> String {
        guard path.hasPrefix("/"), let root, root.hasPrefix("/") else { return path }
        let base = Self.normalizedAbsolutePath(root)
        let absolute = Self.normalizedAbsolutePath(path)
        if absolute == base { return "." }
        let prefix = base == "/" ? "/" : base + "/"
        guard absolute.hasPrefix(prefix) else { return path }
        return String(absolute.dropFirst(prefix.count))
    }

    private static func normalizedAbsolutePath(_ path: String) -> String {
        // Lexical normalization only: Foundation's file URLs can expand the *phone's* home.
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func expandHome(_ path: String, home: String?) throws -> String {
        guard path.hasPrefix("~") else { return path }
        guard path == "~" || path.hasPrefix("~/"), let home, home.hasPrefix("/") else { throw ChatLinkError.missingContext }
        return home + path.dropFirst()
    }
}

enum ChatLinkError: LocalizedError {
    case invalid, unsupported, missingContext, missingFile
    var errorDescription: String? {
        switch self {
        case .invalid: t("chat.link.invalid")
        case .unsupported: t("chat.link.unsupported")
        case .missingContext: t("chat.link.workspaceMissing")
        case .missingFile: t("chat.link.fileMissing")
        }
    }
}

struct ChatLinks: ViewModifier {
    let project: Project?
    let workspace: WorkspaceService?
    var basePath: String? = nil
    @State private var destination: ChatLinkDestination?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .environment(\.chatProjectPath, basePath ?? project?.path)
            .environment(\.openURL, OpenURLAction { url in
                guard destination == nil else { return .handled }
                do { destination = try ChatLinkDestination.resolve(url) }
                catch { self.error = error.localizedDescription }
                return .handled
            })
            .sheet(item: $destination) { target in
                switch target {
                case .web(let url):
                    SafariView(url: url) { destination = nil }.ignoresSafeArea()
                        .accessibilityIdentifier("chat.link.browser")
                case .file(let link):
                    if let workspace, let basePath {
                        WorkspaceFileLinkView(workspace: workspace, link: link, project: project, basePath: basePath)
                    } else if let project {
                        if let workspace {
                            WorkspaceFileLinkView(workspace: workspace, link: link, project: project)
                        } else {
                            ProjectToolDestination(tool: .files, project: project, fileLink: link)
                        }
                    } else {
                        NavigationStack {
                            ContentUnavailableView(t("editor.loadFailed"), icon: .fileWarning,
                                                   description: Text(t("chat.link.workspaceMissing")))
                                .toolbar { AppToolbarItem(placement: .confirmationAction) {
                                    Button(t("common.done")) { destination = nil }.tint(.primary)
                                } }
                        }
                    }
                }
            }
            .alert(t("chat.link.failed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(t("common.ok"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}

/// Local Markdown images stay visible and tappable without fetching files as chat rows render.
/// Opening one uses the same bounded, zoomable image viewer as the file explorer.
struct ChatMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { ChatMarkdownImage(url: url) }
}

private struct ChatMarkdownImage: View {
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url {
            if case .web = try? ChatLinkDestination.resolve(url) {
                DefaultImageProvider.default.makeImage(url: url).onTapGesture { openURL(url) }
            } else {
                Button { openURL(url) } label: {
                    HStack(spacing: Spacing.sm) {
                        FileIcon(name: url.lastPathComponent, size: 22)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.sm)
                        Text(t("chat.link.preview")).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline).padding(Spacing.md)
                    .background(Palette.surface, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.link.image")
            }
        }
    }
}
