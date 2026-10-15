import XCTest
import SwiftUI
import Observation
@testable import Mindwire

@MainActor
final class ChatPresentationTests: XCTestCase {
    private func capture(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOutgoingBubblesGroupOnlyAdjacentUserMessagesAndKeepTheirText() async throws {
        let messages: [DaemonMessage] = [
            .init(id: "one", chatId: "chat", role: .user, text: "Can you improve the reading list?", createdAt: "2026-09-25T10:00:00Z"),
            .init(id: "two", chatId: "chat", role: .user, text: "And keep the current colors.", createdAt: "2026-09-25T10:00:30Z"),
            .init(id: "reply", chatId: "chat", role: .assistant, text: "I’ll keep the colors and tighten the layout.", createdAt: "2026-09-25T10:00:40Z"),
            .init(id: "three", chatId: "chat", role: .user, text: "Perfect, thanks.", createdAt: "2026-09-25T10:00:50Z")
        ]
        let rows = ChatTranscriptRow.make(messages: messages, live: nil, runID: nil)
        XCTAssertFalse(rows[0].joinsUserAbove)
        XCTAssertTrue(rows[0].joinsUserBelow)
        XCTAssertTrue(rows[1].joinsUserAbove)
        XCTAssertFalse(rows[1].joinsUserBelow)
        XCTAssertFalse(rows.last!.joinsUserAbove)
        let model = ChatModel(chatId: "chat")
        model.messages = messages
        let host = UIHostingController(rootView: NavigationStack {
            ChatTranscriptView(model: model).navigationTitle("Reading list")
                .navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 680))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.dispose() }
        try await Task.sleep(for: .milliseconds(200))
        let image = ChatFeedSnapshot.image(host)
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("reading list"), visible)
        XCTAssertTrue(visible.contains("current colors"), visible)
        capture(image, name: "User message bubbles")
    }

    func testCommandGroupingPreservesOrderAndStopsAtOtherContent() {
        let parts: [DaemonMessagePart] = [
            .init(kind: .thinking, text: "Inspect the project first."),
            command(0, legacy: true), command(1),
            fileEdit(), command(2),
            .init(kind: .text, text: "Now run the checks."),
            command(3), command(4),
            .init(kind: .interaction, interaction: .init(kind: "approval", needsResponse: true)),
            command(5)
        ]
        let groups = ChatPartGroup.make(parts)
        XCTAssertEqual(groups.flatMap(\.parts), parts, "Grouping must never remove, reorder, or rewrite daemon parts")
        XCTAssertEqual(groups.map(\.startIndex), [0, 1, 3, 4, 5, 6, 8, 9])
        XCTAssertEqual(groups.filter(\.isCommandGroup).map { $0.parts.count }, [2, 2])
        XCTAssertTrue(groups[1].startsBlock)
        XCTAssertFalse(groups[2].startsBlock, "Adjacent file/tool rows remain one activity block")
        XCTAssertTrue(groups[4].startsBlock, "Narrative needs separation from tool activity")
    }

    func testShellRecognitionUsesTheProtocolBeforeLegacyNames() {
        XCTAssertTrue(command(0, legacy: true).isShellCommand)
        XCTAssertTrue(command(0).isShellCommand)
        XCTAssertTrue(DaemonToolCall(name: "functions.exec_command", input: .object(["cmd": .string("swift test")])).isShellCommand)
        XCTAssertEqual(DaemonToolCall(name: "functions.exec_command", input: .object(["cmd": .string("swift test")])).shellCommandText, "swift test")
        XCTAssertFalse(DaemonToolCall(name: "Bash", action: .init(kind: "mcp")).isShellCommand)
        XCTAssertFalse(fileEdit().isShellCommand)
        XCTAssertFalse(DaemonMessagePart(kind: .text, tool: command(0).tool).isShellCommand)
        XCTAssertFalse(DaemonToolCall(name: "shell", action: .init(
            surface: .init(surfaceId: "desktop", operation: "capture"), kind: "shell")).isShellCommand)
    }

    func testGroupExpansionKeepsEveryCommandSeparateAndPreservesPaginationAnchors() throws {
        let parts = [command(0), command(1), fileEdit(), DaemonMessagePart(kind: .text, text: "Done.")]
        let message = saved(parts)
        let closed = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil)
        XCTAssertEqual(closed.count, 3)
        guard case .commands(let commands, let expanded) = closed[0].content else {
            return XCTFail("Consecutive commands should have one summary")
        }
        XCTAssertEqual(commands, Array(parts.prefix(2)))
        XCTAssertFalse(expanded)
        XCTAssertTrue(closed.allSatisfy { !$0.id.isCommandDetail && !$0.autoExpanded })

        let open = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil,
                                          expandedCommandGroups: [closed[0].id])
        XCTAssertEqual(open.count, 5)
        XCTAssertEqual(open[0].id, closed[0].id, "The message anchor must remain on the group header")
        XCTAssertEqual(open.filter(\.startsMessage).count, 1)
        XCTAssertEqual(open.filter { $0.id.isCommandDetail }.map(\.content), Array(parts.prefix(2)).map { .part($0) })
        XCTAssertEqual(Set(open.map(\.id)).count, open.count, "The first command and its group need distinct IDs")
        XCTAssertTrue(open.allSatisfy { !$0.autoExpanded }, "Opening a group must not open command output")

        let older = DaemonMessage(id: "older", chatId: "chat", role: .user, text: "Earlier request", createdAt: "")
        let paged = ChatTranscriptRow.make(messages: [older, message], live: nil, runID: nil,
                                           expandedCommandGroups: [closed[0].id])
        XCTAssertEqual(Array(paged.dropFirst()).map(\.id), open.map(\.id))
    }

    func testLiveCommandUpdatesKeepTheGroupIdentityAndResult() throws {
        var live = LiveTurn()
        live.parts = [command(0)]
        let initial = ChatTranscriptRow.make(messages: [], live: live, runID: "run")
        live.parts.append(command(1))
        let grouped = ChatTranscriptRow.make(messages: [], live: live, runID: "run")
        XCTAssertEqual(initial.first?.id, grouped.first?.id)
        let groupID = try XCTUnwrap(grouped.first?.id)
        let open = ChatTranscriptRow.make(messages: [], live: live, runID: "run", expandedCommandGroups: [groupID])
        live.parts[1].tool?.output = "Tests passed."
        live.parts.append(command(2))
        let updated = ChatTranscriptRow.make(messages: [], live: live, runID: "run", expandedCommandGroups: [groupID])
        XCTAssertEqual(updated.prefix(3).map(\.id), open.prefix(3).map(\.id))
        XCTAssertEqual(updated.filter { $0.id.isCommandDetail }.count, 3)
        guard case .part(let result) = updated[2].content else { return XCTFail("The second command disappeared") }
        XCTAssertEqual(result.tool?.output, "Tests passed.")
        live.parts.append(.init(kind: .text, text: "All checks passed."))
        let finished = ChatTranscriptRow.make(messages: [saved(live.parts)], live: nil, runID: nil)
        XCTAssertEqual(finished.last?.content, .part(live.parts.last!))
        XCTAssertEqual(finished.count, 2, "Completed history must keep the answer alongside the collapsed commands")
    }

    func testContextMenusUseOnlyThePressedTextReasoningToolOrCommandGroup() throws {
        let parts: [DaemonMessagePart] = [
            .init(kind: .text, text: "An earlier explanation."),
            .init(kind: .thinking, text: "Reasoning for this step only."),
            command(0, command: "swift test"), command(1, command: "git status"),
            fileEdit(),
            .init(kind: .text, text: "The selected answer only.")
        ]
        var message = saved(parts)
        // The parent turn's text deliberately differs from every part: none of its menus may use it.
        message = .init(id: message.id, chatId: message.chatId, role: .assistant,
                        text: "WHOLE CONVERSATION MUST NOT APPEAR", createdAt: "", parts: parts)
        let rows = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil)
        XCTAssertEqual(rows[0].selection?.text, "An earlier explanation.")
        XCTAssertEqual(rows[1].selection?.text, "Reasoning for this step only.")
        let grouped = try XCTUnwrap(rows[2].selection)
        XCTAssertTrue(grouped.text.contains("swift test"))
        XCTAssertTrue(grouped.text.contains("git status"))
        XCTAssertFalse(grouped.text.contains("selected answer"))
        let edit = try XCTUnwrap(rows[3].selection)
        XCTAssertTrue(edit.text.contains("Sources/LibraryView.swift"))
        XCTAssertTrue(edit.text.contains("-var results = books"))
        XCTAssertTrue(edit.text.contains("+var results = books.filter"))
        XCTAssertEqual(rows[4].selection?.text, "The selected answer only.")
        XCTAssertFalse(rows.compactMap(\.selection).contains { $0.text.contains(message.text) })

        let expanded = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil,
            expandedCommandGroups: [rows[2].id])
        let commands = expanded.filter { $0.id.isCommandDetail }.compactMap(\.selection)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].text.contains("swift test"))
        XCTAssertFalse(commands[0].text.contains("git status"), "A command menu must not include its sibling")
        XCTAssertTrue(commands[1].text.contains("git status"))
        XCTAssertFalse(commands[1].text.contains("swift test"))

        var live = LiveTurn()
        live.parts = parts
        let liveRows = ChatTranscriptRow.make(messages: [], live: live, runID: "run")
        XCTAssertEqual(liveRows.compactMap(\.selection).map(\.text), rows.compactMap(\.selection).map(\.text),
                       "Live parts and saved parts must have the same menu content")
    }

    func testContextPreviewIsBoundedWhileCopyAndSelectKeepTheEntireSelectedPart() async throws {
        let selected = "Selected block only.\n\n" + String(repeating: "Details of this block. ", count: 150)
        let message = DaemonMessage(id: "turn", chatId: "chat", role: .assistant,
            text: "OTHER PARTS MUST NOT APPEAR", createdAt: "", parts: [
                .init(kind: .text, text: "An unrelated earlier explanation."),
                .init(kind: .text, text: selected),
                .init(kind: .text, text: "An unrelated final answer.")
            ])
        let row = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil)[1]
        let selection = try XCTUnwrap(row.selection)
        XCTAssertEqual(selection.text, selected)
        XCTAssertEqual(selection.previewText.count, 1501)
        XCTAssertTrue(selection.previewText.hasSuffix("…"))
        let host = UIHostingController(rootView: ChatTranscriptSelectionPreview(selection: selection)
            .background(Color(uiColor: .secondarySystemBackground)).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 460))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        let image = ChatFeedSnapshot.image(host)
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("Selected block only"), visible)
        XCTAssertFalse(visible.contains("unrelated") || visible.contains("OTHER PARTS"), visible)
        #if targetEnvironment(simulator)
        capture(image, name: "Selected chat part preview")
        #endif
        let attachment = XCTAttachment(image: image)
        attachment.name = "Context preview contains only the pressed block"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOpeningALargeCommandGroupKeepsItsPositionAndRecyclesChildren() async throws {
        let feed = CommandFeed(parts: [.init(kind: .text, text: "Checking the project.")]
            + (0..<160).map { command($0) }
            + [.init(kind: .text, text: "All checks passed.")])
        let host = UIHostingController(rootView: CommandFeedView(feed: feed).preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let table = try XCTUnwrap(table(in: host.view))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3)
        let before = table.rectForRow(at: IndexPath(row: 1, section: 0)).minY - table.contentOffset.y

        let id = ChatTranscriptRow.ID(messageID: "turn", partIndex: 1)
        feed.setExpanded(true, id: id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 163)
        XCTAssertEqual(table.rectForRow(at: IndexPath(row: 1, section: 0)).minY - table.contentOffset.y, before, accuracy: 1)
        XCTAssertLessThan(feed.rendered.count, 35, "Expanding a long group must only construct its visible command views")
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(text.contains("160 commands"), text)
        XCTAssertFalse(text.contains("FULL COMMAND OUTPUT"), "Child outputs must remain independently collapsed")
        feed.parts[1].tool?.output = "Updated output after opening the group."
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.rectForRow(at: IndexPath(row: 1, section: 0)).minY - table.contentOffset.y, before, accuracy: 1)
        feed.setExpanded(false, id: id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3)
    }

    func testSharedChatPresentationKeepsHistoryCompactAndLiveDiffsVisible() async throws {
        let parts: [DaemonMessagePart] = [
            .init(kind: .thinking, text: "Keep the existing design and add search to the reading list.", durationMs: 2400, tokens: 1260),
            .init(kind: .text, text: "I’ll add search to the reading list and check the results."),
            command(0, command: "rg --files Sources"),
            command(1, legacy: true, command: "cat Package.swift"),
            command(2, command: "swift test"),
            .init(kind: .text, text: "The search now matches both the book title and author."),
            fileEdit(),
            .init(kind: .tool, tool: .init(id: "test-file", name: "Write", input: .object([
                "file_path": .string("Tests/LibraryTests.swift"), "content": .string("func testSearch() {\n    XCTAssertEqual(results.count, 2)\n}")
            ]))),
            .init(kind: .text, text: "**Ready to try.** All 12 tests pass.")
        ]
        for scheme in [ColorScheme.dark, .light] {
            let feed = CommandFeed(parts: parts)
            let host = UIHostingController(rootView: NavigationStack {
                CommandFeedView(feed: feed)
                    .navigationTitle("Reading list")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        HStack {
                            Image(systemName: "plus")
                            Text("Message your agent…").foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .padding(14).glassEffect(in: .capsule).padding(16)
                    }
            }.preferredColorScheme(scheme))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            let image = ChatFeedSnapshot.image(host)
            let text = try ChatFeedSnapshot.visibleText(in: image)
            XCTAssertTrue(text.contains("3 commands"), text)
            XCTAssertFalse(text.contains("rg --files Sources"), "Collapsed groups show the count only")
            XCTAssertTrue(text.contains("Ready to try"), text)
            XCTAssertFalse(text.contains("FULL COMMAND OUTPUT"), text)
            let name = "mindwire-chat-content-\(scheme == .dark ? "dark" : "light")"
            capture(image, name: name)

            feed.setExpanded(true, id: .init(messageID: "turn", partIndex: 2))
            try await Task.sleep(for: .milliseconds(200))
            let opened = ChatFeedSnapshot.image(host)
            XCTAssertFalse(try ChatFeedSnapshot.visibleText(in: opened).contains("FULL COMMAND OUTPUT"))
            capture(opened, name: "\(name)-commands")
            window.isHidden = true
        }

        let host = UIHostingController(rootView: TurnPartsView(parts: [fileEdit()], autoExpandedToolIDs: ["file"]).padding(16)
            .preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 450))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        let image = ChatFeedSnapshot.image(host)
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("results") && visible.contains("query"), visible)
        capture(image, name: "File edit presentation")

        // Capture the real chat navigation bar with both controls present and a long title.
        let suite = "chat-title-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let agent = stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: "preview"))
        let chat = stores.createChat(agentId: agent.id, projectId: "preview",
            title: "Improve the reading list with search, saved filters, and a cleaner library layout")
        let model = stores.chatSessions.model(for: chat.id)
        model.messages = [.init(id: "turn", chatId: chat.id, role: .assistant, text: "Done.", createdAt: "", parts: parts)]
        let navigation = UIHostingController(rootView: NavigationStack(path: .constant([chat.id])) {
            Color.clear.navigationTitle("Reading list")
                .navigationDestination(for: String.self) { ChatScreen(chatId: $0) }
        }.environment(\.stores, stores).environment(AppModel(stores: stores))
            .environment(\.scenePhase, .inactive).preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let navigationWindow = UIWindow(windowScene: scene)
        navigationWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        navigationWindow.rootViewController = navigation
        navigationWindow.makeKeyAndVisible()
        defer { navigationWindow.isHidden = true; model.dispose() }
        try await Task.sleep(for: .milliseconds(400))
        let titleImage = ChatFeedSnapshot.image(navigation)
        capture(titleImage, name: "Chat navigation title")
    }

    private func command(_ index: Int, legacy: Bool = false, command: String? = nil) -> DaemonMessagePart {
        let command = command ?? "printf command_\(index)"
        return .init(kind: .tool, durationMs: 1200, tool: .init(id: "command-\(index)", name: legacy ? "Bash" : "exec_command",
            input: legacy ? .object(["command": .string(command)]) : nil,
            output: "FULL COMMAND OUTPUT\n" + String(repeating: "Detailed result\n", count: 20), isError: false,
            action: legacy ? nil : .init(kind: "shell", shell: .init(command: command, exitCode: 0))))
    }

    private func fileEdit() -> DaemonMessagePart {
        .init(kind: .tool, tool: .init(id: "file", name: "apply_patch", action: .init(kind: "file_edit", files: [
            .init(path: "Sources/LibraryView.swift", op: "update", diff: "@@ -12,3 +12,4 @@\n-var results = books\n+var results = books.filter { book in\n+    book.matches(query)\n+}\n")
        ])))
    }

    private func saved(_ parts: [DaemonMessagePart]) -> DaemonMessage {
        .init(id: "turn", chatId: "chat", role: .assistant, text: "All checks passed.", createdAt: "", parts: parts)
    }

    private func table(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }
}

@MainActor @Observable
private final class CommandFeed {
    var parts: [DaemonMessagePart]
    var expanded: Set<ChatTranscriptRow.ID> = []
    var expansion: ChatTranscriptExpansion<ChatTranscriptRow.ID>?
    @ObservationIgnored var rendered: Set<ChatTranscriptRow.ID> = []

    init(parts: [DaemonMessagePart]) { self.parts = parts }
    func setExpanded(_ value: Bool, id: ChatTranscriptRow.ID) {
        expansion = .init(rowID: id)
        if value { expanded.insert(id) } else { expanded.remove(id) }
    }
}

private struct CommandFeedView: View {
    let feed: CommandFeed
    var body: some View {
        let message = DaemonMessage(id: "turn", chatId: "chat", role: .assistant, text: "Done.", createdAt: "", parts: feed.parts)
        let rows = ChatTranscriptRow.make(messages: [message], live: nil, runID: nil, expandedCommandGroups: feed.expanded)
        ChatTranscriptScrollView(rows: rows, isRunning: false, expansion: feed.expansion) { row in
            let _ = feed.rendered.insert(row.id)
            ChatTranscriptRowView(row: row, onExpandCommands: { feed.setExpanded($0, id: row.id) })
        }
    }
}
