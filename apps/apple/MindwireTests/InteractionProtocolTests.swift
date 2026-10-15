import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class InteractionProtocolTests: XCTestCase {
    func testAsyncChoicesRemainActionableAfterResultWhileNativeControlsExpire() throws {
        let async = try InteractionFixtures.form("codex-async")
        XCTAssertTrue(async.isMessageQuestion)
        XCTAssertEqual(async.runId, "run")
        XCTAssertEqual(async.questions?.count, 2)
        XCTAssertTrue(async.displayQuestions.allSatisfy { $0.accepts(.init(text: "Another answer")) })
        var turn = LiveTurn()
        turn.apply(DaemonEvent(type: .interaction, interaction: async))
        XCTAssertFalse(turn.waitingForInput, "Native async questions must not pretend to block Codex")
        let blocking = try InteractionFixtures.form("claude-code")
        turn.apply(DaemonEvent(type: .interaction, interaction: blocking))
        XCTAssertTrue(turn.waitingForInput)
        turn.apply(DaemonEvent(type: .result, result: DaemonResultInfo(text: "Questions sent")))
        XCTAssertTrue(turn.parts[0].interaction?.needsResponse == true)
        XCTAssertFalse(turn.parts[1].interaction?.needsResponse == true)
    }

    func testAsyncQuestionsUseSheetWhileTranscriptStaysCompact() async throws {
        var form = try InteractionFixtures.form("codex-async")
        for answered in [false, true] {
            if answered {
                form.needsResponse = false
                form.response = .init(answers: ["question-1": .init(options: ["Blue"], text: "Use a soft shade"),
                                              "question-2": .init(options: ["Markdown"])])
            }
            let compact = UIHostingController(rootView: ScrollView {
                TurnPartsView(parts: [.init(kind: .interaction, interaction: form)], onOpenInteraction: { _ in })
            }.padding(16).frame(width: 390, height: 180).environment(\.colorScheme, .dark))
            let compactWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
            compactWindow.overrideUserInterfaceStyle = .dark
            compact.view.backgroundColor = .black
            compactWindow.rootViewController = compact
            compactWindow.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(120))
            let summary = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(compact))
            XCTAssertTrue(summary.contains(t(answered ? "chat.interaction.answered" : "chat.interaction.open")), summary)
            XCTAssertFalse(summary.contains("Blue"), "Choices belong in the answer sheet: \(summary)")
            compactWindow.isHidden = true

            let chat = ChatModel(chatId: "chat")
            chat.messages = [.init(id: "message", chatId: "chat", role: .assistant, text: "", createdAt: "",
                                   parts: [.init(kind: .interaction, interaction: form)])]
            let content = answered
                ? AnyView(ScrollView { InteractionView(interaction: form) })
                : AnyView(ChatInteractionSheet(model: chat, selectedID: .constant(nil)))
            let host = UIHostingController(rootView: content
                .frame(width: 390, height: 900).environment(\.colorScheme, .dark))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
            // Match UIKit's backing surface to the SwiftUI dark appearance. Otherwise
            // standalone snapshot windows render white text over a light UIView.
            window.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(120))
            let image = ChatFeedSnapshot.image(host)
            let text = try ChatFeedSnapshot.visibleText(in: image)
            for label in ["Blue", "Green", "Plain text", "Markdown"] { XCTAssertTrue(text.contains(label), text) }
            XCTAssertTrue(text.localizedCaseInsensitiveContains(answered ? "answered" : "continue while you choose"), text)
            if answered { XCTAssertTrue(text.contains("Use a soft shade"), text) }
            let attachment = XCTAttachment(image: image)
            attachment.name = answered ? "Answered async choice details" : "Pending async question sheet"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("mindwire-async-questions-\(answered ? "answered" : "pending").png"))
        }
    }

    func testPendingQuestionsUseOriginatingRunAndNewestAcknowledgement() throws {
        let chat = ChatModel(chatId: "chat")
        let original = try InteractionFixtures.form("codex-async")
        var nextRun = original
        nextRun.runId = "next-run" // Native request IDs can repeat across runs.
        let expired = try InteractionFixtures.form("claude-code")
        var unresolved = original
        unresolved.id = nil
        chat.messages = [.init(id: "message", chatId: "chat", role: .assistant, text: "", createdAt: "",
            parts: [original, original, nextRun, expired, unresolved].map { .init(kind: .interaction, interaction: $0) })]
        XCTAssertEqual(chat.pendingInteractions.map(\.id.runId), ["run", "next-run"])
        XCTAssertEqual(chat.pendingRequest(for: nextRun)?.id.runId, "next-run")

        var resolved = original
        resolved.needsResponse = false
        resolved.response = .init(answers: ["question-1": .init(options: ["Blue"])])
        chat.messages.append(.init(id: "acknowledgement", chatId: "chat", role: .assistant, text: "", createdAt: "",
                                   parts: [.init(kind: .interaction, interaction: resolved)]))
        XCTAssertEqual(chat.pendingInteractions.map(\.id.runId), ["next-run"])
        XCTAssertNil(chat.pendingRequest(for: original))
    }

    func testLegacyQuestionHistoryShowsSavedFeedbackWithoutAnInMemoryDraft() async throws {
        let question = DaemonInteraction(id: "legacy", kind: "choice", title: "Choose a format",
            options: [.init(id: "markdown", label: "Markdown")], needsResponse: false,
            response: .init(options: ["markdown"], text: "Keep the saved feedback"))
        let host = UIHostingController(rootView: InteractionView(interaction: question, showsTitle: false)
            .frame(width: 390, height: 320))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(120))
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(text.contains("Choose a format"), text)
        XCTAssertTrue(text.contains("Keep the saved feedback"), text)
        XCTAssertTrue(text.contains("Answered"), text)
    }

    func testCapturedNativeFormsPreserveQuestionIDsSelectionsAndFeedback() throws {
        for harness in ["codex", "claude-code"] {
            let interaction = try InteractionFixtures.form(harness)
            XCTAssertEqual(interaction.questions?.count, 2)
            XCTAssertEqual(interaction.displayQuestions.count, 2)
            var answers: [String: DaemonQuestionAnswer] = [:]
            for question in interaction.displayQuestions {
                let options = try XCTUnwrap(question.options)
                XCTAssertFalse(try XCTUnwrap(options.first?.description).isEmpty)
                let ids = options.prefix(question.multiSelect == true ? 2 : 1).map { $0.id ?? $0.label }
                let answer = DaemonQuestionAnswer(options: ids, text: "Preserve this feedback")
                XCTAssertTrue(question.accepts(answer))
                XCTAssertFalse(question.accepts(DaemonQuestionAnswer()))
                XCTAssertFalse(question.accepts(DaemonQuestionAnswer(options: ["not-offered"])))
                answers[question.id] = answer
            }
            let reply = DaemonInteractionReply(answers: answers)
            XCTAssertEqual(try JSONDecoder().decode(DaemonInteractionReply.self, from: JSONEncoder().encode(reply)), reply)
            if harness == "claude-code" { XCTAssertTrue(interaction.displayQuestions.contains { $0.multiSelect == true }) }
        }
        XCTAssertEqual(try JSONDecoder().decode(DaemonQuestionAnswer.self, from: Data(#"{"text":"Other"}"#.utf8)),
                       DaemonQuestionAnswer(text: "Other"))
    }

    func testGroupedAnswersAndScopedApprovalUseTheSameTransport() async throws {
        let channel = InteractionRequestChannel()
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        let reply = DaemonInteractionReply(answers: ["question-id": .init(options: ["A", "B"], text: "Keep both")])
        try await transport.respondToRun("run", interactionId: "native-request", reply: reply)
        try await transport.respondToRun("run", interactionId: "approval", reply: .init(decision: "allow_session"))
        try await transport.setPermissionMode("run", mode: "acceptEdits")
        let requests = await channel.requests
        XCTAssertEqual(requests.map(\.path), ["/runs/run/respond?agent=codex", "/runs/run/respond?agent=codex", "/runs/run/set-permission-mode?agent=codex"])
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[0].body))
        XCTAssertEqual(body["interactionId"]?.string, "native-request")
        XCTAssertEqual(body["answers"]?["question-id"]?["options"]?.array, [.string("A"), .string("B")])
        XCTAssertEqual(body["answers"]?["question-id"]?["text"]?.string, "Keep both")
        let approval = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[1].body))
        XCTAssertEqual(approval["decision"]?.string, "allow_session")
        await channel.rejectNext()
        do {
            try await transport.setPermissionMode("run", mode: "auto")
            XCTFail("A native rejection must remain an error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Native mode unavailable")) }
    }

    func testNativeSettingsKeepCanonicalPermissionKeys() throws {
        let data = Data(#"{"key":"native-mode","label":"Permissions","type":"select","canon":"permissionMode","scope":"unified","options":[{"value":"manual","label":"Ask when needed"}]}"#.utf8)
        let field = try JSONDecoder().decode(DaemonField.self, from: data)
        XCTAssertEqual(field.canon, "permissionMode")
        XCTAssertEqual(field.options?.first?.value, "manual")
    }

    func testCapturedFormsRenderAsNativeQuestionsWithFeedback() async throws {
        for harness in ["codex", "claude-code"] {
            let form = try InteractionFixtures.form(harness)
            let host = UIHostingController(rootView: ScrollView { InteractionView(interaction: form, actionable: true) }
                .frame(width: 390, height: 1000).environment(\.colorScheme, .dark))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1000))
            window.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(120))
            let image = ChatFeedSnapshot.image(host)
            let text = try ChatFeedSnapshot.visibleText(in: image)
            XCTAssertTrue(text.contains("Light"), text)
            XCTAssertTrue(text.contains("Search"), text)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("feedback"), text)
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(harness) native question form"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: FileManager.default.temporaryDirectory
                .appendingPathComponent("mindwire-\(harness)-question-form.png"))
        }
    }
}

@MainActor
enum InteractionFixtures {
    static func form(_ harness: String) throws -> DaemonInteraction {
        let url = try XCTUnwrap(Bundle(for: InteractionProtocolTests.self).url(forResource: "\(harness)-questions", withExtension: "json"))
        return try JSONDecoder().decode(DaemonInteraction.self, from: Data(contentsOf: url))
    }
}

private actor InteractionRequestChannel: DaemonChannel {
    struct Request: Sendable { let path: String; let body: Data? }
    nonisolated let label = "interaction-fixture"
    private(set) var requests: [Request] = []
    private var reject = false
    func rejectNext() { reject = true }
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        requests.append(Request(path: path, body: jsonBody))
        if reject { reject = false; return (400, #"{"error":"Native mode unavailable"}"#) }
        return (202, "")
    }
}
