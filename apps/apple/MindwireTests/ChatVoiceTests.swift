import AVFoundation
import XCTest
@testable import Mindwire

@MainActor
final class ChatVoiceTests: XCTestCase {
    func testPermissionIsRequestedOnceAndLateApprovalCannotStartAfterCancel() async throws {
        let fixture = Fixture()
        var permission: CheckedContinuation<Bool, Never>?
        let model = fixture.model(permission: { await withCheckedContinuation { permission = $0 } })
        model.start(); model.start()
        try await eventually { permission != nil }
        XCTAssertEqual(fixture.captures.count, 0)
        model.cancel()
        permission?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(fixture.captures.isEmpty)
    }

    func testDeniedPermissionLeavesClearRecoveryAndNeverCreatesAudio() async throws {
        let fixture = Fixture()
        let model = fixture.model(permission: { false })
        model.start()
        try await eventually { model.phase == .failed }
        XCTAssertTrue(model.microphoneDenied)
        XCTAssertFalse(model.canAdd)
        XCTAssertTrue(fixture.captures.isEmpty)
        model.cancel()
    }

    func testDefaultRecordingStaysAudioAndTranscriptionOnlyRunsWhenRequested() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.cancel() }
        model.start(); model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 4
        model.finishRecording(); model.finishRecording()
        XCTAssertEqual(model.phase, .review)
        XCTAssertTrue(model.includeRecording)
        XCTAssertEqual(fixture.transcriber.calls, 0)
        XCTAssertTrue(model.transcript.isEmpty)
        model.transcribeRecording(); model.transcribeRecording()
        try await eventually { model.phase == .review }
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertEqual(fixture.captures[0].stops, 1)
        XCTAssertEqual(fixture.transcriber.calls, 1)
        XCTAssertTrue(fixture.transcriber.sawStoppedCapture)
        XCTAssertEqual(model.transcript, "Review the latest changes.")
        model.transcript = "Review the latest changes and run tests."
        model.includeRecording = false
        let draft = try await model.draft()
        XCTAssertEqual(draft.text, model.transcript)
        XCTAssertNil(draft.attachment, "Audio is only shared when selected")
    }

    func testTranscriptionFailureKeepsUnmodifiedAudioThroughDraftAndCleanup() async throws {
        let fixture = Fixture()
        fixture.transcriber.failure = ChatVoiceError.transcriptionUnavailable
        let model = fixture.model()
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 3
        model.finishRecording(transcribe: true)
        try await eventually { model.phase == .review }
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.includeRecording)
        XCTAssertTrue(model.canAdd)
        let draft = try await model.draft()
        let recording = try XCTUnwrap(draft.attachment)
        XCTAssertTrue(recording.isAudio)
        XCTAssertEqual(recording.mime, "audio/mp4")
        XCTAssertEqual(recording.data, fixture.audio)
        XCTAssertTrue(recording.name?.hasSuffix(".m4a") == true)
        let files = ChatImageDraft()
        try files.append(recording)
        let file = fixture.captures[0].url
        model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(files.attachments, [recording], "The composer's copy survives recording cleanup")
    }

    func testCancelledTranscriptionCannotReviveADeletedRecordingOrDraft() async throws {
        let fixture = Fixture()
        fixture.transcriber.waitForCompletion = true
        let model = fixture.model()
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 4
        model.finishRecording(transcribe: true)
        try await eventually { fixture.transcriber.completion != nil }
        model.cancel()
        fixture.transcriber.partial?("Late text")
        fixture.transcriber.completion?.resume(returning: "Late result")
        await Task.yield()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertFalse(model.hasRecording)
    }

    func testFileFallbackIgnoresLateSpeechResultsAndRetainsUserEdits() async throws {
        let fixture = Fixture()
        fixture.transcriber.waitForCompletion = true
        let model = fixture.model()
        defer { model.cancel() }
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 4
        model.finishRecording(transcribe: true)
        try await eventually { fixture.transcriber.completion != nil }
        model.keepRecordingInstead()
        model.transcript = "My voice note"
        fixture.transcriber.partial?("Must not overwrite")
        fixture.transcriber.completion?.resume(returning: "Must not overwrite")
        await Task.yield()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.transcript, "My voice note")
        XCTAssertTrue(model.includeRecording)
        let draft = try await model.draft()
        XCTAssertNotNil(draft.attachment)
    }

    func testBackgroundStopsMicrophoneAndKeepsFileWithoutStartingSpeech() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.cancel() }
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 4
        model.suspend()
        XCTAssertEqual(fixture.captures[0].stops, 1)
        XCTAssertEqual(fixture.transcriber.calls, 0)
        XCTAssertEqual(model.phase, .review)
        XCTAssertTrue(model.includeRecording)
        let draft = try await model.draft()
        XCTAssertNotNil(draft.attachment)
        model.transcribeRecording()
        try await eventually { model.phase == .review }
        XCTAssertEqual(fixture.transcriber.calls, 1)
        XCTAssertTrue(model.includeRecording, "Optional transcription does not silently replace the audio")
    }

    func testInterruptionKeepsAudioWithoutStartingSpeech() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.cancel() }
        model.start()
        try await eventually { model.phase == .recording }
        let capture = fixture.captures[0]
        capture.elapsed = 3
        capture.onInterruption?("Recording interrupted")
        try await eventually { model.phase == .review }
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(fixture.transcriber.calls, 0)
        XCTAssertTrue(model.includeRecording)
        XCTAssertEqual(model.notice, "Recording interrupted")
    }

    func testDurationLimitFinalizesWithoutUnboundedRecordingOrWaveform() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.cancel() }
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = ChatVoiceModel.maximumDuration + 1
        try await eventually { model.phase == .review }
        XCTAssertEqual(model.elapsed, ChatVoiceModel.maximumDuration)
        XCTAssertLessThanOrEqual(model.levels.count, ChatVoiceWaveform.barCount)
        XCTAssertEqual(fixture.captures[0].stops, 1)
    }

    func testEmptyRecordingFailsWithoutSendingOrRetainingAFile() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.cancel() }
        model.start()
        try await eventually { model.phase == .recording }
        fixture.captures[0].elapsed = 0.01
        model.finishRecording()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.canAdd)
        XCTAssertEqual(fixture.transcriber.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.captures[0].url.path))
    }

    func testWaveformKeepsShortPeaksAndHandlesSilenceWithoutNaN() {
        XCTAssertEqual(ChatVoiceWaveform.normalizedLevel(decibels: -.infinity), 0)
        XCTAssertEqual(ChatVoiceWaveform.normalizedLevel(decibels: .nan), 0)
        XCTAssertEqual(ChatVoiceWaveform.normalizedLevel(decibels: -160), 0)
        XCTAssertEqual(ChatVoiceWaveform.normalizedLevel(decibels: 10), 1)
        var levels = [Float](repeating: 0, count: 12_000)
        levels[9_990] = 0.95
        let reduced = ChatVoiceWaveform.summary(levels)
        XCTAssertEqual(reduced.count, ChatVoiceWaveform.barCount)
        XCTAssertEqual(reduced.max(), 0.95)
    }

    func testSpokenLanguageFollowsSavedChoiceThenKeyboardIncludingArabic() {
        let choices = [ChatVoiceLanguage(id: "en-US", label: "English"), .init(id: "ar-SA", label: "Arabic")]
        XCTAssertEqual(ChatVoiceLanguage.preferred(saved: nil, keyboard: "ar", choices: choices, languages: ["en-US"]), "ar-SA")
        XCTAssertEqual(ChatVoiceLanguage.preferred(saved: "en_US", keyboard: "ar", choices: choices), "en-US")
        XCTAssertEqual(ChatVoiceLanguage.preferred(saved: nil, keyboard: nil, choices: choices, languages: ["ar-EG"]), "ar-SA")
    }

    private func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<100 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Voice state did not settle")
        throw ChatVoiceError.recordingFailed
    }

    @MainActor private final class Fixture {
        let audio = Data("fixture AAC payload".utf8)
        var captures: [Capture] = []
        let transcriber = Transcriber()
        func model(permission: @escaping () async -> Bool = { true }) -> ChatVoiceModel {
            transcriber.captureStopped = { [weak self] in self?.captures.last?.stops == 1 }
            return .init(dependencies: .init(requestPermission: permission, makeCapture: { [unowned self] url in
                let capture = Capture(url: url, data: self.audio)
                self.captures.append(capture)
                return capture
            }, transcription: transcriber), language: "en-US")
        }
    }

    @MainActor private final class Capture: ChatVoiceCapturing {
        let url: URL, data: Data
        var elapsed: TimeInterval = 0
        var stops = 0
        var onInterruption: ((String) -> Void)?
        init(url: URL, data: Data) { self.url = url; self.data = data }
        func start() throws { try data.write(to: url) }
        func level() -> Float { 0.4 }
        func stop() { stops += 1 }
    }

    @MainActor private final class Transcriber: ChatVoiceTranscribing {
        var calls = 0
        var failure: Error?
        var waitForCompletion = false
        var completion: CheckedContinuation<String, Never>?
        var partial: ((String) -> Void)?
        var captureStopped: (() -> Bool)?
        var sawStoppedCapture = false
        func transcribe(url: URL, locale: Locale,
                        progress: @escaping (ChatVoiceTranscriptionProgress) -> Void,
                        partial: @escaping (String) -> Void) async throws -> String {
            calls += 1
            sawStoppedCapture = captureStopped?() == true
            progress(.init())
            self.partial = partial
            if let failure { throw failure }
            if waitForCompletion { return await withCheckedContinuation { completion = $0 } }
            return "Review the latest changes."
        }
    }
}
