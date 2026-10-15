#if DEBUG
import AVFoundation
import Foundation

/// Only used by explicit UI-test launches. Normal builds always request the actual microphone.
@MainActor
enum ChatVoicePreview {
    static func model(scenario: String) -> ChatVoiceModel {
        .init(dependencies: .init(requestPermission: { scenario != "denied" },
            makeCapture: { Capture(url: $0) }, transcription: Transcription(scenario: scenario)),
            language: scenario == "arabic" ? "ar-SA" : "en-US")
    }

    private final class Capture: ChatVoiceCapturing {
        let url: URL
        var started: Date?
        var onInterruption: ((String) -> Void)?
        var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }
        init(url: URL) { self.url = url }
        func start() throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000)!
            buffer.frameLength = buffer.frameCapacity
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            try file.write(from: buffer)
            started = Date()
        }
        func level() -> Float { Float(abs(sin(elapsed * 11)) * 0.55 + abs(cos(elapsed * 4)) * 0.25) }
        func stop() { }
    }

    private struct Transcription: ChatVoiceTranscribing {
        let scenario: String
        func transcribe(url: URL, locale: Locale,
                        progress: @escaping (ChatVoiceTranscriptionProgress) -> Void,
                        partial: @escaping (String) -> Void) async throws -> String {
            progress(.init())
            try await Task.sleep(for: .milliseconds(scenario == "delayed" ? 30_000 : 350))
            if scenario == "unavailable" { throw ChatVoiceError.transcriptionUnavailable }
            let text = scenario == "arabic" ? "راجع التغييرات الأخيرة." : "Review the latest changes."
            partial(text)
            return text
        }
    }
}
#endif
