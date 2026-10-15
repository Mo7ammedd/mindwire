import XCTest
import SwiftUI
import Observation
import Vision
@testable import Mindwire

@MainActor
final class ChatFeedTests: XCTestCase {
    func testSeveralLiveFileWritesKeepLatestOutputVisible() async throws {
        let feed = FeedFixture()
        let host = UIHostingController(rootView: FeedFixtureView(feed: feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        for index in 0..<5 {
            feed.parts.append(Self.filePart(index))
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(Self.scrollView(in: host.view))
            let bottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
            XCTAssertLessThanOrEqual(scroll.contentSize.height - bottom, 60,
                                     "File operation \(index + 1) moved below the visible feed")
        }
        feed.parts.append(.init(kind: .text, text: "All five files are written. Building the app now."))
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(Self.scrollView(in: host.view))
        XCTAssertLessThanOrEqual(scroll.contentSize.height - scroll.contentOffset.y - scroll.bounds.height, 60)
        attach(host, name: "Live feed follows multiple file writes")
    }

    func testHistoryDisclosuresStartCompactAndLiveToolsCanOpen() async throws {
        let parts = (0..<3).map(Self.filePart)
        let closed = UIHostingController(rootView: TurnPartsView(parts: parts).padding(20))
        let expanded = UIHostingController(rootView:
            TurnPartsView(parts: parts, autoExpandedToolIDs: Set(parts.compactMap { $0.tool?.id })).padding(20))
        let bounds = CGSize(width: 390, height: 10000)
        let closedHeight = closed.sizeThatFits(in: bounds).height
        let expandedHeight = expanded.sizeThatFits(in: bounds).height
        XCTAssertLessThan(closedHeight, 200, "Saved file tools should show just their disclosure headers")
        XCTAssertGreaterThan(expandedHeight, closedHeight + 300, "New live tools should expose their diff")
    }

    func testShellStaysCompactEvenWhenAFirstLiveToolIDIsProvided() {
        let part = DaemonMessagePart(kind: .tool, tool: DaemonToolCall(id: "shell", name: "shell",
            output: String(repeating: "Build output\n", count: 30),
            action: DaemonToolAction(kind: "shell", shell: DaemonShellCommand(command: "swift build"))))
        let host = UIHostingController(rootView: TurnPartsView(parts: [part], isLive: true, autoExpandedToolIDs: ["shell"]).padding(20))
        XCTAssertLessThan(host.sizeThatFits(in: CGSize(width: 390, height: 10000)).height, 100,
                          "Live shell output must remain behind its disclosure")
    }

    func testRestorationShowsLatestOutputWithoutLoadingOlderHistory() async throws {
        let feed = FeedFixture()
        feed.isRestoring = true
        let host = UIHostingController(rootView: FeedFixtureView(feed: feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        feed.parts = (0..<50).map { .init(kind: .text, text: "Saved response \($0).\nAlready received before reopening.") }
        feed.revision += 1
        feed.isRestoring = false
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(Self.scrollView(in: host.view))
        XCTAssertLessThanOrEqual(scroll.contentSize.height - scroll.contentOffset.y - scroll.bounds.height, 60,
                                 "Restoration must open at the latest output")
        XCTAssertEqual(feed.olderLoads, 0, "Initial layout/prefetch must not trigger pagination")
        let visible = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(visible.contains("Saved response 49"), "The latest content must be painted, not just have a scroll offset")
        attach(host, name: "Reopened chat starts at latest output")
    }

    func testNotificationShowsLatestInTheSameCachedTranscriptWithoutRecreatingTheTable() async throws {
        let suite = "notification-feed-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults), app = AppModel(stores: stores)
        let model = stores.chatSessions.model(for: "chat")
        let parts = (0..<120).map { DaemonMessagePart(kind: .text, id: "part-\($0)",
            text: "Saved step \($0).\n\nThis is already loaded conversation history.") }
            + [.init(kind: .text, text: "LATEST ANSWER FROM THE NOTIFICATION.")]
        model.messages = [.init(id: "saved", chatId: "chat", role: .assistant,
            text: "Whole turn", createdAt: "", parts: parts)]
        app.projectsPath.append(AppRoute.chat(chatId: "chat"))
        app.rememberChatLocation("chat")
        let host = UIHostingController(rootView: NavigationStack {
            ChatTranscriptView(model: model).navigationTitle("Reading list").navigationBarTitleDisplayMode(.inline)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    Text("Message your agent…").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).glassEffect(in: .capsule).padding(16)
                }
        }.environment(\.stores, stores).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.dispose() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let table = try XCTUnwrap(Self.scrollView(in: host.view) as? UITableView)

        for index in [35, 70] {
            table.delegate?.scrollViewWillBeginDragging?(table)
            table.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            table.layoutIfNeeded()
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("LATEST ANSWER"))
            app.open(.chat("chat"), notificationID: "same-notification")
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(Self.scrollView(in: host.view) === table, "Notification positioning must not replace the feed")
            XCTAssertEqual(app.projectsPath.count, 1)
            XCTAssertTrue(app.agentsPath.isEmpty)
            XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("LATEST ANSWER"))
            XCTAssertEqual(table.numberOfRows(inSection: 0), parts.count)
        }
        attach(host, name: "Notification opens cached chat at latest")
        #if targetEnvironment(simulator)
        try ChatFeedSnapshot.image(host).pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-chat-notification-latest.png"))
        #endif
    }

    func testNotificationDuringRestorationFollowsNewOutputUntilTheReaderScrolls() async throws {
        let feed = FeedFixture()
        feed.parts = (0..<80).map { .init(kind: .text, id: "step-\($0)", text: "SAVED STEP \($0).\n\nPreviously received text.") }
        feed.isRestoring = true
        let host = UIHostingController(rootView: FeedFixtureView(feed: feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let table = try XCTUnwrap(Self.scrollView(in: host.view) as? UITableView)
        func readMiddle() {
            table.delegate?.scrollViewWillBeginDragging?(table)
            table.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
            table.layoutIfNeeded()
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
        }
        readMiddle()
        feed.latestRequestRevision += 1
        try await Task.sleep(for: .milliseconds(100))
        feed.parts.append(.init(kind: .text, id: "latest", text: "NEWEST RESTORED ANSWER."))
        feed.revision += 1
        feed.isRestoring = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("NEWEST RESTORED ANSWER"))

        readMiddle()
        try await Task.sleep(for: .milliseconds(100))
        let offset = table.contentOffset.y
        feed.revision += 1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.contentOffset.y, offset, accuracy: 1, "A late snapshot must not undo an intentional scroll")
        XCTAssertEqual(feed.olderLoads, 0)
    }

    func testLongTranscriptBuildsOnlyVisibleRowsAndTracksGrowingText() async throws {
        let feed = FeedFixture()
        feed.parts = (0..<800).map { index in
            .init(kind: .text, id: "step-\(index)", text: "Implementation step \(index).\n\n" +
                  String(repeating: "This step has a saved explanation. ", count: index % 5 + 1))
        }
        let host = UIHostingController(rootView: FeedFixtureView(feed: feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("Implementation step 799"))
        XCTAssertLessThan(feed.renderedRows.count, 50, "Opening must not build every markdown and tool row in a long run")

        // An existing text cell changes height without inserting a new row.
        for index in 0..<6 {
            feed.parts[799].text! += "\n\nMore streamed detail \(index)."
            try await Task.sleep(for: .milliseconds(35))
        }
        feed.parts[799].text! += "\n\nLATEST STREAMED LINE."
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("LATEST STREAMED LINE"))
        // A keyboard/composer size change must also follow the newly measured final cell.
        feed.viewportHeight = 320
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("LATEST STREAMED LINE"))
    }

    func testReaderPositionSurvivesLiveUpdatesAndLoadingOlderHistory() async throws {
        let feed = FeedFixture()
        func saved(_ index: Int) -> DaemonMessagePart {
            .init(kind: .text, id: "saved-\(index)", text: "SAVED RESPONSE \(index).\n\n" +
                  String(repeating: "Previously received text. ", count: index % 3 + 1))
        }
        feed.parts = (40..<100).map(saved)
        feed.olderParts = (0..<40).map(saved)
        let host = UIHostingController(rootView: FeedFixtureView(feed: feed))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("SAVED RESPONSE 99"))
        let table = try XCTUnwrap(Self.scrollView(in: host.view) as? UITableView)
        XCTAssertEqual(feed.olderLoads, 0)

        func readRow(_ index: Int) {
            table.delegate?.scrollViewWillBeginDragging?(table)
            table.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            table.layoutIfNeeded()
            table.delegate?.scrollViewDidScroll?(table)
            table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
        }
        readRow(20)
        try await Task.sleep(for: .milliseconds(100))
        let path = try XCTUnwrap(table.indexPathsForVisibleRows?.sorted().first)
        let relativeY = table.rectForRow(at: path).minY - table.contentOffset.y
        let before = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(before.contains("SAVED RESPONSE 60"), before)
        feed.parts.append(.init(kind: .text, id: "new", text: "NEW LIVE OUTPUT BELOW THE READER."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.rectForRow(at: path).minY - table.contentOffset.y, relativeY, accuracy: 1,
                       "New output must not pull a reader away from history")
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("SAVED RESPONSE 60"))
        XCTAssertEqual(feed.olderLoads, 0, "Reading the middle of a page must not request older history")

        readRow(0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(feed.olderLoads, 1, "Only a user scroll to the top requests an older page")
        XCTAssertEqual(table.numberOfRows(inSection: 0), 101)
        let restored = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(restored.contains("SAVED RESPONSE 40"), "Prepending history must retain the visible message: \(restored)")
        XCTAssertFalse(restored.contains("SAVED RESPONSE 0."), "Fetching an older page must not jump to its first message")
    }

    func testTranscriptUnderNavigationAndComposerKeepsLatestOutputVisible() async throws {
        let feed = FeedFixture()
        feed.parts = (0..<80).map { .init(kind: .text, text: "Saved response \($0).\n\nText flows under the native navigation and message controls.") }
        feed.parts.append(.init(kind: .text, text: "LATEST OUTPUT ABOVE INPUT."))
        let host = UIHostingController(rootView: NavigationStack {
            FeedFixtureView(feed: feed)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { feed.visibleFrame = $0 }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    GlassEffectContainer {
                        HStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2").frame(width: 48, height: 48).glassEffect(in: .circle)
                            HStack {
                                TextField("Message", text: .constant(""))
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                            }
                            .padding(14).glassEffect(in: .capsule)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .navigationTitle("Implementation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left") {} }
                    ToolbarItem(placement: .topBarTrailing) { Button("More", systemImage: "ellipsis") {} }
                }
        }.preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let lastImage = ChatFeedSnapshot.image(host)
        attach(lastImage, name: "Latest output above the composer")
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: lastImage).contains("LATEST OUTPUT ABOVE INPUT"),
                      "Native bar overlap must leave the newest message readable above the composer")
        let table = try XCTUnwrap(Self.scrollView(in: host.view) as? UITableView)
        let lastFrame = table.convert(table.rectForRow(at: IndexPath(row: feed.parts.count - 1, section: 0)), to: host.view)
        XCTAssertLessThanOrEqual(lastFrame.maxY, feed.visibleFrame.maxY,
                                 "The entire final row must stop above the composer, not behind or below it")
        func textField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try XCTUnwrap(textField(in: host.view))
        // A native input view exercises keyboard safe-area delivery even on a simulator whose
        // hardware keyboard is connected. No simulator preferences or private APIs are needed.
        field.inputView = UIInputView(frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: 300), inputViewStyle: .keyboard)
        XCTAssertTrue(field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(400))
        let keyboardImage = ChatFeedSnapshot.image(host)
        attach(keyboardImage, name: "Latest output above the software keyboard")
        let keyboardLastFrame = table.convert(table.rectForRow(at: IndexPath(row: feed.parts.count - 1, section: 0)), to: host.view)
        XCTAssertLessThan(feed.visibleFrame.maxY, lastFrame.maxY, "Opening the software keyboard must reduce the available transcript area")
        XCTAssertLessThanOrEqual(keyboardLastFrame.maxY, feed.visibleFrame.maxY,
                                 "Keyboard insets must keep the final row above the composer")
        XCTAssertGreaterThan(keyboardLastFrame.maxY, feed.visibleFrame.maxY - 60,
                             "The keyboard inset must not be counted twice and leave a large gap")
        host.view.endEditing(true)
        try await Task.sleep(for: .milliseconds(350))
        // Inspect the captured keyboard layout after the first-responder transition settles.
        XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: keyboardImage).contains("LATEST OUTPUT ABOVE INPUT"))
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.scrollToRow(at: IndexPath(row: 35, section: 0), at: .top, animated: false)
        table.layoutIfNeeded()
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(150))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Chat beneath native navigation and composer"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func filePart(_ index: Int) -> DaemonMessagePart {
        .init(kind: .tool, tool: DaemonToolCall(id: "file-\(index)", name: "apply_patch",
            action: DaemonToolAction(kind: "file_edit", files: [DaemonFileChange(path: "Sources/Screen\(index).swift",
                op: "add", diff: "@@ -0,0 +1,30 @@\n" + (0..<30).map { "+let value\($0) = \($0)" }.joined(separator: "\n"))])))
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func attach(_ host: UIViewController, name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        attach(image, name: name)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor @Observable
private final class FeedFixture {
    var parts: [DaemonMessagePart] = [.init(kind: .text, text: "Creating the app files.")]
    var olderParts: [DaemonMessagePart] = []
    var isRestoring = false
    var revision = 0
    var latestRequestRevision = 0
    var olderLoads = 0
    var viewportHeight: CGFloat?
    @ObservationIgnored var renderedRows: Set<ChatTranscriptRow.ID> = []
    @ObservationIgnored var visibleFrame = CGRect.zero
}

private struct FeedFixtureView: View {
    let feed: FeedFixture
    var body: some View {
        let rows = feed.parts.enumerated().map { index, part in
            ChatTranscriptRow(id: .init(messageID: part.id ?? "response-\(index)"), message: nil,
                              content: .part(part), isLive: true, isLast: index == feed.parts.count - 1,
                              animatesLiveUpdates: !feed.isRestoring, autoExpanded: true)
        }
        ChatTranscriptScrollView(rows: rows, isRunning: true, isRestoring: feed.isRestoring,
                                 restorationRevision: feed.revision, latestRequestRevision: feed.latestRequestRevision, onLoadOlder: {
            feed.olderLoads += 1
            if !feed.olderParts.isEmpty {
                try? await Task.sleep(for: .milliseconds(30))
                feed.parts.insert(contentsOf: feed.olderParts, at: 0)
                feed.olderParts = []
            }
        }) { row in
            rowContent(row)
        }
        .frame(height: feed.viewportHeight)
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private func rowContent(_ row: ChatTranscriptRow) -> some View {
        let _ = feed.renderedRows.insert(row.id)
        if case .part(let part) = row.content {
            TurnPartView(part: part, isLive: row.animatesLiveUpdates, isLast: row.isLast,
                         autoExpanded: row.autoExpanded).equatable()
        }
    }
}

/// Verify what is actually visible, not just the model's parts or a scroll view's content size.
/// A lazy row can still occupy its old frame after SwiftUI stops drawing its contents.
@MainActor
enum ChatFeedSnapshot {
    static func image(_ host: UIViewController) -> UIImage {
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    static func visibleText(in image: UIImage) throws -> String {
        let pixels = try XCTUnwrap(image.cgImage)
        var failure: Error?
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            #if !targetEnvironment(simulator)
            request.revision = VNRecognizeTextRequestRevision2
            request.usesCPUOnly = level == .accurate
            #endif
            do {
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            } catch {
                // The accurate image-analysis service can reject a CPU request
                // with InvalidTransition on a physical phone. Its native fast
                // recognizer still verifies the same pixels, not model content.
                failure = error
            }
        }
        throw failure!
    }
}
