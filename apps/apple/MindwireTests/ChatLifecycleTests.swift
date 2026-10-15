import XCTest
import SwiftUI
import CryptoKit
@testable import Mindwire

/// Exercise the real model, session and HTTP protocol mapping with a controllable daemon channel.
/// No lifecycle behavior is reimplemented in the fixture; it only serves run/history/event data.
@MainActor
final class ChatLifecycleTests: XCTestCase {
    func testCachedRefreshKeepsTheListLoadingAcrossRapidBackAndReopenWithoutDuplicateReads() async throws {
        let channel = ReattachChannel(running: false, history: catchUpHistory(60))
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        defer { chat.dispose() }
        chat.viewDidAppear(viewer)
        await chat.load()
        await channel.holdHistory()
        chat.viewDidDisappear(viewer)
        chat.viewDidAppear(viewer)
        let first = Task { await chat.load() }
        try await eventually { await channel.historyReads == 2 }
        var waiters: [Task<Void, Never>] = []
        for _ in 0..<8 {
            chat.viewDidDisappear(viewer)
            XCTAssertTrue(chat.isLoadingConversation, "The row must show an in-flight cached refresh after Back")
            XCTAssertFalse(chat.isInitiallyLoading, "This is an already loaded conversation")
            chat.viewDidAppear(viewer)
            waiters.append(Task { await chat.load() })
            await Task.yield()
        }
        chat.viewDidDisappear(viewer)
        first.cancel()
        waiters.forEach { $0.cancel() }
        await channel.releaseHistory()
        await first.value
        for waiter in waiters { await waiter.value }
        XCTAssertFalse(chat.isLoadingConversation)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 2, "Navigation must join the existing request, not schedule another tail read")
    }

    func testOlderPagingFinishesWhileNewestRefreshIsStillLoading() async throws {
        let original = catchUpHistory(60)
        let updated = catchUpHistory(61)
        let channel = ReattachChannel(running: false, history: original)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.seedHistory(updated)
        await channel.holdHistory()
        let refresh = Task { await chat.load(force: true) }
        try await eventually { await channel.historyReads == 2 }
        await chat.loadOlder()
        XCTAssertTrue(chat.loadingHistory)
        XCTAssertEqual(chat.messages, Array(original.suffix(24)))
        await channel.releaseHistory()
        await refresh.value
        XCTAssertEqual(chat.messages, Array(updated.suffix(25)), "The refreshed tail must retain the older page just loaded")
        XCTAssertEqual(Set(chat.messages.map(\.id)).count, chat.messages.count)
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, Array(updated.suffix(37)), "The older cursor remains attached to the retained head")
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 4)
    }

    func testAnOlderPageSurvivesANewerRefreshAndNavigationCancellation() async throws {
        let original = catchUpHistory(60)
        let updated = catchUpHistory(61)
        let channel = ReattachChannel(running: false, history: original)
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        defer { chat.dispose() }
        chat.viewDidAppear(viewer)
        await chat.load()
        await channel.holdHistory()
        let older = Task { await chat.loadOlder() }
        try await eventually { await channel.historyReads == 2 }
        chat.viewDidDisappear(viewer)
        older.cancel()
        XCTAssertTrue(chat.isLoadingConversation)
        await channel.seedHistory(updated)
        chat.viewDidAppear(viewer)
        await chat.load()
        await chat.loadOlder() // A second scroller cannot restart the held page.
        await channel.releaseHistory()
        await older.value
        XCTAssertEqual(chat.messages, Array(updated.suffix(25)))
        XCTAssertFalse(chat.loadingOlder)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3)
    }

    func testDistantLatestHistoryWaitsForTheReaderThenJumpsWithoutAnotherDownload() async throws {
        let original = catchUpHistory(60)
        let updated = catchUpHistory(400)
        let channel = ReattachChannel(running: false, history: original)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.seedHistory(updated)
        await channel.holdHistory()
        let refresh = Task { await chat.load(force: true) }
        try await eventually { await channel.historyReads == 2 }
        await chat.loadOlder()
        let reading = chat.messages
        await channel.releaseHistory()
        await refresh.value
        XCTAssertEqual(chat.messages, reading, "A response must not pull the reader hundreds of messages forward")
        XCTAssertTrue(chat.hasNewerHistory)
        chat.revealLatestHistory()
        XCTAssertEqual(chat.messages, Array(updated.suffix(12)))
        XCTAssertFalse(chat.hasNewerHistory)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3, "Jump adopts the already downloaded latest page")
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, Array(updated.suffix(24)), "The new window must page through its own gap")
    }

    func testLateOlderPageCannotCrossTheGapAfterJumpingToLatest() async throws {
        let original = catchUpHistory(60)
        let updated = catchUpHistory(400)
        let channel = ReattachChannel(running: false, history: original)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.holdHistory()
        let older = Task { await chat.loadOlder() }
        try await eventually { await channel.historyReads == 2 }
        await channel.seedHistory(updated)
        await chat.load(force: true)
        XCTAssertTrue(chat.hasNewerHistory)
        chat.revealLatestHistory()
        await channel.releaseHistory()
        await older.value
        XCTAssertEqual(chat.messages, Array(updated.suffix(12)))
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, Array(updated.suffix(24)))
    }

    func testSendingFromOlderHistoryAdoptsTheLatestPageBeforeAppendingTheAcceptedMessage() async throws {
        let channel = ReattachChannel(running: false, history: catchUpHistory(60))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await chat.loadOlder()
        let updated = catchUpHistory(400)
        await channel.seedHistory(updated)
        await chat.load(force: true)
        XCTAssertTrue(chat.hasNewerHistory)

        let accepted = await chat.send("Continue from the newest reply")
        XCTAssertTrue(accepted)
        XCTAssertFalse(chat.hasNewerHistory)
        XCTAssertEqual(Array(chat.messages.dropLast()), Array(updated.suffix(12)))
        XCTAssertEqual(chat.messages.last?.text, "Continue from the newest reply")
        chat.setFollowingLatest(true)
        XCTAssertEqual(chat.messages.last?.text, "Continue from the newest reply",
                       "The scrolling callback must not replace an acknowledged user message with a stale page")
    }

    func testCompletingTheRunDoesNotInvalidateACommittedOlderPage() async throws {
        let original = catchUpHistory(60)
        let channel = ReattachChannel(running: true)
        await channel.seedHistory(original)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { await channel.subscriberCount == 1 }
        await channel.holdHistory()
        let older = Task { await chat.loadOlder() }
        try await eventually { await channel.historyReads == 2 }
        let final = DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "The final reply", createdAt: "2026-09-14T10:01:00Z")
        await channel.complete(.done, history: original + [final])
        try await eventually { !chat.thinking }
        await channel.releaseHistory()
        await older.value
        XCTAssertEqual(chat.messages, Array(original.suffix(24)) + [final])
        XCTAssertFalse(chat.loadingOlder)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3)
    }

    func testIdleBackgroundReturnChecksRevisionWithoutReloadingMessagesAndStillFindsNativeCLIWork() async throws {
        let history = (0..<36).map {
            DaemonMessage(id: "message-\($0)", chatId: "chat", role: .assistant,
                          text: "Retained reply \($0)", createdAt: "2026-10-07T12:00:00Z")
        }
        let channel = ReattachChannel(running: false, history: history, conditionalHistory: true)
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        defer { chat.dispose() }
        chat.viewDidAppear(viewer)
        await chat.load()
        await chat.loadOlder()
        let cached = chat.messages
        let downloads = await channel.historyDownloads
        chat.viewDidDisappear(viewer)
        chat.viewDidAppear(viewer)
        async let one: Void = chat.load()
        async let two: Void = chat.load()
        _ = await (one, two)
        XCTAssertEqual(chat.messages, cached, "An unchanged tail must retain already loaded older pages")
        let unchangedDownloads = await channel.historyDownloads
        let requests = await channel.requests
        XCTAssertEqual(unchangedDownloads, downloads)
        XCTAssertEqual(requests.filter { $0.contains("ifRevision=") }.count, 1, "Concurrent openers share one revision check")
        XCTAssertFalse(chat.thinking)
        XCTAssertFalse(chat.loadingHistory)
        XCTAssertFalse(chat.restoringRun)

        // No Mindwire run or push exists: the native CLI alone changed the file.
        chat.viewDidDisappear(viewer)
        let next = history + [DaemonMessage(id: "native-new", chatId: "chat", role: .assistant,
            text: "Finished on the Mac", createdAt: "2026-10-07T12:01:00Z")]
        await channel.seedHistory(next)
        chat.viewDidAppear(viewer)
        await chat.load()
        XCTAssertEqual(chat.messages.last?.id, "native-new")
        XCTAssertEqual(chat.messages.count, ChatHistoryPaging.limit, "A changed return uses a bounded newest window")
        let changedDownloads = await channel.historyDownloads
        XCTAssertEqual(changedDownloads, downloads + 1)
        XCTAssertTrue(chat.hasMoreHistory)
    }

    func testCompletedTurnKeepsNativeRevisionForTheNextReopen() async throws {
        let channel = ReattachChannel(running: false, conditionalHistory: true)
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        defer { chat.dispose() }
        chat.viewDidAppear(viewer)
        await chat.load()
        let sent = await chat.send("Keep working")
        XCTAssertTrue(sent)
        try await eventually { await channel.subscriberCount == 1 }
        await channel.publish(.init(type: .text, itemId: "answer", text: "Completed reply", delta: true))
        await channel.complete(.done)
        try await eventually { !chat.thinking }
        let cached = chat.messages
        let downloads = await channel.historyDownloads
        chat.viewDidDisappear(viewer)
        chat.viewDidAppear(viewer)
        await chat.load()
        XCTAssertEqual(chat.messages, cached)
        let after = await channel.historyDownloads
        XCTAssertEqual(after, downloads, "Completion already supplied the authoritative page and revision")
    }

    func testComposerDismissalPreservesReadOnlyTextSelection() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let message = UITextView(frame: CGRect(x: 20, y: 100, width: 300, height: 80))
        message.text = "Tap selection here."
        message.isEditable = false
        window.rootViewController!.view.addSubview(message)
        XCTAssertTrue(message.becomeFirstResponder())
        message.selectedRange = NSRange(location: 4, length: 9)
        var dismissed = false
        ChatKeyboardDismissal.dismiss(in: window) { dismissed = true }
        XCTAssertFalse(dismissed)
        XCTAssertTrue(message.isFirstResponder)
        XCTAssertEqual(message.selectedRange, NSRange(location: 4, length: 9))

        let composer = UITextField(frame: CGRect(x: 20, y: 300, width: 300, height: 44))
        composer.text = "Keep my draft"
        window.rootViewController!.view.addSubview(composer)
        XCTAssertTrue(composer.becomeFirstResponder())
        ChatKeyboardDismissal.dismiss(in: window) { dismissed = true }
        XCTAssertTrue(dismissed)
        XCTAssertFalse(composer.isFirstResponder)
        XCTAssertEqual(composer.text, "Keep my draft")
    }

    func testRenderedSelectionSurvivesLiveTranscriptReconfiguration() async throws {
        let fixture = try await AppStoreFixture(preloadChat: false)
        defer { fixture.close() }
        let channel = ReattachChannel(running: true, chatID: fixture.chatID)
        let chat = ChatModel(chatId: fixture.chatID, session: DaemonSession(agentId: "store-mac-codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        fixture.stores.chatSessions = ChatSessionStore(stores: fixture.stores, makeModel: { _ in chat })
        let host = UIHostingController(rootView: ChatSceneLifecycleHost(state: ChatScenePhaseFixture(), fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        try await eventually { await channel.subscriberCount == 1 }
        await channel.publish(.init(type: .text, itemId: "answer", text: "Tap **selection** here.", delta: true))
        func selectedText(in root: UIView) -> SelectableChatTextView? {
            if let view = root as? SelectableChatTextView, view.text.hasPrefix("Tap selection") { return view }
            return root.subviews.lazy.compactMap { selectedText(in: $0) }.first
        }
        try await eventually { selectedText(in: host.view) != nil }
        let text = try XCTUnwrap(selectedText(in: host.view))
        XCTAssertTrue(text.becomeFirstResponder())
        let selected = NSRange(location: 4, length: 9)
        text.selectedRange = selected
        await channel.publish(.init(type: .text, itemId: "answer", text: " More streamed output.", delta: true))
        try await eventually { chat.transcriptLive?.parts.contains { $0.text?.contains("More streamed output.") == true } == true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(selectedText(in: host.view) === text, "New output must not replace the text being selected")
        XCTAssertTrue(text.isFirstResponder)
        XCTAssertEqual(text.selectedRange, selected, "The same visible word remains selected as output grows")
        text.resignFirstResponder()
        try await eventually { selectedText(in: host.view)?.text.contains("More streamed output.") == true }
    }

    func testTemporaryInactiveSceneKeepsLiveMessagesAndOnlyBackgroundDetaches() async throws {
        let fixture = try await AppStoreFixture(preloadChat: false)
        defer { fixture.close() }
        let channel = ReattachChannel(running: true, chatID: fixture.chatID)
        let chat = ChatModel(chatId: fixture.chatID, session: DaemonSession(agentId: "store-mac-codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        fixture.stores.chatSessions = ChatSessionStore(stores: fixture.stores, makeModel: { _ in chat })
        let state = ChatScenePhaseFixture()
        let host = UIHostingController(rootView: ChatSceneLifecycleHost(state: state, fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        try await eventually {
            let subscribers = await channel.subscriberCount
            return chat.thinking && !chat.catchingUp && chat.transcriptLive != nil && subscribers == 1
        }
        await channel.publish(.init(type: .text, itemId: "answer", text: "Work is continuing", delta: true))
        try await eventually { chat.transcriptLive?.parts.contains { $0.text == "Work is continuing" } == true }
        let presentation = chat.presentationID
        let reads = await channel.historyReads
        let opens = await channel.opens
        let table = try XCTUnwrap(transcriptTable(in: host.view))

        state.phase = .inactive // Notification Center, a call, or an in-progress system gesture
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(chat.presentationID, presentation)
        XCTAssertFalse(chat.catchingUp, "A visible transcript must not switch to Loading latest")
        XCTAssertNotNil(chat.transcriptLive, "Live output must remain visible under a brief overlay")
        XCTAssertTrue(transcriptTable(in: host.view) === table)
        await channel.publish(.init(type: .text, itemId: "answer", text: " while inactive", delta: true))
        try await eventually { chat.transcriptLive?.parts.contains { $0.text?.contains("while inactive") == true } == true }
        let attachment = XCTAttachment(image: ChatFeedSnapshot.image(host))
        attachment.name = "Live messages remain visible during a temporary inactive scene"
        attachment.lifetime = .keepAlways
        add(attachment)
        state.phase = .active
        try await Task.sleep(for: .milliseconds(100))
        let inactiveReads = await channel.historyReads
        let inactiveOpens = await channel.opens
        XCTAssertEqual(inactiveReads, reads)
        XCTAssertEqual(inactiveOpens, opens, "A temporary overlay must not rebuild the stream")
        XCTAssertEqual(chat.presentationID, presentation)

        state.phase = .background
        try await eventually { await channel.subscriberCount == 0 }
        let cancellations = await channel.cancels
        XCTAssertEqual(cancellations, 0, "Closing the app detaches its viewer; it never sends Stop")
        await channel.publish(.init(type: .text, itemId: "answer", text: " and in the background", delta: true))
        await channel.holdReplay()
        state.phase = .active
        try await eventually { chat.catchingUp }
        XCTAssertTrue(chat.transcriptLive?.text.contains("while inactive") == true,
                      "Returning must retain the last visible assistant reply")
        await channel.releaseReplay()
        try await eventually { !chat.catchingUp && chat.transcriptLive?.parts.contains { $0.text?.contains("in the background") == true } == true }
        try await eventually { await channel.opens == opens + 1 }
        let reopened = await channel.opens
        XCTAssertEqual(reopened, opens + 1, "Returning from the background attaches exactly once")
        XCTAssertNotEqual(chat.presentationID, presentation)
        XCTAssertTrue(chat.thinking)
        let reopenedReads = await channel.historyReads
        XCTAssertEqual(reopenedReads, reads, "The same active run resumes events without refetching its unchanged history")
    }

    func testRejectedSendKeepsDraftWithoutSentBubbleOrInertStop() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.rejectSend()
        let sent = await chat.send("Keep this draft")
        XCTAssertFalse(sent)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.submitting)
        XCTAssertFalse(chat.thinking)
        XCTAssertNil(chat.live)
        XCTAssertEqual(chat.lastFailedInput, "Keep this draft")
        XCTAssertTrue(chat.turnError?.contains("another client") == true)
        let current = await channel.current
        XCTAssertNil(current)
    }

    func testPendingAdmissionIsSingleFlightAndStopWorksAfterAcknowledgement() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.holdSend()
        let send = Task { await chat.send("Build an app") }
        try await eventually { await channel.current != nil }
        XCTAssertTrue(chat.submitting)
        XCTAssertTrue(chat.messages.isEmpty, "An unacknowledged request must not appear sent")
        XCTAssertFalse(chat.thinking, "There is no cancellable run ID before acknowledgement")
        let duplicate = await chat.send("Build an app")
        XCTAssertFalse(duplicate)
        await channel.releaseSend()
        let accepted = await send.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(chat.submitting)
        XCTAssertTrue(chat.thinking)
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
        let cancels = await channel.cancels
        let requests = await channel.requests.filter { $0.hasPrefix("POST /turns") }
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(requests.count, 1)
    }

    func testStopThenSendWaitsForDelayedCancellationAndKeepsFreshRunActive() async throws {
        let channel = ReattachChannel(running: true)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.holdCancel()
        let stop = Task { await chat.cancel() }
        try await eventually { chat.cancelling && !chat.thinking }
        let premature = await chat.send("Next task")
        XCTAssertFalse(premature, "An old cancellation must settle before a new send")
        await channel.releaseCancel()
        await stop.value
        XCTAssertFalse(chat.cancelling)
        let next = await chat.send("Next task")
        XCTAssertTrue(next)
        XCTAssertTrue(chat.thinking)
        XCTAssertFalse(chat.submittingInput)
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
    }

    func testStopDismissesNativeAndAsyncQuestionsAndDoesNotHideTheNextRun() async throws {
        for fixture in ["codex", "claude-code", "codex-async"] {
            let channel = ReattachChannel(running: true)
            let form = try InteractionFixtures.form(fixture)
            await channel.publish(DaemonEvent(type: .interaction, interaction: form))
            let harness = fixture == "claude-code" ? "claude-code" : "codex"
            let chat = model(channel, agent: harness, activity: ChatActivityStore())
            defer { chat.dispose() }
            await chat.load()
            try await eventually { chat.pendingInteractions.count == 1 }
            await channel.holdCancel()
            let stop = Task { await chat.cancel() }
            try await eventually { chat.cancelling }
            XCTAssertTrue(chat.pendingInteractions.isEmpty, "Stop hides the pinned question immediately")
            await chat.respond(to: form, answer: .init(text: "Stale answer"))
            let responses = await channel.responseBodies.count
            XCTAssertEqual(responses, 0, "An open answer sheet must not submit after Stop")
            await channel.releaseCancel()
            await stop.value
            XCTAssertTrue(chat.pendingInteractions.isEmpty)
            chat.dispose()

            // This fixture deliberately retains the old daemon's needsResponse flag.
            // A fresh model must respect the authoritative cancelled run as well.
            let reopened = model(channel, agent: harness, activity: ChatActivityStore())
            defer { reopened.dispose() }
            await reopened.load()
            XCTAssertTrue(reopened.pendingInteractions.isEmpty, "Reopening cannot revive a stopped prompt")
            XCTAssertFalse(reopened.messages.isEmpty, "Stopping keeps the conversation history")
            let sent = await reopened.send("Next task")
            XCTAssertTrue(sent)
            var next = form
            if next.isMessageQuestion { next.runId = reopened.activeRunID }
            await channel.publish(DaemonEvent(type: .interaction, interaction: next))
            try await eventually { reopened.pendingInteractions.count == 1 }
            XCTAssertEqual(reopened.pendingInteractions.first?.id.runId, reopened.activeRunID)
            await reopened.cancel()
        }
    }

    func testRejectedStopKeepsTheQuestionAnswerable() async throws {
        let channel = ReattachChannel(running: true)
        let form = try InteractionFixtures.form("codex-async")
        await channel.publish(DaemonEvent(type: .interaction, interaction: form))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.pendingInteractions.count == 1 }
        await channel.rejectNextCancel()
        await chat.cancel()
        XCTAssertTrue(chat.thinking)
        XCTAssertFalse(chat.cancelling)
        XCTAssertEqual(chat.pendingInteractions.count, 1)
        XCTAssertNotNil(chat.turnError)
        await chat.cancel()
        XCTAssertTrue(chat.pendingInteractions.isEmpty)
    }

    func testLateQuestionReplyFailureCannotRestoreUIAfterStop() async throws {
        let channel = ReattachChannel(running: true)
        let form = try InteractionFixtures.form("codex-async")
        await channel.publish(DaemonEvent(type: .interaction, interaction: form))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.pendingInteractions.count == 1 }
        await channel.holdResponse(fail: true)
        let answer = Task { await chat.respond(to: form, answer: .init(text: "Blue")) }
        try await eventually { await channel.responseBodies.count == 1 }
        await chat.cancel()
        await channel.releaseResponse()
        await answer.value
        XCTAssertFalse(chat.thinking)
        XCTAssertTrue(chat.pendingInteractions.isEmpty)
        XCTAssertNil(chat.turnError, "A reply from before Stop must not reopen an error dialog")
    }

    func testCancelledSubmissionCleansUpAndAllowsRetry() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await channel.cancelNextSend()
        let failed = await chat.send("Build an app")
        XCTAssertFalse(failed)
        XCTAssertFalse(chat.submitting)
        XCTAssertNil(chat.live)
        XCTAssertNil(chat.turnError)
        XCTAssertEqual(chat.lastFailedInput, "Build an app")
        let retried = await chat.send("Build an app")
        XCTAssertTrue(retried)
        await chat.cancel()
        XCTAssertNil(chat.live)
    }

    func testNativeSessionConflictEndsAcceptedRunAndClearsStop() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        let accepted = await chat.send("Build an app")
        XCTAssertTrue(accepted)
        await channel.failActiveTurn("This Codex conversation is open in another client. Close it there, then try sending again.")
        try await eventually { chat.live == nil }
        XCTAssertFalse(chat.thinking)
        XCTAssertFalse(chat.submitting)
        XCTAssertTrue(chat.turnError?.contains("another client") == true)
    }

    func testCachedVersionMismatchDoesNotBlockFreshDaemonAdmission() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await channel.reportStaleSoftware()
        await chat.session?.refresh()
        XCTAssertEqual(chat.session?.software?.compatibility, "incompatible")
        await chat.load()
        let accepted = await chat.send("Build an app")
        XCTAssertTrue(accepted, "Readiness is checked by the daemon at admission, not by a stale phone cache")
        await chat.cancel()
    }

    func testByteBoundedHistoryUsesHasMoreEvenWhenPageIsSmallerThanLimit() async throws {
        let channel = BytePagedHistoryChannel()
        let chat = ChatModel(chatId: "chat", session: DaemonSession(agentId: "codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        XCTAssertEqual(chat.messages.map(\.id), ["3", "4"])
        XCTAssertTrue(chat.hasMoreHistory)
        await chat.loadOlder()
        XCTAssertEqual(chat.messages.map(\.id), ["1", "2", "3", "4"])
        XCTAssertTrue(chat.hasMoreHistory)
        await chat.loadOlder()
        XCTAssertEqual(chat.messages.map(\.id), ["0", "1", "2", "3", "4"])
        XCTAssertFalse(chat.hasMoreHistory)
        await chat.loadOlder()
        let reads = await channel.reads
        XCTAssertEqual(reads, 3)
    }

    func testSendThenBackAndReturnUsesTheAcceptedUserMessageOnce() async throws {
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        await channel.holdSend()
        let sending = Task { await chat.send("Build an app") }
        try await eventually { await channel.current?.status == .running }
        chat.viewDidDisappear(viewer)
        await channel.releaseSend()
        await sending.value
        chat.viewDidAppear(viewer)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["Build an app"],
                       "The accepted prompt must already be cached before reopening reads history")
        await chat.load()
        await channel.publish(fileEvent("created"))
        try await eventually { chat.live?.toolIndexByID.count == 1 }
        await chat.cancel()
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).count, 1)
        chat.viewDidDisappear(viewer)
    }

    func testAcknowledgedMessageSurvivesLaggingHistoryAfterBackAndReopen() async throws {
        for agent in ["codex", "claude-code"] {
            let channel = ReattachChannel(running: false, supportsImages: true)
            let chat = model(channel, agent: agent, activity: ChatActivityStore())
            defer { chat.dispose() }
            let viewer = UUID()
            chat.viewDidAppear(viewer)
            await chat.load()
            let image = DaemonAttachment(mime: "image/png", data: Data("image".utf8))
            let sent = await chat.send("Build an app", attachments: [image])
            XCTAssertTrue(sent)
            let submitted = try XCTUnwrap(chat.messages.last)
            // Native transcripts can lag the admission acknowledgement.
            await channel.seedHistory([])
            chat.viewDidDisappear(viewer)
            await channel.holdHistory()
            chat.viewDidAppear(viewer)
            let reopening = Task { await chat.load(force: true) }
            try await eventually { await channel.historyReads == 2 }
            XCTAssertEqual(chat.messages, [submitted], "A pending refresh must not hide the cached prompt")
            await channel.releaseHistory()
            await reopening.value
            XCTAssertEqual(chat.messages, [submitted], "An empty native page must not erase an acknowledged send")
            let canonical = DaemonMessage(id: "native-user", chatId: "chat", role: .user,
                text: submitted.text, createdAt: submitted.createdAt, attachments: [image])
            await channel.seedHistory([canonical])
            await chat.load(force: true)
            XCTAssertEqual(chat.messages, [canonical], "Native history replaces the cached prompt without a duplicate")
        }
    }

    func testEarlierIdenticalPromptDoesNotConsumeTheNewAcknowledgedMessage() async throws {
        let previous = DaemonMessage(id: "previous-user", chatId: "chat", role: .user,
            text: "Build an app", createdAt: "2026-09-13T10:00:00Z")
        let channel = ReattachChannel(running: false, history: [previous])
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        let sent = await chat.send(previous.text)
        XCTAssertTrue(sent)
        let submitted = try XCTUnwrap(chat.messages.last)
        await channel.seedHistory([previous])
        await chat.load(force: true)
        XCTAssertEqual(chat.messages, [previous, submitted])
        let canonical = DaemonMessage(id: "new-native-user", chatId: "chat", role: .user,
            text: submitted.text, createdAt: submitted.createdAt)
        await channel.seedHistory([previous, canonical])
        await chat.load(force: true)
        XCTAssertEqual(chat.messages, [previous, canonical])
    }

    func testCompletedReceiptCachesAcceptedMessageBeforeHistoryReturns() async throws {
        let channel = ReattachChannel(running: false)
        await channel.loseFirstTurnAcknowledgement()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        let lost = await chat.send("Build an app")
        XCTAssertFalse(lost)
        await channel.complete(.done)
        await channel.holdHistory()
        let retry = Task { await chat.send("Build an app") }
        try await eventually { await channel.historyReads == 2 }
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["Build an app"],
                       "A recovered receipt must cache the prompt before its history refresh finishes")
        XCTAssertFalse(chat.thinking, "A completed receipt must not revive Stop")
        await channel.releaseHistory()
        let accepted = await retry.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
    }

    func testCachedLiveTranscriptStaysVisibleWhileReopeningWaitsForHistory() async throws {
        let fixture = try await AppStoreFixture(preloadChat: false)
        defer { fixture.close() }
        let channel = ReattachChannel(running: true, chatID: fixture.chatID)
        await channel.seedHistory([])
        await channel.publish(.init(type: .input, input: .init(id: "native-input", text: "CACHED USER MESSAGE",
            createdAt: "2026-09-14T10:00:00Z", status: "accepted")))
        await channel.publish(.init(type: .text, itemId: "answer", text: "CACHED LIVE REPLY"))
        let chat = ChatModel(chatId: fixture.chatID, session: DaemonSession(agentId: "store-mac-codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        fixture.stores.chatSessions = ChatSessionStore(stores: fixture.stores, makeModel: { _ in chat })
        let state = ChatScenePhaseFixture()
        let host = UIHostingController(rootView: ChatSceneLifecycleHost(state: state, fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        try await eventually { chat.transcriptLive?.text == "CACHED LIVE REPLY" && chat.animatesLiveUpdates }
        state.showsChat = false
        try await eventually { await channel.subscriberCount == 0 }
        await channel.holdHistory()
        let refresh = Task { await chat.load(force: true) }
        try await eventually { await channel.historyReads == 2 }
        state.showsChat = true
        try await Task.sleep(for: .milliseconds(300))
        let visible = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        // Release the held request even on failure so the fixture never hangs the test runner.
        await channel.releaseHistory()
        await refresh.value
        XCTAssertTrue(visible.contains("CACHED USER MESSAGE"), visible)
        XCTAssertTrue(visible.contains("CACHED LIVE REPLY"), visible)
    }

    func testCachedRunningReplyResumesOnlyNewEventsWithoutReadingHistoryOrSnapshotAgain() async throws {
        for agent in ["codex", "claude-code"] {
            let channel = ReattachChannel(running: false)
            let chat = model(channel, agent: agent, activity: ChatActivityStore())
            defer { chat.dispose() }
            let viewer = UUID()
            chat.viewDidAppear(viewer)
            await chat.load()
            let accepted = await chat.send("Build an app")
            XCTAssertTrue(accepted)
            await channel.publish(.init(type: .text, itemId: "answer", text: "Already visible. ", delta: true))
            try await eventually { chat.transcriptLive?.text == "Already visible. " && chat.animatesLiveUpdates }
            let requestsBefore = await channel.requests
            let readsBefore = await channel.historyReads

            chat.viewDidDisappear(viewer)
            try await eventually { await channel.subscriberCount == 0 }
            for _ in 0..<400 {
                await channel.publish(.init(type: .text, itemId: "answer", text: "new ", delta: true))
            }
            await channel.publish(fileEvent("completed-while-away"))
            // These endpoints may be slow on a large native transcript. Reopening
            // the cached run must not wait for either of them.
            await channel.holdHistory()
            await channel.holdReplay()
            chat.viewDidAppear(viewer)
            XCTAssertEqual(chat.transcriptLive?.text, "Already visible. ")
            await chat.load()
            try await eventually { await channel.opens == 2 }
            XCTAssertTrue(chat.catchingUp)
            XCTAssertEqual(chat.transcriptLive?.text, "Already visible. ")
            await chat.load() // Another opener shares the pending observer.
            let requests = Array((await channel.requests).dropFirst(requestsBefore.count))
            XCTAssertTrue(requests.contains { $0.contains("/stream?after=1&") }, requests.joined(separator: "\n"))
            XCTAssertFalse(requests.contains { $0.contains("/snapshot") || $0.contains("/messages") })
            let subscribers = await channel.subscriberCount
            XCTAssertEqual(subscribers, 1)

            await channel.releaseReplay()
            try await eventually { !chat.catchingUp && chat.transcriptLive?.toolIndexByID.count == 1 }
            XCTAssertEqual(chat.transcriptLive?.text, "Already visible. " + String(repeating: "new ", count: 400))
            XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty, "Replayed file edits should not jump open")
            let readsAfter = await channel.historyReads
            XCTAssertEqual(readsAfter, readsBefore)
            await channel.releaseHistory()
            await chat.cancel()
            XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
            XCTAssertFalse(chat.thinking)
        }
    }

    func testColdRunningChatPublishesHistoryAndPartialReplyTogether() async throws {
        for agent in ["codex", "claude-code"] {
            let channel = ReattachChannel(running: true)
            await channel.publish(.init(type: .text, itemId: "answer", text: "Already received partial response"))
            await channel.publish(fileEvent("cached-file"))
            await channel.holdSnapshot()
            let chat = model(channel, agent: agent, activity: ChatActivityStore())
            defer {
                chat.dispose()
                Task { await channel.releaseSnapshot() }
            }
            let loading = Task { await chat.load() }
            try await eventually {
                let snapshots = await channel.snapshotReads
                let history = await channel.historyReads
                return snapshots == 1 && history == 1
            }
            XCTAssertFalse(chat.hasLoadedHistory, "The prompt and active reply must become ready as one conversation")
            XCTAssertTrue(chat.transcriptMessages.isEmpty, "Do not publish just the prompt while its existing reply is loading")
            XCTAssertFalse(chat.hasCachedTranscript)
            await channel.releaseSnapshot()
            await loading.value
            XCTAssertEqual(chat.messages.map(\.text), ["Build an app"])
            XCTAssertEqual(chat.transcriptLive?.text, "Already received partial response")
            XCTAssertEqual(chat.transcriptLive?.parts.compactMap(\.tool).map(\.id), ["cached-file"])
            try await eventually { chat.animatesLiveUpdates }
            let snapshots = await channel.snapshotReads
            XCTAssertEqual(snapshots, 1, "The stream must reuse the snapshot that restored the conversation")
        }
    }

    func testColdRunningRestoreReadsHistoryAndSnapshotConcurrentlyAndResumesOnlyNewEvents() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(.init(type: .text, itemId: "answer", text: "Received before opening. ", delta: true))
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer {
            chat.dispose()
            Task { await channel.releaseHistory() }
        }
        let loading = Task { await chat.load() }
        try await eventually {
            let history = await channel.historyReads
            let snapshots = await channel.snapshotReads
            return history == 1 && snapshots == 1
        }
        XCTAssertFalse(chat.hasLoadedHistory)
        XCTAssertTrue(chat.messages.isEmpty)
        // A new event arriving after the checkpoint belongs to the stream suffix.
        await channel.publish(.init(type: .text, itemId: "answer", text: "New output.", delta: true))
        await channel.releaseHistory()
        await loading.value
        try await eventually { chat.transcriptLive?.text == "Received before opening. New output." && chat.animatesLiveUpdates }
        let requests = await channel.requests
        XCTAssertTrue(requests.contains("GET /runs/run/stream?after=1&agent=codex"))
        let historyReads = await channel.historyReads
        let snapshotReads = await channel.snapshotReads
        XCTAssertEqual(historyReads, 1)
        XCTAssertEqual(snapshotReads, 1)
    }

    func testColdRunningScreenNeverShowsThePromptWithoutItsReceivedReply() async throws {
        let fixture = try await AppStoreFixture(preloadChat: false)
        defer { fixture.close() }
        let channel = ReattachChannel(running: true, chatID: fixture.chatID)
        await channel.publish(.init(type: .text, itemId: "answer", text: "PARTIAL RESPONSE APPEARS TOGETHER"))
        await channel.holdSnapshot()
        let chat = ChatModel(chatId: fixture.chatID, session: DaemonSession(agentId: "store-mac-codex",
            transport: ExecDaemonTransport(channel: channel, agentType: "codex")), activity: ChatActivityStore())
        fixture.stores.chatSessions = ChatSessionStore(stores: fixture.stores, makeModel: { _ in chat })
        let host = UIHostingController(rootView: ChatSceneLifecycleHost(state: ChatScenePhaseFixture(), fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            chat.dispose()
            window.isHidden = true
            Task { await channel.releaseSnapshot() }
        }
        try await eventually { await channel.snapshotReads == 1 }
        try await Task.sleep(for: .milliseconds(150))
        let before = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertFalse(before.contains("Build an app"), "Do not show a prompt-only conversation while restoring its received reply: \(before)")
        await channel.releaseSnapshot()
        try await eventually { chat.hasLoadedHistory && chat.transcriptLive?.text == "PARTIAL RESPONSE APPEARS TOGETHER" }
        try await Task.sleep(for: .milliseconds(200))
        let after = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(after.contains("Build an app"), after)
        XCTAssertTrue(after.contains("PARTIAL RESPONSE APPEARS TOGETHER"), after)
    }

    func testStopDuringColdSnapshotRestoreCannotPublishTheStaleRunningConversation() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(fileEvent("before-stop"))
        await channel.holdSnapshot()
        let chat = model(channel, activity: ChatActivityStore())
        defer {
            chat.dispose()
            Task { await channel.releaseSnapshot() }
        }
        let loading = Task { await chat.load() }
        try await eventually {
            let snapshots = await channel.snapshotReads
            let history = await channel.historyReads
            return snapshots == 1 && history == 1
        }
        XCTAssertTrue(chat.canCancel)
        await chat.cancel()
        let completed = chat.messages
        XCTAssertFalse(chat.thinking)
        await channel.releaseSnapshot()
        await loading.value
        XCTAssertEqual(chat.messages, completed)
        XCTAssertNil(chat.activeRunID)
        XCTAssertFalse(chat.restoringRun)
        XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).map(\.id), ["before-stop"])
    }

    func testLeavingHalfwayThroughReplayKeepsTheCursorPairedWithCachedOutput() async throws {
        for sequenced in [true, false] {
            let channel = ReattachChannel(running: true, snapshots: sequenced, sequenced: sequenced)
            await channel.publish(.init(type: .text, itemId: "answer", text: "A", delta: true))
            let chat = model(channel, activity: ChatActivityStore())
            defer { chat.dispose() }
            let viewer = UUID()
            chat.viewDidAppear(viewer)
            await chat.load()
            try await eventually { chat.animatesLiveUpdates && chat.transcriptLive?.text == "A" }
            chat.viewDidDisappear(viewer)
            try await eventually { await channel.subscriberCount == 0 }
            await channel.publish(.init(type: .text, itemId: "answer", text: "B", delta: true))
            await channel.holdReplay()
            chat.viewDidAppear(viewer)
            await chat.load()
            try await eventually { await channel.opens == 2 }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(chat.transcriptLive?.text, "A", "Partial replay must not erase or duplicate the cached text")
            chat.viewDidDisappear(viewer)
            try await eventually { await channel.subscriberCount == 0 }
            await channel.publish(.init(type: .text, itemId: "answer", text: "C", delta: true))
            await channel.releaseReplay()
            chat.viewDidAppear(viewer)
            await chat.load()
            try await eventually { !chat.catchingUp && chat.transcriptLive?.text == "ABC" }
            let requests = await channel.requests
            if sequenced {
                XCTAssertEqual(requests.filter { $0.contains("/stream?after=1&") }.count, 3,
                               "Both returns must resume the published checkpoint, never the discarded replay buffer")
            } else {
                XCTAssertFalse(requests.contains { $0.contains("after=") }, "Old daemons still replay atomically without cursors")
            }
            let reads = await channel.historyReads
            XCTAssertEqual(reads, 1)
        }
    }

    func testTransportReconnectDuringReplayPreservesTheBufferedSuffix() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(.init(type: .text, itemId: "answer", text: "A", delta: true))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.animatesLiveUpdates && chat.transcriptLive?.text == "A" }
        chat.viewDidDisappear(viewer)
        try await eventually { await channel.subscriberCount == 0 }
        await channel.publish(.init(type: .text, itemId: "answer", text: "B", delta: true))
        await channel.holdReplay()
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { await channel.opens == 2 }
        try await Task.sleep(for: .milliseconds(30))
        await channel.disconnect()
        // The production monitor backs off for one second after transport failure.
        try await Task.sleep(for: .milliseconds(1_050))
        try await eventually { await channel.opens == 3 }
        await channel.publish(.init(type: .text, itemId: "answer", text: "C", delta: true))
        await channel.releaseReplay()
        try await eventually { !chat.catchingUp && chat.transcriptLive?.text == "ABC" }
        let requests = await channel.requests
        XCTAssertTrue(requests.contains { $0.contains("/stream?after=2&") })
        let cancels = await channel.cancels
        XCTAssertEqual(cancels, 0)
    }

    func testNewRunWhileAwayDoesNotReuseThePreviousRunsCursorOrHistoryPrefix() async throws {
        let channel = ReattachChannel(running: true)
        for _ in 0..<5 { await channel.publish(.init(type: .text, itemId: "answer", text: "old ", delta: true)) }
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        chat.viewDidDisappear(viewer)
        try await eventually { await channel.subscriberCount == 0 }
        await channel.complete(.done)
        await channel.startNextRun()
        await channel.publish(.init(type: .text, itemId: "new-answer", text: "New run output", delta: true))
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.animatesLiveUpdates && chat.transcriptLive?.text == "New run output" }
        XCTAssertEqual(chat.activeRunID, "next-run")
        XCTAssertEqual(chat.messages.filter { $0.id == "reply" }.count, 1)
        XCTAssertEqual(chat.messages.last?.id, "next-user")
        let requests = await channel.requests
        XCTAssertTrue(requests.contains { $0.contains("/runs/next-run/stream?after=1&") })
        XCTAssertFalse(requests.contains { $0.contains("/runs/next-run/stream?after=5&") })
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 2)
    }

    func testInitialLoadContinuesAfterLeavingAndReopenUsesTheCachedPage() async throws {
        let history = [DaemonMessage(id: "saved", chatId: "chat", role: .assistant,
            text: "Already saved in the native transcript", createdAt: "2026-09-24T10:00:00Z")]
        let channel = ReattachChannel(running: false, history: history)
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let first = UUID(), second = UUID()
        chat.viewDidAppear(first)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        chat.viewDidDisappear(first)
        loading.cancel() // SwiftUI cancels the disappearing screen's task.
        XCTAssertTrue(chat.isInitiallyLoading)
        await channel.releaseHistory()
        await loading.value
        XCTAssertTrue(chat.hasLoadedHistory)
        XCTAssertEqual(chat.messages, history)
        XCTAssertFalse(chat.isInitiallyLoading)
        chat.viewDidAppear(second)
        await chat.load()
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 1, "Reopening a fresh, unchanged transcript must not download it again")
        chat.viewDidDisappear(second)
    }

    func testConcurrentOpensShareOneHistoryReadAndOneLiveSubscription() async throws {
        let channel = ReattachChannel(running: true)
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let first = UUID(), second = UUID()
        chat.viewDidAppear(first)
        let a = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        chat.viewDidAppear(second)
        let b = Task { await chat.load() }
        chat.viewDidDisappear(first)
        a.cancel()
        await channel.releaseHistory()
        await a.value
        await b.value
        try await eventually { await channel.subscriberCount == 1 }
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 1)
        chat.viewDidDisappear(second)
        try await eventually { await channel.subscriberCount == 0 }
        XCTAssertTrue(chat.thinking, "The cached running state must retain Stop on the next visit")
    }

    func testNotificationRefreshesTheNewestPageWithoutDiscardingLoadedHistory() async throws {
        let history = (0..<35).map { DaemonMessage(id: "message-\($0)", chatId: "chat", role: .assistant,
            text: "Saved \($0)", createdAt: "2026-10-02T10:00:00Z") }
        let channel = ReattachChannel(running: false, history: history)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await chat.loadOlder()
        let cached = chat.messages
        let presentation = chat.presentationID
        let added = DaemonMessage(id: "new-reply", chatId: "chat", role: .assistant,
            text: "The answer that sent the notification", createdAt: "2026-10-02T10:01:00Z")
        await channel.seedHistory(history + [added])
        chat.openFromNotification(id: "completed-run")
        XCTAssertEqual(chat.messages, cached, "A tap must leave cached content available immediately")
        XCTAssertEqual(chat.presentationID, presentation)
        await chat.load()
        XCTAssertEqual(chat.messages, cached + [added])
        XCTAssertTrue(chat.hasMoreHistory)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3, "Two cached pages need only one tail refresh")
        chat.openFromNotification(id: "completed-run")
        await chat.load()
        let repeatedReads = await channel.historyReads
        XCTAssertEqual(repeatedReads, reads, "Tapping the same notification again repositions without another read")
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, history + [added], "The older-page cursor must survive the notification")
    }

    func testRepeatedNotificationTapsShareThePendingHistoryRequest() async throws {
        let channel = ReattachChannel(running: false)
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        chat.openFromNotification(id: "notification")
        let first = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        chat.openFromNotification(id: "notification")
        let second = Task { await chat.load() }
        await channel.releaseHistory()
        await first.value
        await second.value
        XCTAssertTrue(chat.hasLoadedHistory)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 1)
    }

    func testANewerNotificationDuringAnOlderSnapshotTriggersOneTailRefresh() async throws {
        let saved = DaemonMessage(id: "saved", chatId: "chat", role: .assistant, text: "Previous reply", createdAt: "")
        let added = DaemonMessage(id: "added", chatId: "chat", role: .assistant, text: "Newest reply", createdAt: "")
        let channel = ReattachChannel(running: false, history: [saved])
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        chat.openFromNotification(id: "first")
        let first = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        await channel.seedHistory([saved, added])
        chat.openFromNotification(id: "second")
        let second = Task { await chat.load() }
        await channel.releaseHistory()
        await first.value
        await second.value
        XCTAssertEqual(chat.messages, [saved, added], "An old in-flight snapshot must not acknowledge a newer push")
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 2)
    }

    func testNotificationDoesNotRestartAnActiveStreamOrReloadItsHistory() async throws {
        let channel = ReattachChannel(running: true)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { await channel.subscriberCount == 1 && chat.animatesLiveUpdates }
        let reads = await channel.historyReads, opens = await channel.opens
        let presentation = chat.presentationID
        chat.openFromNotification(id: "live-update")
        await chat.load()
        XCTAssertEqual(chat.presentationID, presentation)
        let updatedReads = await channel.historyReads, updatedOpens = await channel.opens
        XCTAssertEqual(updatedReads, reads)
        XCTAssertEqual(updatedOpens, opens)
        await channel.publish(.init(type: .text, text: "Still streaming on the original connection"))
        try await eventually { chat.live?.text == "Still streaming on the original connection" }
    }

    func testDetachedInitialLoadCannotStartAStreamAndReturnRestoresWithoutReplay() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(fileEvent("before-return"))
        await channel.holdHistory()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        chat.viewDidDisappear(viewer)
        await channel.releaseHistory()
        await loading.value
        let initialOpens = await channel.opens
        XCTAssertEqual(initialOpens, 0)
        XCTAssertTrue(chat.hasLoadedHistory)
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.live?.toolIndexByID.count == 1 && chat.animatesLiveUpdates }
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 1, "Reattaching the same run only needs its status and snapshot")
        await channel.publish(fileEvent("new-live"))
        try await eventually { chat.autoExpandedToolIDs == ["new-live"] }
        chat.viewDidDisappear(viewer)
    }

    func testNativeActivityInvalidatesCachedHistoryAndKeepsLoadedOlderPages() async throws {
        let activity = ChatActivityStore()
        let history = (0..<24).map {
            DaemonMessage(id: "message-\($0)", chatId: "chat", role: .assistant,
                text: "Saved \($0)", createdAt: "2026-09-24T10:00:00Z")
        }
        let channel = ReattachChannel(running: false, history: history)
        let chat = model(channel, activity: activity)
        defer { chat.dispose() }
        await chat.load()
        await chat.loadOlder()
        let added = DaemonMessage(id: "new-native", chatId: "chat", role: .assistant,
            text: "Continued on the computer", createdAt: "2026-09-25T10:00:00Z")
        await channel.seedHistory(history + [added])
        activity.receive([.init(chatId: "chat", updatedAt: "2026-09-25T10:00:00Z")], workspaceId: "workspace")
        await chat.load()
        XCTAssertEqual(chat.messages, history + [added])
    }

    func testReturnLoadsNativeComputerChangesWithoutAnActivityNotification() async throws {
        let original = catchUpHistory(60)
        let channel = ReattachChannel(running: false, history: original)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID(), secondViewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        await chat.loadOlder()
        await chat.loadOlder()
        XCTAssertEqual(chat.messages.count, 36)
        chat.viewDidDisappear(viewer)

        let updated = catchUpHistory(400)
        await channel.seedHistory(updated)
        await channel.holdHistory()
        chat.viewDidAppear(viewer)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 4 }
        XCTAssertTrue(chat.catchingUp)
        XCTAssertEqual(chat.messages.count, 12, "An old expanded cache should not be laid out while catching up")
        chat.viewDidAppear(secondViewer)
        let duplicateOpen = Task { await chat.load() }
        await channel.releaseHistory()
        await loading.value
        await duplicateOpen.value

        XCTAssertFalse(chat.catchingUp)
        XCTAssertEqual(chat.messages, Array(updated.suffix(12)))
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 4, "Hundreds of changes need one shared newest-page read, even inside the cache TTL")
        XCTAssertTrue(chat.hasMoreHistory)
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, Array(updated.suffix(24)), "Scrolling up must load the gap from the new window")
    }

    func testRunCompletedWhileAwayUsesOneTailReadWithoutRegraftingTheOldSnapshot() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(DaemonEvent(type: .text, text: "Cached work from the start of this run."))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        chat.viewDidDisappear(viewer)

        let native = catchUpHistory(400) + [DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "LATEST COMPUTER ANSWER", createdAt: "2026-09-14T10:01:00Z",
            parts: [.init(kind: .text, text: "LATEST COMPUTER ANSWER")])]
        await channel.complete(.done, history: native)
        await channel.holdHistory()
        chat.viewDidAppear(viewer)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 2 }
        XCTAssertTrue(chat.catchingUp)
        XCTAssertEqual(chat.transcriptLive?.text, "Cached work from the start of this run.",
                       "Keep the cached reply visible until the terminal page is ready to replace it atomically")
        await channel.releaseHistory()
        await loading.value

        XCTAssertFalse(chat.thinking)
        XCTAssertFalse(chat.catchingUp)
        XCTAssertNil(chat.turnError)
        XCTAssertEqual(chat.messages, Array(native.suffix(12)))
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 2, "Returning must never backfill hundreds of earlier run messages")
        await chat.loadOlder()
        XCTAssertEqual(chat.messages, Array(native.suffix(24)))
    }

    func testRestoredRunCompletionKeepsTheNewestPageAndDefersOlderMessages() async throws {
        let channel = ReattachChannel(running: true)
        await channel.publish(DaemonEvent(type: .text, text: "Earlier work already saved in native history."))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        let native = catchUpHistory(240) + [DaemonMessage(id: "reply", chatId: "chat", role: .assistant,
            text: "Final result", createdAt: "2026-09-14T10:01:00Z", parts: [.init(kind: .text, text: "Final result")])]
        await channel.complete(.done, history: native)
        try await eventually { !chat.thinking }
        XCTAssertEqual(chat.messages, Array(native.suffix(12)))
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 2, "A restored run must not switch back to a full-run download at completion")
        XCTAssertTrue(chat.hasMoreHistory)
    }

    func testReopenedCachedTranscriptLandsOnLatestWithoutLoadingIntermediatePages() async throws {
        let channel = ReattachChannel(running: false, history: catchUpHistory(60))
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        await chat.load()
        await chat.loadOlder()
        let host = UIHostingController(rootView: NavigationStack {
            ChatTranscriptView(model: chat, agentType: .codex)
                .navigationTitle("Project review").navigationBarTitleDisplayMode(.inline)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    Text("Message Codex…").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).glassEffect(in: .capsule).padding(16)
                }
        }.preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        try await eventually { self.transcriptTable(in: host.view) != nil }
        host.view.layoutIfNeeded()
        let oldTable = try XCTUnwrap(transcriptTable(in: host.view))
        oldTable.delegate?.scrollViewWillBeginDragging?(oldTable)
        oldTable.scrollToRow(at: IndexPath(row: 2, section: 0), at: .top, animated: false)
        oldTable.delegate?.scrollViewDidEndDragging?(oldTable, willDecelerate: false)
        chat.viewDidDisappear(viewer)

        await channel.seedHistory(catchUpHistory(400))
        await channel.holdHistory()
        chat.viewDidAppear(viewer)
        let loading = Task { await chat.load() }
        try await eventually {
            let reads = await channel.historyReads
            return chat.catchingUp && reads == 3
        }
        try await Task.sleep(for: .milliseconds(180))
        host.view.layoutIfNeeded()
        attach(host, name: "Cached chat loading latest computer activity")
        let table = try XCTUnwrap(transcriptTable(in: host.view))
        await channel.releaseHistory()
        await loading.value
        try await Task.sleep(for: .milliseconds(180))
        host.view.layoutIfNeeded()
        XCTAssertTrue(transcriptTable(in: host.view) === table, "Catch-up must update the existing transcript")
        XCTAssertEqual(table.numberOfRows(inSection: 0), 12)
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(IndexPath(row: 11, section: 0)) == true)
        XCTAssertLessThanOrEqual(table.contentSize.height - table.contentOffset.y - table.bounds.height
            + table.adjustedContentInset.bottom, 2)
        XCTAssertEqual(chat.messages.last?.id, "computer-399")
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3, "Positioning at the tail must not trigger older-page requests")
        attach(host, name: "Reopened chat at latest computer message")
    }

    private func catchUpHistory(_ count: Int) -> [DaemonMessage] {
        (0..<count).map { index in
            DaemonMessage(id: "computer-\(index)", chatId: "chat", role: .assistant,
                text: "Computer update \(index).\n\n" + String(repeating: "Saved work from the native conversation. ", count: 5),
                createdAt: "2026-09-14T10:00:30Z")
        }
    }

    func testCachedAttachmentRowsUseTheSessionAfterItBecomesAvailable() async throws {
        let artifactID = "history-photo-\(UUID().uuidString)"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let message = DaemonMessage(id: "photo", chatId: "chat", role: .user, text: "Saved photo",
            createdAt: "2026-09-14T10:00:00Z",
            attachments: [.init(artifactId: artifactID, bytes: bytes.count, name: "Photo.png", mime: "image/png")])
        let channel = ReattachChannel(running: false, history: [message])
        await channel.seedArtifact(artifactID, data: bytes)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        let host = UIHostingController(rootView: ChatTranscriptView(model: chat)
            .environment(\.chatAttachmentSession, nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await eventually { self.transcriptTable(in: host.view) != nil }
        let table = try XCTUnwrap(transcriptTable(in: host.view))
        host.rootView = ChatTranscriptView(model: chat).environment(\.chatAttachmentSession, chat.session)
        try await eventually { await channel.artifactReads == 1 }
        XCTAssertTrue(transcriptTable(in: host.view) === table, "Binding an attachment channel must update recycled cells in place")
        let read = try await ChatAttachmentContent.data(try XCTUnwrap(message.attachments?.first), session: chat.session)
        XCTAssertEqual(read, bytes)
        let reads = await channel.artifactReads
        XCTAssertEqual(reads, 1, "A restored photo must share its cached bytes with the image viewer")
    }

    func testChatCacheEvictionKeepsVisibleAndLoadingModelsAndDeletionInvalidates() {
        let defaults = UserDefaults(suiteName: "chat-cache-\(UUID())")!
        let stores = Stores(defaults: defaults)
        let cache = ChatSessionStore(stores: stores, capacity: 2)
        let a = cache.model(for: "a"), b = cache.model(for: "b")
        let viewer = UUID()
        a.viewDidAppear(viewer)
        XCTAssertTrue(cache.model(for: "a") === a)
        _ = cache.model(for: "c")
        XCTAssertTrue(cache.cached("a") === a)
        XCTAssertNil(cache.cached("b"))
        cache.remove("a")
        XCTAssertNil(cache.cached("a"))
        XCTAssertFalse(a.hasLoadedHistory)
        _ = b // An evicted model may still be referenced by a disappearing screen.
    }

    func testRetryPreservesTheTurnReceiptAfterTheComposerRestoresItsDraft() async throws {
        let channel = ReattachChannel(running: false)
        await channel.loseFirstTurnAcknowledgement()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        await chat.send("Do this once")
        XCTAssertEqual(chat.lastFailedInput, "Do this once")
        // ChatScreen consumes this one-shot value when it restores the composer.
        chat.lastFailedInput = nil
        await chat.send("Do this once")
        let receipts = await channel.turnReceipts
        XCTAssertEqual(receipts.count, 2)
        XCTAssertFalse(receipts[0].isEmpty)
        XCTAssertEqual(receipts[0], receipts[1], "Retry must recover the accepted turn")
        XCTAssertNil(chat.turnError)
    }

    func testFollowupsKeepTheSameStreamAndOnlyAppearAfterNativeConsumption() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        try await eventually { await channel.opens == 1 }
        await channel.publish(DaemonEvent(type: .text, itemId: "first", text: "Still working"))
        let sent = await chat.send("Also check accessibility")
        XCTAssertTrue(sent)
        XCTAssertEqual(chat.activeRunID, "run")
        XCTAssertTrue(chat.thinking)
        XCTAssertEqual(chat.queuedInputs.map(\.text), ["Also check accessibility"])
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        XCTAssertTrue(chat.live?.parts.compactMap(\.input).isEmpty == true)
        let opens = await channel.opens
        XCTAssertEqual(opens, 1, "A follow-up must not restart the stream or replay the transcript")
        await channel.acceptQueuedInputs()
        try await eventually { chat.queuedInputs.isEmpty }
        XCTAssertEqual(chat.live?.parts.compactMap(\.input).map(\.text), ["Also check accessibility"])
        XCTAssertEqual(chat.live?.text, "Still working")
    }

    func testQueuedImagesAndMessagesSurviveClosingAndReopening() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        let chat = model(channel, activity: ChatActivityStore())
        _ = try await chat.session?.agentInfo()
        await chat.load()
        let image = DaemonAttachment(mime: "image/png", data: Data("image".utf8))
        let sent = await chat.send("", attachments: [image])
        XCTAssertTrue(sent)
        let inputID = try XCTUnwrap(chat.queuedInputs.first?.id)
        chat.dispose()
        let reopened = model(channel, activity: ChatActivityStore())
        defer { reopened.dispose() }
        _ = try await reopened.session?.agentInfo()
        await reopened.load()
        XCTAssertEqual(reopened.queuedInputs.map(\.id), [inputID])
        XCTAssertEqual(reopened.queuedInputs.first?.attachments, [image])
        XCTAssertTrue(reopened.thinking)
        await reopened.cancel()
        XCTAssertFalse(reopened.thinking)
        XCTAssertEqual(reopened.queuedInputs.first?.status, "cancelled")
        XCTAssertEqual(reopened.queuedInputs.first?.attachments, [image], "Stop must keep an unsent image recoverable")
    }

    func testRejectedFollowupKeepsTheCurrentRunAndStop() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        await channel.rejectSend()
        let sent = await chat.send("Keep this follow-up")
        XCTAssertFalse(sent)
        XCTAssertEqual(chat.lastFailedInput, "Keep this follow-up")
        XCTAssertTrue(chat.thinking)
        XCTAssertEqual(chat.activeRunID, "run")
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
        let cancels = await channel.cancels
        XCTAssertEqual(cancels, 1)
    }

    func testLostQueuedReceiptRetriesOnceWithoutNativeDuplicate() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        await channel.loseFirstTurnAcknowledgement()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        let lost = await chat.send("Follow-up once")
        XCTAssertFalse(lost)
        XCTAssertTrue(chat.thinking)
        let retry = await chat.send("Follow-up once")
        XCTAssertTrue(retry)
        let receipts = await channel.turnReceipts
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(Set(receipts).count, 1)
        let saved = await channel.current?.inputs
        XCTAssertEqual(saved?.count, 1)
        XCTAssertEqual(chat.queuedInputs.count, 1)
        XCTAssertNil(chat.turnError)
    }

    func testCompletionDuringFollowupAdmissionLoadsTheNewRun() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        await channel.completeBeforeNextSend()
        let sent = await chat.send("Continue the work")
        XCTAssertTrue(sent)
        try await eventually { chat.activeRunID == "resumed" }
        XCTAssertTrue(chat.thinking)
        XCTAssertEqual(chat.messages.filter { $0.role == .user && $0.text == "Continue the work" }.count, 1)
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
    }

    func testQueuedAdmissionResponseAfterStopCannotReviveTheRun() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        await channel.holdSend()
        let send = Task { await chat.send("Follow-up during stop") }
        try await eventually { await channel.current?.inputs?.count == 1 }
        XCTAssertTrue(chat.submittingInput)
        let duplicate = await chat.send("Do not send twice")
        XCTAssertFalse(duplicate)
        await chat.cancel()
        await channel.releaseSend()
        let sent = await send.value
        XCTAssertTrue(sent)
        XCTAssertFalse(chat.thinking)
        XCTAssertNil(chat.activeRunID)
        XCTAssertEqual(chat.queuedInputs.first?.status, "cancelled")
    }

    func testStopDuringFileUploadDoesNotSendThePendingFollowup() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput()
        await channel.holdUpload()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        let file = DaemonAttachment(name: "notes.txt", mime: "text/plain", data: Data("notes".utf8))
        let send = Task { await chat.send("Use these notes", attachments: [file]) }
        try await eventually { await channel.requests.contains { $0.contains("/attachments/") } }
        await chat.cancel()
        await channel.releaseUpload()
        let accepted = await send.value
        XCTAssertFalse(accepted, "Finishing an upload after Stop must not start another turn")
        XCTAssertFalse(chat.thinking)
        XCTAssertFalse(chat.submittingInput)
        XCTAssertEqual(chat.lastFailedAttachments, [file], "The unsent file stays available in the draft")
        let turns = await channel.requests.filter { $0.hasPrefix("POST /turns") }
        XCTAssertTrue(turns.isEmpty)
    }

    func testOlderDaemonExplainsQueuedInputUpdateWithoutDroppingTheDraftOrRun() async throws {
        let channel = ReattachChannel(running: true)
        await channel.enableQueuedInput(version: 0)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        _ = try await chat.session?.agentInfo()
        await chat.load()
        let sent = await chat.send("Keep this draft")
        XCTAssertFalse(sent)
        XCTAssertEqual(chat.lastFailedInput, "Keep this draft")
        XCTAssertTrue(chat.turnError?.contains("Update") == true)
        XCTAssertTrue(chat.thinking)
        let requests = await channel.requests
        XCTAssertFalse(requests.contains { $0.hasPrefix("POST /turns") })
    }

    private func model(_ channel: ReattachChannel, agent: String = "codex", activity: ChatActivityStore) -> ChatModel {
        ChatModel(chatId: "chat", session: DaemonSession(agentId: agent,
            transport: ExecDaemonTransport(channel: channel, agentType: agent)), activity: activity)
    }

    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("State did not reconcile", file: file, line: line)
        throw NSError(domain: "ChatLifecycleTests", code: 1)
    }

    func testCodexAndClaudeReopenWithStopAndOnlyNewToolsAutoExpand() async throws {
        for agent in ["codex", "claude"] {
            let activity = ChatActivityStore()
            let channel = ReattachChannel(running: true)
            await channel.publish(fileEvent("old"))
            await channel.publish(DaemonEvent(type: .interaction, interaction:
                DaemonInteraction(id: "question", kind: "approval", title: "Allow build?", needsResponse: true)))
            let chat = model(channel, agent: agent, activity: activity)
            defer { chat.dispose() }

            await chat.load()
            try await eventually { chat.live?.toolIndexByID.count == 1 }
            XCTAssertTrue(chat.thinking, "Stop must be restored for \(agent)")
            XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty, "Replay is history on this visit")
            XCTAssertEqual(chat.messages.map(\.role), [.user])
            XCTAssertEqual(chat.live?.parts.last?.interaction?.needsResponse, true)

            await channel.publish(fileEvent("live"))
            try await eventually { chat.live?.toolIndexByID.count == 2 }
            XCTAssertEqual(chat.autoExpandedToolIDs, ["live"])
            chat.dispose()
            try await eventually { await channel.subscriberCount == 0 }
            let stillRunning = await channel.current?.status
            let cancels = await channel.cancels
            XCTAssertEqual(stillRunning, .running, "Back must not stop the daemon")
            XCTAssertEqual(cancels, 0)
            XCTAssertEqual(activity.status("chat"), .running)

            await chat.load()
            try await eventually { chat.live?.toolIndexByID.count == 2 }
            XCTAssertTrue(chat.thinking)
            XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty, "Previous live tools collapse on reopening")
            await channel.publish(fileEvent("after-return"))
            try await eventually { chat.live?.toolIndexByID.count == 3 }
            XCTAssertEqual(chat.autoExpandedToolIDs, ["after-return"])
            let request = try XCTUnwrap(chat.live?.parts.compactMap(\.interaction).first)
            await chat.respond(to: request, answer: DaemonInteractionReply(decision: "allow"))
            XCTAssertEqual(chat.live?.parts.compactMap(\.interaction).first?.needsResponse, false)

            await chat.cancel()
            try await eventually { !chat.thinking }
            XCTAssertEqual(activity.status("chat"), .cancelled)
            XCTAssertEqual(chat.messages.count, 2)
            XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).count, 3)
            let requests = await channel.requests
            XCTAssertTrue(requests.contains("POST /runs/run/cancel?agent=\(agent)"))
            XCTAssertTrue(requests.contains("POST /runs/run/respond?agent=\(agent)"))

            chat.dispose()
            await chat.load()
            XCTAssertFalse(chat.thinking)
            XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
            XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).count, 3)
        }
    }

    func testSlowHistoryRestoresStopFirstAndCannotReattachAfterBack() async throws {
        let activity = ChatActivityStore()
        let channel = ReattachChannel(running: true)
        await channel.holdHistory()
        let chat = model(channel, activity: activity)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        XCTAssertTrue(chat.thinking)
        XCTAssertTrue(chat.loadingHistory)
        chat.dispose()
        await channel.releaseHistory()
        await loading.value
        XCTAssertFalse(chat.thinking)
        let opens = await channel.opens
        XCTAssertEqual(opens, 0, "A late HTTP result must not resurrect a closed screen")
        XCTAssertEqual(activity.status("chat"), .running)
    }

    func testLegacyHistoryLoadsSmallPagesWithoutOverlappingRequests() async throws {
        let history = (0..<35).map { index in
            DaemonMessage(id: "message-\(index)", chatId: "chat", role: .assistant,
                          text: "Saved message \(index)", createdAt: "2026-09-24T10:00:00Z")
        }
        let channel = ReattachChannel(running: false, history: history)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        XCTAssertEqual(chat.messages.map(\.id), history.suffix(12).map(\.id))
        XCTAssertTrue(chat.hasMoreHistory)

        await channel.holdHistory()
        let older = Task { await chat.loadOlder() }
        try await eventually { await channel.historyReads == 2 }
        await chat.loadOlder()
        let concurrentReads = await channel.historyReads
        XCTAssertEqual(concurrentReads, 2, "Repeated scrolling must share the in-flight page")
        await channel.releaseHistory()
        await older.value
        XCTAssertEqual(chat.messages.map(\.id), history.suffix(24).map(\.id))

        await chat.loadOlder()
        XCTAssertEqual(chat.messages.map(\.id), history.map(\.id))
        XCTAssertFalse(chat.hasMoreHistory)
        await chat.loadOlder()
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 3, "Stop paging after the oldest message")
        let requests = await channel.requests.filter { $0.contains("/messages?") }
        XCTAssertEqual(requests, [
            "GET /chats/chat/messages?limit=12&paged=true&maxBytes=1048576&agent=codex",
            "GET /chats/chat/messages?limit=12&paged=true&maxBytes=1048576&before=message-23&agent=codex",
            "GET /chats/chat/messages?limit=12&paged=true&maxBytes=1048576&before=message-11&agent=codex"
        ])
    }

    func testReopeningLongRunningChatPaintsLatestOutputWithoutScrolling() async throws {
        let history = (0..<40).map { index in
            DaemonMessage(id: "saved-\(index)", chatId: "chat", role: index.isMultiple(of: 2) ? .user : .assistant,
                text: index.isMultiple(of: 2) ? "Saved request \(index)" :
                    (0..<12).map { "Paragraph \($0) from saved response \(index). Already received before reopening." }.joined(separator: "\n\n"),
                createdAt: "2026-09-14T09:00:00Z")
        }
        let channel = ReattachChannel(running: true)
        await channel.seedHistory(history)
        for index in 0..<160 {
            await channel.publish(DaemonEvent(type: .text, itemId: "step-\(index)",
                text: "Completed implementation step \(index).\n\n" + String(repeating: "Saved explanation with **formatting**. ", count: index % 6 + 1)))
            if index.isMultiple(of: 3) { await channel.publish(fileEvent("File\(index)")) }
        }
        await channel.publish(DaemonEvent(type: .text, itemId: "latest", text: "LATEST RUNNING OUTPUT is visible immediately."))
        let chat = model(channel, activity: ChatActivityStore())
        let viewer = UUID()
        chat.viewDidAppear(viewer)
        let host = UIHostingController(rootView: ChatTranscriptView(model: chat))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        try await Task.sleep(for: .milliseconds(350))
        let image = ChatFeedSnapshot.image(host)
        attach(image, name: "Running chat visible on open")
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("LATEST RUNNING OUTPUT"), "Opening must paint the actual latest rows, not empty estimated space: \(visible)")
        let reads = await channel.historyReads
        XCTAssertEqual(reads, 1, "Restoring the bottom must not request older history")
        // The second visit restores into an already existing screen and resets its disclosure state.
        chat.viewDidDisappear(viewer)
        chat.viewDidAppear(viewer)
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        try await Task.sleep(for: .milliseconds(350))
        let reopenedImage = ChatFeedSnapshot.image(host)
        attach(reopenedImage, name: "Running chat latest after reopening")
        let reopened = try ChatFeedSnapshot.visibleText(in: reopenedImage)
        XCTAssertTrue(reopened.contains("LATEST RUNNING OUTPUT"), "A subsequent visit must also paint the latest rows: \(reopened)")
    }

    func testShortHistoryShowsUserAndAssistantAtTop() async throws {
        let history: [DaemonMessage] = [
            .init(id: "request", chatId: "chat", role: .user, text: "USER QUICK CHECK", createdAt: "2026-09-24T09:00:00Z"),
            .init(id: "answer", chatId: "chat", role: .assistant, text: "A short assistant reply.", createdAt: "2026-09-24T09:00:01Z")
        ]
        let chat = model(ReattachChannel(running: false, history: history), activity: ChatActivityStore())
        let host = UIHostingController(rootView: ChatTranscriptView(model: chat))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { chat.dispose(); window.isHidden = true }
        await chat.load()
        try await Task.sleep(for: .milliseconds(200))
        let image = ChatFeedSnapshot.image(host)
        let visible = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(visible.contains("USER QUICK CHECK"), visible)
        XCTAssertTrue(visible.contains("A short assistant reply"), visible)
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        XCTAssertLessThan(scroll.contentSize.height, 300, "Short messages must not stretch their cells to fill the viewport")
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 1)
        attach(image, name: "Short chat top alignment")
    }

    func testAcceptedSendAfterBackUpdatesListsWithoutResurrectingScreen() async throws {
        let activity = ChatActivityStore()
        let channel = ReattachChannel(running: false)
        let chat = model(channel, activity: activity)
        defer { chat.dispose() }
        await chat.load()
        await channel.holdSend()
        let sending = Task { await chat.send("Build an app") }
        try await eventually { await channel.current?.status == .running }
        chat.dispose()
        await channel.releaseSend()
        await sending.value
        XCTAssertEqual(activity.status("chat"), .running)
        XCTAssertFalse(chat.thinking)
        let opens = await channel.opens
        XCTAssertEqual(opens, 0)
        await chat.load()
        XCTAssertTrue(chat.thinking)
        XCTAssertEqual(chat.messages.count, 1, "Replace the optimistic input with the accepted message")
    }

    func testCompletionBetweenRunAndHistoryReadsCommitsExactlyOnce() async throws {
        let activity = ChatActivityStore()
        let channel = ReattachChannel(running: true)
        await channel.publish(fileEvent("file"))
        await channel.completeDuringHistoryRead()
        let chat = model(channel, activity: activity)
        await chat.load()
        XCTAssertFalse(chat.thinking)
        XCTAssertNil(chat.turnError)
        XCTAssertEqual(activity.status("chat"), .done)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).count, 1)
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
        let opens = await channel.opens
        XCTAssertEqual(opens, 0)
    }

    func testStopDuringSlowReloadCannotBeOverwrittenByTheOlderHistoryResponse() async throws {
        let activity = ChatActivityStore()
        let channel = ReattachChannel(running: true)
        await channel.publish(fileEvent("file"))
        await channel.holdHistory()
        let chat = model(channel, activity: activity)
        let loading = Task { await chat.load() }
        try await eventually { await channel.historyReads == 1 }
        XCTAssertTrue(chat.thinking)
        await chat.cancel()
        XCTAssertFalse(chat.thinking)
        XCTAssertEqual(chat.messages.count, 2)
        await channel.releaseHistory()
        await loading.value
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.parts?.compactMap(\.tool).count, 1)
        XCTAssertEqual(activity.status("chat"), .cancelled)
    }

    func testReopenHydratesSnapshotThenSubscribesOnlyToNewEvents() async throws {
        let channel = ReattachChannel(running: true)
        for _ in 0..<200 { await channel.publish(DaemonEvent(type: .text, itemId: "answer", text: "word ", delta: true)) }
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.live?.text.count == 1000 && chat.animatesLiveUpdates }
        let requests = await channel.requests
        XCTAssertTrue(requests.contains("GET /runs/run/snapshot?agent=codex"))
        XCTAssertTrue(requests.contains("GET /runs/run/stream?after=200&agent=codex"))
        XCTAssertEqual(chat.live?.parts.count, 1)
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
        await channel.publish(DaemonEvent(type: .text, itemId: "answer", text: "new", delta: true))
        try await eventually { chat.live?.text.hasSuffix("word new") == true }
    }

    func testOlderDaemonReplayIsAppliedTogetherAtReady() async throws {
        let channel = ReattachChannel(running: true, snapshots: false)
        for _ in 0..<100 { await channel.publish(DaemonEvent(type: .text, itemId: "answer", text: "a", delta: true)) }
        await channel.holdReplay()
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { await channel.opens == 1 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(chat.live?.text, "", "History must not become an animated token replay")
        XCTAssertFalse(chat.animatesLiveUpdates)
        await channel.releaseReplay()
        try await eventually { chat.live?.text.count == 100 }
        XCTAssertTrue(chat.animatesLiveUpdates)
        XCTAssertTrue(chat.thinking)
    }

    func testLiveShellCommandsStayCollapsed() async throws {
        let channel = ReattachChannel(running: true)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.animatesLiveUpdates }
        await channel.publish(DaemonEvent(type: .tool_use, tool: DaemonToolEvent(id: "shell", name: "shell",
            action: DaemonToolAction(kind: "shell", shell: DaemonShellCommand(command: "swift build")))))
        try await eventually { chat.live?.toolIndexByID["shell"] != nil }
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
    }

    func testReopenedFormWaitsForOneReplyAndAllowsRetryWithoutStartingAnotherTurn() async throws {
        let channel = ReattachChannel(running: true)
        let form = try InteractionFixtures.form("claude-code")
        await channel.publish(DaemonEvent(type: .interaction, interaction: form))
        let chat = model(channel, agent: "claude-code", activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.live?.waitingForInput == true }
        XCTAssertTrue(chat.live?.waitingForInput == true)
        XCTAssertEqual(chat.pendingInteractions.map(\.id.interactionId), [form.id!])
        chat.dispose()
        await chat.load()
        try await eventually { chat.live?.waitingForInput == true }
        XCTAssertTrue(chat.live?.waitingForInput == true)
        XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
        let answers = Dictionary(uniqueKeysWithValues: form.displayQuestions.map {
            ($0.id, DaemonQuestionAnswer(options: [($0.options?.first?.id)!], text: "Keep this feedback"))
        })
        let reply = DaemonInteractionReply(answers: answers)
        await channel.holdResponse(fail: true)
        let first = Task { await chat.respond(to: form, answer: reply) }
        try await eventually { chat.respondingInteractions.contains(form.id!) }
        try await eventually { await channel.responseBodies.count == 1 }
        await chat.respond(to: form, answer: reply)
        let firstRequests = await channel.responseBodies
        XCTAssertEqual(firstRequests.count, 1, "Double tap must not submit twice")
        await channel.releaseResponse()
        await first.value
        XCTAssertTrue(chat.live?.waitingForInput == true, "A rejected answer keeps the form available")
        XCTAssertEqual(chat.pendingInteractions.count, 1, "Failed replies keep the pinned request available")
        XCTAssertNotNil(chat.turnError)
        XCTAssertTrue(chat.respondingInteractions.isEmpty)
        await chat.respond(to: form, answer: reply)
        XCTAssertFalse(chat.live?.waitingForInput == true)
        XCTAssertTrue(chat.pendingInteractions.isEmpty, "Acknowledged questions leave the composer")
        XCTAssertNil(chat.turnError)
        let bodies = await channel.responseBodies
        let sent = try JSONDecoder().decode(DaemonInteractionReply.self, from: XCTUnwrap(bodies.last))
        XCTAssertEqual(sent.answers, answers)
        chat.dispose()
        await chat.respond(to: form, answer: reply)
        let requests = await channel.requests
        XCTAssertFalse(requests.contains { $0.hasPrefix("POST /turns") }, "History replies must never become new messages")
        XCTAssertEqual(requests.filter { $0.hasPrefix("POST /runs/run/respond") }.count, 2)
        await chat.load()
        XCTAssertFalse(chat.live?.waitingForInput == true, "Resolved requests stay resolved after reopening")
    }

    func testLiveFileCreationSurvivesSuccessfulHistoryHandoffAndReopen() async throws {
        for agent in ["codex", "claude"] {
            let channel = ReattachChannel(running: false)
            let chat = model(channel, agent: agent, activity: ChatActivityStore())
            let host = UIHostingController(rootView: ChatTranscriptView(model: chat))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            defer { chat.dispose(); window.isHidden = true }
            await chat.load()
            await chat.send("Build an app")
            try await eventually { chat.animatesLiveUpdates }
            for index in 0..<5 {
                await channel.publish(DaemonEvent(type: .tool_result, tool: DaemonToolEvent(
                    id: "file-\(index)", name: "apply_patch", output: "Created file", action:
                        DaemonToolAction(kind: "file_edit", files: [DaemonFileChange(
                            path: "Sources/File\(index).swift", op: "add", diff:
                                "@@ -0,0 +1,30 @@\n" + (0..<30).map { "+let value\($0) = \($0)" }.joined(separator: "\n"))]))))
                try await eventually { chat.live?.toolIndexByID.count == index + 1 }
            }
            await channel.publish(DaemonEvent(type: .text, itemId: "answer", text: "Created the test project."))
            try await eventually { chat.live?.text == "Created the test project." }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(chat.autoExpandedToolIDs.count, 5)
            let streamed = try XCTUnwrap(chat.live?.parts)
            host.view.layoutIfNeeded()
            attach(host, name: "\(agent) live file creation")
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)

            await channel.complete(.done)
            try await eventually { !chat.thinking }
            XCTAssertNil(chat.turnError)
            XCTAssertEqual(chat.messages.count, 2)
            XCTAssertEqual(chat.messages.last?.parts, streamed)
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            let completedScroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertGreaterThan(completedScroll.contentSize.height, completedScroll.bounds.height, "Completing the turn must keep the file cards")
            XCTAssertLessThanOrEqual(completedScroll.contentSize.height - completedScroll.contentOffset.y - completedScroll.bounds.height, 60,
                                     "Completion must keep the final response visible")
            XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("Created the test project."),
                          "The saved answer must still be drawn after completion")
            attach(host, name: "\(agent) completed file creation")

            chat.dispose()
            await chat.load()
            XCTAssertFalse(chat.thinking)
            XCTAssertNil(chat.loadError)
            XCTAssertEqual(chat.messages.last?.parts, streamed)
            XCTAssertTrue(chat.autoExpandedToolIDs.isEmpty)
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let restoredScroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertLessThanOrEqual(restoredScroll.contentSize.height - restoredScroll.contentOffset.y - restoredScroll.bounds.height, 60)
            XCTAssertTrue(try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host)).contains("Created the test project."),
                          "Restored history must be visible, not just present in the model")
            attach(host, name: "\(agent) reopened file creation")
        }
    }

    func testAsyncHistoryAnswerUsesOriginatingRunThenAttachesResumedRun() async throws {
        let channel = ReattachChannel(running: true)
        let form = try InteractionFixtures.form("codex-async")
        await channel.publish(DaemonEvent(type: .interaction, interaction: form))
        await channel.complete(.done)
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        XCTAssertFalse(chat.thinking)
        XCTAssertTrue(chat.messages.last?.parts?.first?.interaction?.needsResponse == true)
        XCTAssertEqual(chat.pendingInteractions.map(\.id.runId), ["run"])
        chat.dispose()
        await chat.load()
        XCTAssertEqual(chat.pendingInteractions.map(\.id.runId), ["run"], "Unanswered async questions return above the composer")
        let answers = Dictionary(uniqueKeysWithValues: form.displayQuestions.map {
            ($0.id, DaemonQuestionAnswer(options: [($0.options?.first?.id)!], text: "Keep the feedback"))
        })
        await channel.holdResponse(fail: true)
        let reply = DaemonInteractionReply(answers: answers)
        let first = Task { await chat.respond(to: form, answer: reply) }
        try await eventually { await channel.responseBodies.count == 1 }
        await chat.respond(to: form, answer: reply)
        await channel.releaseResponse()
        await first.value
        XCTAssertNotNil(chat.turnError)
        XCTAssertTrue(chat.messages.last?.parts?.first?.interaction?.needsResponse == true)
        await chat.respond(to: form, answer: reply)
        try await eventually { chat.thinking && chat.animatesLiveUpdates }
        XCTAssertNil(chat.turnError)
        let resolved = chat.messages.flatMap { $0.parts ?? [] }.compactMap(\.interaction).first { $0.id == form.id }
        XCTAssertEqual(resolved?.response?.answers, answers)
        XCTAssertFalse(resolved?.needsResponse == true)
        XCTAssertTrue(chat.pendingInteractions.isEmpty)
        let requests = await channel.requests
        XCTAssertEqual(requests.filter { $0.hasPrefix("POST /runs/run/respond") }.count, 2)
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /runs/resumed/snapshot") })
        XCTAssertFalse(requests.contains { $0.hasPrefix("POST /turns") }, "The daemon owns resuming and duplicate prevention")
        chat.dispose()
        await chat.load()
        try await eventually { chat.thinking }
        XCTAssertFalse(chat.messages.flatMap { $0.parts ?? [] }.contains { $0.interaction?.id == form.id && $0.interaction?.needsResponse == true })
    }

    func testAsyncChoiceDraftSurvivesTheLiveToHistoryHandoff() async throws {
        let channel = ReattachChannel(running: true)
        let form = try InteractionFixtures.form("codex-async")
        await channel.publish(DaemonEvent(type: .interaction, interaction: form))
        let chat = model(channel, activity: ChatActivityStore())
        defer { chat.dispose() }
        await chat.load()
        try await eventually { chat.live?.parts.contains { $0.interaction?.id == form.id } == true }
        let requestID = try XCTUnwrap(chat.pendingInteractions.first?.id)
        let draft = chat.interactionDraft(for: form)
        draft.answers["question-1"] = .init(options: ["Green"], text: "Keep this unfinished feedback")
        await channel.complete(.done)
        try await eventually { !chat.thinking }
        let historical = try XCTUnwrap(chat.messages.flatMap { $0.parts ?? [] }.compactMap(\.interaction).first { $0.id == form.id })
        XCTAssertTrue(historical.needsResponse == true)
        XCTAssertEqual(chat.pendingInteractions.map(\.id), [requestID], "The answer sheet retains the same request as the turn finishes")
        XCTAssertTrue(chat.interactionDraft(for: historical) === draft)
        XCTAssertEqual(chat.interactionDraft(for: historical).answers["question-1"]?.text, "Keep this unfinished feedback")
    }

    func testNativeHistoryAfterLiveAsyncReplyDoesNotRegraftTheEarlierForm() throws {
        let form = try InteractionFixtures.form("codex-async")
        let prefix: [DaemonMessagePart] = [.init(kind: .text, id: "intro", text: "I will ask now."),
                                            .init(kind: .interaction, interaction: form)]
        let final = DaemonMessagePart(kind: .text, id: "final", text: "You selected Green.")
        let native = [
            DaemonMessage(id: "user", chatId: "chat", role: .user, text: "Ask a question", createdAt: "2026-09-19T00:00:00Z"),
            DaemonMessage(id: "before", chatId: "chat", role: .assistant, text: "I will ask now.", createdAt: "2026-09-19T00:00:01Z", parts: prefix),
            DaemonMessage(id: "steer", chatId: "chat", role: .user, text: "Green", createdAt: "2026-09-19T00:00:02Z"),
            DaemonMessage(id: "after", chatId: "chat", role: .assistant, text: "You selected Green.", createdAt: "2026-09-19T00:00:03Z", parts: [final])
        ]
        var live = LiveTurn()
        live.parts = prefix + [final]
        let run = DaemonRun(id: "run", chatId: "chat", status: .done, replyId: "recorded-reply", createdAt: "2026-09-19T00:00:00Z")
        let completion = ChatTurnCompletion.reconcile(current: [], fetched: native, live: live, run: run,
                                                     runId: "run", baselineIDs: [], pendingUser: nil)
        XCTAssertEqual(completion.messages.count, native.count)
        XCTAssertEqual(completion.messages[1].parts, prefix)
        XCTAssertEqual(completion.messages[3].parts, [final])
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func transcriptTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView, table.accessibilityIdentifier == "chat.transcript" { return table }
        return view.subviews.lazy.compactMap { self.transcriptTable(in: $0) }.first
    }

    private func attach(_ host: UIViewController, name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        attach(image, name: name)
    }

    private func attach(_ image: UIImage, name: String) {
        // XCTest carries these captures off a physical iPhone. An absolute /tmp
        // path is outside its app container and is not a portable export path.
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private func fileEvent(_ id: String) -> DaemonEvent {
    DaemonEvent(type: .tool_result, tool: DaemonToolEvent(id: id, name: "apply_patch", output: "Created file",
        action: DaemonToolAction(kind: "file_edit", files: [
            DaemonFileChange(path: "\(id).swift", op: "add", diff: "@@ -0,0 +1 @@\n+let value = 1")
        ])))
}

@MainActor @Observable
private final class ChatScenePhaseFixture {
    var phase: ScenePhase = .active
    var showsChat = true
}

private struct ChatSceneLifecycleHost: View {
    let state: ChatScenePhaseFixture
    let fixture: AppStoreFixture
    var body: some View {
        NavigationStack {
            if state.showsChat { ChatScreen(chatId: fixture.chatID, draft: "Keep this draft") }
        }
            .environment(fixture.app)
            .environment(\.stores, fixture.stores)
            .environment(\.scenePhase, state.phase)
    }
}

private actor ReattachChannel: StreamingDaemonChannel {
    nonisolated let label = "reconnection-fixture"
    private let chatID: String
    private(set) var current: DaemonRun?
    private(set) var requests: [String] = []
    private(set) var opens = 0
    private(set) var cancels = 0
    private(set) var historyReads = 0
    private(set) var historyDownloads = 0
    private(set) var artifactReads = 0
    private var artifacts: [String: Data] = [:]
    private(set) var responseBodies: [Data] = []
    private(set) var turnReceipts: [String] = []
    private var receiptSupport = false
    private var queuedInputVersion: Int?
    private var finishBeforeSend = false
    private var loseTurnAcknowledgement = false
    var subscriberCount: Int { subscribers.count }
    private var messages: [DaemonMessage] = []
    private var events: [DaemonEvent] = []
    private var subscribers: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var historyHeld = false
    private var snapshotHeld = false
    private(set) var snapshotReads = 0
    private var snapshotGate: CheckedContinuation<Void, Never>?
    private var sendHeld = false
    private var cancelHeld = false
    private var cancelRejected = false
    private var uploadHeld = false
    private var attachmentUploadVersion = 0
    private var uploadGate: CheckedContinuation<Void, Never>?
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var finishOnHistory = false
    private var historyGate: CheckedContinuation<Void, Never>?
    private var sendGate: CheckedContinuation<Void, Never>?
    private let snapshots: Bool
    private let sequenced: Bool
    private let conditionalHistory: Bool
    private let supportsImages: Bool
    private var replayHeld = false
    private var responseHeld = false
    private var responseFailure = false
    private var responseGate: CheckedContinuation<Void, Never>?
    private var sendRejected = false
    private var sendCancelled = false
    private var staleSoftware = false

    init(running: Bool, snapshots: Bool = true, history: [DaemonMessage] = [], chatID: String = "chat", sequenced: Bool = true, conditionalHistory: Bool = false, supportsImages: Bool = false) {
        self.chatID = chatID
        self.snapshots = snapshots
        self.sequenced = sequenced
        self.conditionalHistory = conditionalHistory
        self.supportsImages = supportsImages
        messages = history
        if running {
            current = DaemonRun(id: "run", chatId: chatID, status: .running, createdAt: "2026-09-14T10:00:00Z")
            messages = [DaemonMessage(id: "user", chatId: chatID, role: .user, text: "Build an app", createdAt: "2026-09-14T10:00:00Z")]
        }
    }

    func holdHistory() { historyHeld = true }
    func holdSnapshot() { snapshotHeld = true }
    func releaseSnapshot() { snapshotHeld = false; snapshotGate?.resume(); snapshotGate = nil }
    func enableQueuedInput(version: Int = 1) { queuedInputVersion = version; receiptSupport = true }
    func completeBeforeNextSend() { finishBeforeSend = true }
    func acceptQueuedInputs() {
        for i in (current?.inputs ?? []).indices where current?.inputs?[i].isQueued == true {
            current?.inputs?[i].status = "accepted"
            publish(DaemonEvent(type: .input, input: current?.inputs?[i]))
        }
    }
    func rejectSend() { sendRejected = true }
    func holdCancel() { cancelHeld = true }
    func rejectNextCancel() { cancelRejected = true }
    func releaseCancel() { cancelHeld = false; cancelGate?.resume(); cancelGate = nil }
    func holdUpload() { attachmentUploadVersion = 1; uploadHeld = true }
    func releaseUpload() { uploadHeld = false; uploadGate?.resume(); uploadGate = nil }
    func cancelNextSend() { sendCancelled = true }
    func reportStaleSoftware() { staleSoftware = true }
    func failActiveTurn(_ error: String) {
        current?.error = error
        publish(DaemonEvent(type: .error, error: error))
        publish(DaemonEvent(type: .result, result: .init(text: error, isError: true)))
        complete(.error)
    }
    func seedHistory(_ history: [DaemonMessage]) { messages = history }
    func seedArtifact(_ id: String, data: Data) { artifacts[id] = data }
    func releaseHistory() { historyHeld = false; historyGate?.resume(); historyGate = nil }
    func holdSend() { sendHeld = true }
    func loseFirstTurnAcknowledgement() { receiptSupport = true; loseTurnAcknowledgement = true }
    func releaseSend() { sendHeld = false; sendGate?.resume(); sendGate = nil }
    func completeDuringHistoryRead() { finishOnHistory = true }
    func holdResponse(fail: Bool) { responseHeld = true; responseFailure = fail }
    func releaseResponse() { responseHeld = false; responseGate?.resume(); responseGate = nil }
    func holdReplay() { replayHeld = true }
    func releaseReplay() {
        replayHeld = false
        let data = try! JSONEncoder().encode(DaemonEvent(type: .status, meta: ["stream": .string("ready")]))
        for continuation in subscribers.values { continuation.yield(data) }
    }

    func disconnect() {
        for continuation in subscribers.values { continuation.finish(throwing: URLError(.networkConnectionLost)) }
        subscribers.removeAll()
    }

    func startNextRun() {
        events = []
        current = DaemonRun(id: "next-run", chatId: chatID, status: .running, createdAt: "2026-09-14T10:02:00Z")
        messages.append(.init(id: "next-user", chatId: chatID, role: .user, text: "Continue the work", createdAt: current!.createdAt))
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        requests.append("\(method) \(path)")
        let rawEndpoint = path.split(separator: "?")[0].replacingOccurrences(of: "/chats/\(chatID)/", with: "/chats/chat/")
        let components = rawEndpoint.split(separator: "/")
        let endpoint = components.first == "runs" && components.count >= 2
            ? "/runs/run" + components.dropFirst(2).map { "/\($0)" }.joined()
            : rawEndpoint
        if method == "GET", endpoint.hasPrefix("/artifacts/"),
           let id = endpoint.split(separator: "/").last, let data = artifacts[String(id)] {
            artifactReads += 1
            return try response(["data": data.base64EncodedString()])
        }
        if method == "PUT", endpoint.contains("/attachments/"), let jsonBody {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonBody) as? [String: Any])
            value["id"] = String(endpoint.split(separator: "/").last!)
            value["offset"] = value["bytes"]
            value["complete"] = true
            value.removeValue(forKey: "data")
            if uploadHeld { await withCheckedContinuation { uploadGate = $0 } }
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        switch (method, endpoint) {
        case ("GET", "/healthz"):
            return (200, "{\"ok\":true,\"turnRequestVersion\":\(receiptSupport ? 1 : 0),\"queuedInputVersion\":\(queuedInputVersion ?? 0),\"imageAttachmentsVersion\":1,\"attachmentUploadVersion\":\(attachmentUploadVersion)}")
        case ("GET", "/setup"):
            return (200, #"{"ok":true,"steps":[]}"#)
        case ("GET", "/agent"):
            let software = staleSoftware ? DaemonHarnessSoftware(policyVersion: 1, installedVersion: "0.160.0", compatibility: "incompatible",
                managed: true, updateAvailable: true, requiresDaemonUpdate: false, catalogRevision: 1, catalogSource: "fixture", catalogStale: true) : nil
            return try response(DaemonAgentInfo(version: "0.1.42", agentType: "codex", name: "Codex",
                capabilities: queuedInputVersion == nil ? (supportsImages ? .init(imageInput: true) : nil)
                    : .init(imageInput: true, input: true, queuedInput: true), schema: .empty,
                installedVersion: "0.160.0", software: software, configured: true))
        case ("GET", "/runs/run/snapshot"), ("GET", "/runs/resumed/snapshot"):
            snapshotReads += 1
            guard snapshots, let current else { return (404, "") }
            var turn = LiveTurn()
            for event in events { turn.apply(event) }
            let checkpoint = DaemonRunSnapshot(run: current, sequence: events.count, parts: turn.parts)
            if snapshotHeld {
                snapshotHeld = false
                await withCheckedContinuation { snapshotGate = $0 }
            }
            return try response(checkpoint)
        case ("GET", "/chats/chat/run"), ("GET", "/runs/run"), ("GET", "/runs/resumed"):
            guard let current else { return (204, "") }
            return try response(current)
        case ("GET", "/chats/chat/messages"):
            historyReads += 1
            if conditionalHistory {
                struct Page: Encodable {
                    let messages: [DaemonMessage]; let hasMore: Bool; let before: String?
                    let revision: String; let notModified: Bool
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let revision = SHA256.hash(data: try encoder.encode(messages)).map { String(format: "%02x", $0) }.joined()
                let query = URLComponents(string: path)?.queryItems ?? []
                if query.first(where: { $0.name == "before" }) == nil,
                   query.first(where: { $0.name == "ifRevision" })?.value == revision {
                    return try response(Page(messages: [], hasMore: false, before: nil, revision: revision, notModified: true))
                }
                historyDownloads += 1
                let result = page(messages, path: path)
                return try response(Page(messages: result, hasMore: result.first?.id != messages.first?.id,
                                         before: result.first?.id, revision: revision, notModified: false))
            }
            if historyHeld {
                historyHeld = false
                let snapshot = messages
                await withCheckedContinuation { historyGate = $0 }
                return try response(page(snapshot, path: path))
            }
            if finishOnHistory { finishOnHistory = false; complete(.done) }
            return try response(page(messages, path: path))
        case ("POST", "/turns"):
            if sendCancelled { sendCancelled = false; throw CancellationError() }
            if sendRejected { return (409, #"{"error":"This Codex conversation is open in another client. Close it there, then try sending again."}"#) }
            if queuedInputVersion != nil, let jsonBody {
                struct Body: Decodable {
                    struct Options: Decodable { var attachments: [DaemonAttachment]? }
                    var requestId: String
                    var message: String
                    var queueIfRunning: Bool?
                    var options: Options?
                    var attachments: [DaemonAttachment]? { options?.attachments }
                }
                let body = try JSONDecoder().decode(Body.self, from: jsonBody)
                turnReceipts.append(body.requestId)
                if current?.inputs?.contains(where: { $0.id == body.requestId }) == true { return try response(current!) }
                if finishBeforeSend {
                    finishBeforeSend = false
                    complete(.done)
                    events = []
                    current = DaemonRun(id: "resumed", chatId: "chat", status: .running, createdAt: "2026-09-14T10:02:00Z")
                    messages.append(DaemonMessage(id: "next-user", chatId: "chat", role: .user, text: body.message,
                        createdAt: "2026-09-14T10:02:00Z", attachments: body.attachments))
                    return try response(current!)
                }
                guard body.queueIfRunning == true, current?.status == .running else { return (409, "No active run") }
                let input = DaemonUserInput(id: body.requestId, text: body.message, attachments: body.attachments,
                    createdAt: "2026-09-14T10:00:30Z", status: "queued")
                let inputs = (current?.inputs ?? []) + [input]
                current?.inputs = inputs
                publish(DaemonEvent(type: .input, input: input))
                let admitted = current!
                if sendHeld { await withCheckedContinuation { sendGate = $0 } }
                if loseTurnAcknowledgement {
                    loseTurnAcknowledgement = false
                    return (500, #"{"error":"Fixture acknowledgement lost"}"#)
                }
                return try response(admitted)
            }
            if receiptSupport, let jsonBody {
                let body = try JSONDecoder().decode(JSONValue.self, from: jsonBody)
                turnReceipts.append(body["requestId"]?.string ?? "")
                if let current { return try response(current) }
            }
            // A new daemon turn always has its own identity and replay buffer.
            // Reusing a cancelled ID would incorrectly make the next request stale.
            let nextRunID = current == nil ? "run" : UUID().uuidString
            if current != nil { events = [] }
            current = DaemonRun(id: nextRunID, chatId: "chat", status: .running, createdAt: "2026-09-14T10:00:00Z")
            messages = [DaemonMessage(id: "user", chatId: "chat", role: .user, text: "Build an app", createdAt: "2026-09-14T10:00:00Z")]
            if sendHeld { await withCheckedContinuation { sendGate = $0 } }
            if loseTurnAcknowledgement {
                loseTurnAcknowledgement = false
                return (500, #"{"error":"Fixture acknowledgement lost"}"#)
            }
            return try response(current!)
        case ("POST", "/runs/run/cancel"), ("POST", "/runs/resumed/cancel"):
            cancels += 1
            if cancelRejected { cancelRejected = false; return (409, #"{"error":"Stop was not accepted"}"#) }
            complete(.cancelled)
            if cancelHeld { await withCheckedContinuation { cancelGate = $0 } }
            return (200, "{}")
        case ("POST", "/runs/run/respond"):
            if let jsonBody { responseBodies.append(jsonBody) }
            if responseHeld { await withCheckedContinuation { responseGate = $0 } }
            if responseFailure { responseFailure = false; return (400, #"{"error":"Please complete the form"}"#) }
            if let jsonBody, let body = try? JSONDecoder().decode(JSONValue.self, from: jsonBody),
               let id = body["interactionId"]?.string,
               var interaction = events.last(where: { $0.interaction?.id == id })?.interaction {
                interaction.needsResponse = false
                interaction.response = try? JSONDecoder().decode(DaemonInteractionReply.self, from: jsonBody)
                if interaction.isMessageQuestion, current?.status != .running {
                    for i in messages.indices {
                        guard var parts = messages[i].parts else { continue }
                        for j in parts.indices where parts[j].interaction?.id == id { parts[j].interaction = interaction }
                        messages[i].parts = parts
                    }
                    current = DaemonRun(id: "resumed", chatId: "chat", status: .running, createdAt: "2026-09-14T10:02:00Z")
                    events = []
                    messages.append(DaemonMessage(id: "answer", chatId: "chat", role: .user,
                        text: "Blue, Plain text", createdAt: "2026-09-14T10:02:00Z"))
                } else { publish(DaemonEvent(type: .interaction, interaction: interaction)) }
            }
            return (200, "{}")
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        requests.append("\(method) \(path)")
        opens += 1
        let cursor = URLComponents(string: path)?.queryItems?.first { $0.name == "after" }?.value.flatMap(Int.init) ?? 0
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        continuation.yield(try JSONEncoder().encode(DaemonEvent(type: .status, meta: ["stream": .string("open")])))
        for var event in events where !sequenced || (event.sequence ?? 0) > cursor {
            event.replay = true
            continuation.yield(try JSONEncoder().encode(event))
        }
        if !replayHeld { continuation.yield(try JSONEncoder().encode(DaemonEvent(type: .status, meta: ["stream": .string("ready")]))) }
        if current?.status != .running { continuation.finish() }
        return stream
    }

    func publish(_ event: DaemonEvent) {
        var event = event
        event.sequence = sequenced ? events.count + 1 : nil
        events.append(event)
        let data = try! JSONEncoder().encode(event)
        for continuation in subscribers.values { continuation.yield(data) }
    }

    func complete(_ status: RunStatus, history: [DaemonMessage]? = nil) {
        for i in (current?.inputs ?? []).indices where current?.inputs?[i].isQueued == true {
            current?.inputs?[i].status = status == .cancelled ? "cancelled" : "failed"
            publish(DaemonEvent(type: .input, input: current?.inputs?[i]))
        }
        current?.status = status
        current?.endedAt = "2026-09-14T10:01:00Z"
        current?.replyId = "reply"
        var turn = LiveTurn()
        for event in events { turn.apply(event) }
        messages.append(DaemonMessage(id: "reply", chatId: "chat", role: .assistant, text: turn.text,
            createdAt: "2026-09-14T10:01:00Z", parts: turn.parts))
        if let history { messages = history }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func remove(_ id: UUID) { subscribers[id] = nil }
    private func page(_ history: [DaemonMessage], path: String) -> [DaemonMessage] {
        let query = URLComponents(string: path)?.queryItems ?? []
        let before = query.first { $0.name == "before" }?.value
        let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? history.count
        let end = before.flatMap { id in history.firstIndex { $0.id == id } } ?? history.count
        return Array(history[..<end].suffix(limit))
    }
    private func response<T: Encodable>(_ value: T) throws -> (Int, String) {
        (200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}


private actor BytePagedHistoryChannel: DaemonChannel {
    nonisolated var label: String { "byte-paged-history-fixture" }
    private(set) var reads = 0

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if path.contains("/run?") { return (204, "") }
        guard path.contains("/messages?") else { return (404, "") }
        reads += 1
        let query = URLComponents(string: "http://fixture" + path)?.queryItems ?? []
        let before = query.first { $0.name == "before" }?.value
        let ids: [String]
        switch before {
        case "3": ids = ["1", "2"]
        case "1": ids = ["0"]
        default: ids = ["3", "4"]
        }
        let body: [String: Any] = [
            "messages": ids.map { ["id": $0, "chatId": "chat", "role": "assistant",
                "text": "Saved message \($0)", "createdAt": "2026-09-25T10:00:00Z"] },
            "hasMore": ids.first != "0", "before": ids[0]
        ]
        return (200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
    }
}
