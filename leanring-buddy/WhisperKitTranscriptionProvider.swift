//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Free, on-device speech-to-text with WhisperKit (OpenAI's Whisper running
//  on the Mac's Neural Engine). Push-to-talk audio is kept in memory while
//  the shortcut is held and transcribed when it's released. The words in the
//  user's key terms (app names, CS and ML vocabulary) are passed to Whisper
//  as a prompt, which is what makes it spell "Dijkstra" or "A*" correctly.
//
//  Models download once (Hugging Face, argmaxinc/whisperkit-coreml) into
//  ~/Library/Application Support/heySona/speech-models and then work
//  offline. The first load of a model is slow (macOS optimizes it for the
//  chip, about a minute for the large model); later loads take a second.
//

import AVFoundation
import Combine
import Foundation
import WhisperKit

/// The Whisper models offered in Settings. Raw values are WhisperKit's
/// variant names.
enum WhisperKitSpeechModel: String, CaseIterable, Identifiable {
    /// About 0.2 s per question on an M4; spells technical words correctly
    /// with the key-term prompt.
    case fastEnglish = "base.en"
    /// About 1 s per question on an M4; handles accents, noise, and other
    /// languages better.
    case mostAccurate = "large-v3-v20240930_626MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fastEnglish: return "Fast (English, 150 MB)"
        case .mostAccurate: return "Most accurate (any language, 630 MB)"
        }
    }

    /// Whisper's language code to force, or nil to detect it.
    var forcedLanguageCode: String? {
        switch self {
        case .fastEnglish: return "en"
        case .mostAccurate: return nil
        }
    }
}

enum WhisperKitModelState: Equatable {
    case notPrepared
    case downloading(fractionCompleted: Double)
    /// Loading into memory (the first time, macOS also optimizes it).
    case loading
    case ready
    case failed(message: String)
}

struct WhisperKitTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns the loaded Whisper model, shared by every push-to-talk session.
@MainActor
final class WhisperKitSpeechModelManager: ObservableObject {
    static let shared = WhisperKitSpeechModelManager()

    @Published private(set) var modelState: WhisperKitModelState = .notPrepared
    @Published private(set) var preparedModel: WhisperKitSpeechModel?

    private var loadedWhisperKit: WhisperKit?
    private var preparationTask: Task<Void, Never>?

    static var speechModelsFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heySona/speech-models", isDirectory: true)
    }

    private static func localModelFolderURL(for speechModel: WhisperKitSpeechModel) -> URL {
        speechModelsFolderURL
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(speechModel.rawValue)", isDirectory: true)
    }

    /// True when every model part is on disk, so no network is needed.
    static func isModelDownloaded(_ speechModel: WhisperKitSpeechModel) -> Bool {
        let modelFolderURL = localModelFolderURL(for: speechModel)
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy { modelPartName in
            FileManager.default.fileExists(atPath: modelFolderURL.appendingPathComponent(modelPartName).path)
        }
    }

    /// Downloads (if needed) and loads `speechModel`. Safe to call again:
    /// it does nothing if that model is already ready or on its way.
    func prepare(_ speechModel: WhisperKitSpeechModel) {
        if preparedModel == speechModel {
            switch modelState {
            case .ready, .downloading, .loading:
                return
            case .notPrepared, .failed:
                break
            }
        }

        preparationTask?.cancel()
        preparedModel = speechModel
        loadedWhisperKit = nil
        modelState = .loading
        preparationTask = Task { [weak self] in
            await self?.downloadAndLoad(speechModel)
        }
    }

    /// Frees the model's memory (when switching to AssemblyAI).
    func unload() {
        preparationTask?.cancel()
        preparationTask = nil
        loadedWhisperKit = nil
        preparedModel = nil
        modelState = .notPrepared
    }

    private func downloadAndLoad(_ speechModel: WhisperKitSpeechModel) async {
        do {
            let modelFolderURL: URL
            if Self.isModelDownloaded(speechModel) {
                modelFolderURL = Self.localModelFolderURL(for: speechModel)
            } else {
                modelState = .downloading(fractionCompleted: 0)
                print("🎙️ WhisperKit: downloading \(speechModel.rawValue)")
                modelFolderURL = try await WhisperKit.download(
                    variant: speechModel.rawValue,
                    downloadBase: Self.speechModelsFolderURL
                ) { [weak self] downloadProgress in
                    let fractionCompleted = downloadProgress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.preparedModel == speechModel,
                              case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fractionCompleted: fractionCompleted)
                    }
                }
            }
            try Task.checkCancellation()

            modelState = .loading
            let loadStartDate = Date()
            let whisperKit = try await WhisperKit(WhisperKitConfig(
                downloadBase: Self.speechModelsFolderURL,
                modelFolder: modelFolderURL.path,
                // The tokenizer is cached next to the models, so it also works offline.
                tokenizerFolder: Self.speechModelsFolderURL,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            ))
            try Task.checkCancellation()
            guard preparedModel == speechModel else { return }
            loadedWhisperKit = whisperKit
            modelState = .ready
            print("🎙️ WhisperKit: \(speechModel.rawValue) ready in \(String(format: "%.1f", Date().timeIntervalSince(loadStartDate)))s")
        } catch is CancellationError {
            return
        } catch {
            guard preparedModel == speechModel else { return }
            print("⚠️ WhisperKit: couldn't prepare \(speechModel.rawValue): \(error)")
            modelState = .failed(message: error.localizedDescription)
        }
    }

    /// Transcribes 16 kHz mono samples. Waits for the model if it's still
    /// loading (up to `maximumWaitSeconds`).
    func transcribe(
        audioSamples: [Float],
        keyterms: [String],
        maximumWaitSeconds: TimeInterval = 25
    ) async throws -> String {
        // Under a third of a second is a tap, not speech. Whisper tends to
        // invent text (or repeat the prompt) for near-silence.
        guard audioSamples.count > 16_000 / 3 else { return "" }

        let waitStartDate = Date()
        while loadedWhisperKit == nil {
            if case .failed(let message) = modelState {
                throw WhisperKitTranscriptionError(message: "The speech model couldn't load: \(message)")
            }
            if modelState == .notPrepared {
                throw WhisperKitTranscriptionError(message: "The speech model isn't set up yet. Open Settings > Speech to text.")
            }
            if Date().timeIntervalSince(waitStartDate) > maximumWaitSeconds {
                throw WhisperKitTranscriptionError(message: "The speech model is still getting ready. Try again in a moment.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let whisperKit = loadedWhisperKit else { return "" }

        var decodingOptions = DecodingOptions(
            task: .transcribe,
            language: preparedModel?.forcedLanguageCode,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: preparedModel?.forcedLanguageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        // Whisper reads a prompt as "text that came before", which nudges it
        // toward these spellings.
        let usefulKeyterms = keyterms.filter { !$0.isEmpty }.prefix(40)
        if !usefulKeyterms.isEmpty, let tokenizer = whisperKit.tokenizer {
            decodingOptions.promptTokens = tokenizer
                .encode(text: " " + usefulKeyterms.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let transcribeStartDate = Date()
        let transcriptionResults = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: decodingOptions)
        let transcriptText = transcriptionResults
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("🎙️ WhisperKit: transcribed \(String(format: "%.1f", Double(audioSamples.count) / 16_000))s of audio in \(String(format: "%.2f", Date().timeIntervalSince(transcribeStartDate)))s")
        return transcriptText
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "WhisperKit (on-device)"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        WhisperKitTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Long enough for a model that's still loading when the key is released.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 30

    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.heysona.whisperkit.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let audioSamples = Self.floatSamples(fromPCM16Data: self.bufferedPCM16AudioData)
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
            let keyterms = self.keyterms
            self.transcriptionTask = Task { @MainActor [weak self] in
                do {
                    let transcriptText = try await WhisperKitSpeechModelManager.shared.transcribe(
                        audioSamples: audioSamples,
                        keyterms: keyterms
                    )
                    guard let self, !self.stateQueue.sync(execute: { self.isCancelled }) else { return }
                    if !transcriptText.isEmpty {
                        self.onTranscriptUpdate(transcriptText)
                    }
                    self.onFinalTranscriptReady(transcriptText)
                } catch {
                    guard let self, !self.stateQueue.sync(execute: { self.isCancelled }) else { return }
                    print("⚠️ WhisperKit transcription failed: \(error.localizedDescription)")
                    self.onError(error)
                }
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    /// Little-endian 16-bit samples → floats in -1...1, as Whisper expects.
    private static func floatSamples(fromPCM16Data pcm16AudioData: Data) -> [Float] {
        let sampleCount = pcm16AudioData.count / MemoryLayout<Int16>.size
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        pcm16AudioData.withUnsafeBytes { rawBuffer in
            for sampleIndex in 0..<sampleCount {
                let pcm16Sample = Int16(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: sampleIndex * 2, as: Int16.self))
                floatSamples[sampleIndex] = Float(pcm16Sample) / 32_768
            }
        }
        return floatSamples
    }
}
