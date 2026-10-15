import AVFoundation
import Foundation
import Speech

struct ChatVoiceTranscriptionProgress {
    var preparing = false
    var fraction: Double? = nil
}

@MainActor
protocol ChatVoiceTranscribing {
    func transcribe(url: URL, locale: Locale,
                    progress: @escaping (ChatVoiceTranscriptionProgress) -> Void,
                    partial: @escaping (String) -> Void) async throws -> String
}

/// Both iOS 26 engines run on device. DictationTranscriber also supports older iPhones.
/// This translates speech into normal harness input; it doesn't pretend a file is native audio input.
@MainActor
struct ChatVoiceTranscription: ChatVoiceTranscribing {
    func transcribe(url: URL, locale: Locale,
                    progress: @escaping (ChatVoiceTranscriptionProgress) -> Void,
                    partial: @escaping (String) -> Void) async throws -> String {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            try await prepare(module, progress: progress)
            return try await analyze(url, module: module, results: module.results, partial: partial)
        }
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ChatVoiceError.transcriptionUnavailable
        }
        let module = DictationTranscriber(locale: supported, preset: .longDictation)
        try await prepare(module, progress: progress)
        return try await analyze(url, module: module, results: module.results, partial: partial)
    }

    private func prepare(_ module: any SpeechModule,
                         progress: @escaping (ChatVoiceTranscriptionProgress) -> Void) async throws {
        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            progress(.init(preparing: true, fraction: request.progress.fractionCompleted))
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in progress(.init(preparing: true, fraction: fraction)) }
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        }
        try Task.checkCancellation()
        progress(.init())
    }

    private func analyze<Results: AsyncSequence>(_ url: URL, module: any SpeechModule,
                                                 results: Results, partial: @escaping (String) -> Void) async throws -> String
    where Results.Element: SpeechModuleResult {
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        return try await withTaskCancellationHandler {
            let reader = Task { @MainActor () throws -> String in
                var pieces: [String] = []
                for try await result in results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text: String
                    if let result = result as? SpeechTranscriber.Result { text = String(result.text.characters) }
                    else if let result = result as? DictationTranscriber.Result { text = String(result.text.characters) }
                    else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { pieces.append(trimmed); partial(pieces.joined(separator: " ")) }
                }
                return pieces.joined(separator: " ")
            }
            do {
                let file = try AVAudioFile(forReading: url)
                // The file overload converts the recorder's AAC format for the chosen speech module.
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let text = try await reader.value
                try Task.checkCancellation()
                guard !text.isEmpty else { throw ChatVoiceError.noSpeech }
                return text
            } catch {
                reader.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

struct ChatVoiceLanguage: Identifiable, Hashable {
    let id: String
    let label: String

    static var choices: [Self] {
        // The system's list includes languages needing a download. Unsupported offline languages
        // keep the recording and offer file attachment instead of changing the spoken language.
        SFSpeechRecognizer.supportedLocales().map { locale in
            Self(id: locale.identifier, label: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func preferred(saved: String?, keyboard: String?, choices: [Self], languages: [String] = Locale.preferredLanguages) -> String {
        for candidate in [saved, keyboard] + languages.map(Optional.some) + [Locale.current.identifier] {
            guard let candidate, candidate != "dictation", !candidate.isEmpty else { continue }
            let locale = Locale(identifier: candidate)
            if let exact = choices.first(where: { Locale(identifier: $0.id).identifier == locale.identifier
                || $0.id.replacingOccurrences(of: "_", with: "-") == candidate.replacingOccurrences(of: "_", with: "-") }) { return exact.id }
            if let sameLanguage = choices.first(where: { Locale(identifier: $0.id).language.languageCode == locale.language.languageCode }) {
                return sameLanguage.id
            }
        }
        return Locale.current.identifier
    }
}
