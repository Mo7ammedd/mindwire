#if DEBUG
import UIKit
import XCTest

/// Real recording UI, AAC playback and composer/queue. Explicit fixtures never
/// open the user's microphone or send a recording to a live account.
final class ChatVoiceInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testHarnessVoiceIsSeparateFromRecordedAttachments() {
        let codex = launch(content: "empty")
        codex.buttons["chat.microphone"].tap()
        let start = codex.buttons["chat.voice.native.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), codex.debugDescription)
        XCTAssertTrue(start.isEnabled, "Native voice is a harness capability, even when the coding model has no audio modality")
        capture("Codex native voice with a separate recording option")
        codex.buttons["chat.voice.native.recordFile"].tap()
        let stop = codex.buttons["chat.voice.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), codex.debugDescription)
        stop.tap()
        codex.buttons["chat.voice.add"].tap()
        XCTAssertTrue(codex.buttons["chat.attachment"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(codex.buttons["chat.microphone"].exists)
        codex.terminate()

        let claude = launch(content: "empty", agent: "claude-code")
        claude.buttons["chat.microphone"].tap()
        let detail = claude.staticTexts["chat.voice.native.status"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5), claude.debugDescription)
        XCTAssertTrue(detail.label.contains("does not accept remote voice input"), detail.label)
        XCTAssertFalse(claude.buttons["chat.voice.native.start"].exists)
        XCTAssertTrue(claude.buttons["chat.voice.native.recordFile"].exists)
        capture("Claude explains its local microphone capability")
        claude.terminate()
    }

    func testRecordingStaysAudioCanPlayAndQueuesWhileAgentWorks() {
        let app = launch()
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 10))
        openRecording(app)
        let stop = app.buttons["chat.voice.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), app.debugDescription)
        let duration = app.staticTexts["chat.voice.duration"]
        let elapsed = NSPredicate { _, _ in (duration.label != "0:00") && duration.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: elapsed, object: nil)], timeout: 5), .completed)
        capture("Voice recording with live waveform")
        stop.tap()
        let add = app.buttons["chat.voice.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled, "An audio-only message needs no transcription")
        XCTAssertFalse(app.buttons["chat.voice.useRecording"].exists, "Stopping never starts speech processing")
        let play = app.buttons["chat.voice.play"]
        play.tap()
        XCTAssertEqual(play.label, "Pause recording")
        play.tap()
        XCTAssertEqual(play.label, "Play recording")
        capture("Audio-first review with playback and optional caption")
        add.tap()
        let attachment = app.buttons["chat.attachment"].firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(attachment.label.hasPrefix("Voice "))
        XCTAssertTrue(app.buttons["chat.stop"].exists)
        app.buttons["chat.send"].tap()
        let queue = app.buttons["chat.queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(queue.label.contains("Voice message"), queue.label)
        XCTAssertFalse(queue.label.contains("Image message"))
        capture("Original recording queued while the agent works")
        app.buttons["chat.stop"].tap()
        XCTAssertTrue(app.buttons["chat.stop"].waitForNonExistence(timeout: 5))
        queue.tap()
        let restore = app.buttons["Use as Draft"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), app.debugDescription)
        restore.tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), "Stopping retains the queued recording for retry")
        XCTAssertTrue(attachment.label.hasPrefix("Voice "))
        app.terminate()
    }

    func testCancelAndBackgroundNeverSendOrResumeMicrophoneAutomatically() {
        let app = launch(theme: "light")
        openRecording(app)
        XCTAssertTrue(app.buttons["chat.voice.stop"].waitForExistence(timeout: 5))
        app.buttons["chat.voice.cancel"].tap()
        XCTAssertTrue(app.buttons["chat.microphone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.attachment"].exists)
        openRecording(app)
        XCTAssertTrue(app.buttons["chat.voice.stop"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["chat.voice.add"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["chat.voice.stop"].exists)
        XCTAssertFalse(app.buttons["chat.voice.useRecording"].exists)
        capture("Interrupted recording remains available without restarting capture")
        app.buttons["chat.voice.cancel"].tap()
        XCTAssertFalse(app.buttons["chat.attachment"].exists)
        app.terminate()
    }

    func testOptionalTranscriptionKeepsArabicEditableAndPreservesExistingDraft() {
        let app = launch(scenario: "arabic", theme: "light")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap(); composer.typeText("Keep this note.")
        app.buttons["chat.tools"].tap()
        XCTAssertTrue(app.buttons["chat.addImage"].waitForExistence(timeout: 5))
        app.buttons["chat.addImage"].tap()
        app.buttons["Record an audio file"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.voice.stop"].waitForExistence(timeout: 5))
        app.buttons["chat.voice.stop"].tap()
        let transcribe = app.buttons["chat.voice.transcribe"]
        reveal(transcribe, app: app)
        transcribe.tap()
        let caption = app.descendants(matching: .any)["chat.voice.transcript"].firstMatch
        let text = NSPredicate { _, _ in caption.exists && (caption.value as? String)?.contains("راجع") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: text, object: nil)], timeout: 5), .completed)
        capture("Optional Arabic transcription with the original recording retained")
        app.buttons["chat.voice.add"].tap()
        XCTAssertTrue(app.buttons["chat.attachment"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this note.\nراجع التغييرات الأخيرة.")
        app.terminate()
    }

    func testDeniedPermissionOffersSettingsAndCanDismissCleanly() {
        let app = launch(scenario: "denied")
        openRecording(app)
        let retry = app.buttons["chat.voice.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(retry.label, "Open Settings")
        XCTAssertFalse(app.buttons["chat.voice.add"].exists)
        capture("Microphone permission recovery")
        app.buttons["chat.voice.cancel"].tap()
        XCTAssertTrue(app.buttons["chat.microphone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.attachment"].exists)
        app.terminate()
    }

    private func openRecording(_ app: XCUIApplication) {
        app.buttons["chat.microphone"].tap()
        let file = app.buttons["chat.voice.native.recordFile"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        file.tap()
    }

    private func launch(scenario: String = "normal", theme: String = "dark", content: String = "queue", agent: String = "codex") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": theme,
            "MINDWIRE_CHAT_TEST_CONTENT": content, "MINDWIRE_CHAT_AGENT": agent, "MINDWIRE_VOICE_FIXTURE": scenario]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["chat.microphone"].waitForExistence(timeout: 10))
        return app
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<3 where !element.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
