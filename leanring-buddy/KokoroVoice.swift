//
//  KokoroVoice.swift
//  leanring-buddy
//
//  The free, natural-sounding local voice: Kokoro-82M running on the Mac's
//  GPU through KokoroSwift (MLX). On an M4 it speaks about 4x faster than
//  real time, so streamed replies never wait on it after the first sentence.
//
//  Files (downloaded once into ~/Library/Application Support/heySona/
//  speech-models/kokoro/, then offline):
//  - kokoro-v1_0.safetensors (~327 MB) from Hugging Face
//    mlx-community/Kokoro-82M-bf16,
//  - voices.npz (~15 MB, every voice's style vector) from the KokoroSwift
//    author's KokoroTestApp repository.
//
//  Speech is rendered into WAV data so it plays through the same
//  AVAudioPlayer path as the other voices.
//

import AVFoundation
import Combine
import Foundation
@preconcurrency import KokoroSwift
@preconcurrency import MLX
@preconcurrency import MLXUtilsLibrary

enum KokoroModelState: Equatable {
    case notDownloaded
    case downloading
    case loading
    case ready
    case failed(message: String)
}

struct KokoroVoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads, loads, and runs the Kokoro voice. One shared instance.
@MainActor
final class KokoroVoiceModelManager: ObservableObject {
    static let shared = KokoroVoiceModelManager()

    /// Voice used when the user hasn't picked one: warm, clear US English.
    static let defaultVoiceName = "af_heart"

    @Published private(set) var modelState: KokoroModelState = .notDownloaded
    /// Voice names like "af_heart", sorted, once the voices file is loaded.
    @Published private(set) var availableVoiceNames: [String] = []

    private var speechEngine: KokoroSpeechEngine?
    private var preparationTask: Task<Void, Never>?

    private static let modelDownloadURL = URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors")!
    private static let voicesDownloadURL = URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!
    /// Smaller files mean an interrupted or wrong download.
    private static let minimumModelFileByteCount = 300_000_000
    private static let minimumVoicesFileByteCount = 10_000_000

    static var kokoroFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heySona/speech-models/kokoro", isDirectory: true)
    }
    private static var modelFileURL: URL { kokoroFolderURL.appendingPathComponent("kokoro-v1_0.safetensors") }
    private static var voicesFileURL: URL { kokoroFolderURL.appendingPathComponent("voices.npz") }

    static func areFilesDownloaded() -> Bool {
        fileByteCount(at: modelFileURL) >= minimumModelFileByteCount
            && fileByteCount(at: voicesFileURL) >= minimumVoicesFileByteCount
    }

    private static func fileByteCount(at fileURL: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Preparing

    /// Downloads (if needed) and loads the voice. Safe to call repeatedly.
    func prepare() {
        switch modelState {
        case .ready, .downloading, .loading:
            return
        case .notDownloaded, .failed:
            break
        }
        // Mark it busy right away, so a second call in the same moment (the
        // Settings card and the voice switch both ask) doesn't start a
        // second download.
        modelState = Self.areFilesDownloaded() ? .loading : .downloading
        preparationTask = Task { [weak self] in
            await self?.downloadAndLoad()
        }
    }

    /// Frees the model's memory when another voice is chosen.
    func unload() {
        preparationTask?.cancel()
        preparationTask = nil
        speechEngine = nil
        availableVoiceNames = []
        modelState = .notDownloaded
    }

    private func downloadAndLoad() async {
        do {
            if !Self.areFilesDownloaded() {
                modelState = .downloading
                try FileManager.default.createDirectory(at: Self.kokoroFolderURL, withIntermediateDirectories: true)
                try await Self.download(Self.voicesDownloadURL, to: Self.voicesFileURL, minimumByteCount: Self.minimumVoicesFileByteCount)
                try await Self.download(Self.modelDownloadURL, to: Self.modelFileURL, minimumByteCount: Self.minimumModelFileByteCount)
            }
            try Task.checkCancellation()

            modelState = .loading
            let loadStartDate = Date()
            let loadedEngine = try await KokoroSpeechEngine.load(
                modelFileURL: Self.modelFileURL,
                voicesFileURL: Self.voicesFileURL
            )
            try Task.checkCancellation()
            speechEngine = loadedEngine
            availableVoiceNames = loadedEngine.voiceNames
            modelState = .ready
            print("🗣️ Kokoro voice ready in \(String(format: "%.1f", Date().timeIntervalSince(loadStartDate)))s (\(loadedEngine.voiceNames.count) voices)")
        } catch is CancellationError {
            return
        } catch {
            print("⚠️ Kokoro voice: \(error.localizedDescription)")
            modelState = .failed(message: error.localizedDescription)
        }
    }

    private static func download(_ remoteURL: URL, to destinationURL: URL, minimumByteCount: Int) async throws {
        print("🗣️ Kokoro voice: downloading \(remoteURL.lastPathComponent)")
        let (temporaryFileURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw KokoroVoiceError(message: "Couldn't download \(remoteURL.lastPathComponent).")
        }
        guard fileByteCount(at: temporaryFileURL) >= minimumByteCount else {
            throw KokoroVoiceError(message: "\(remoteURL.lastPathComponent) came down incomplete. Try again.")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryFileURL, to: destinationURL)
    }

    // MARK: - Speaking

    /// Renders `text` with `voiceName` into WAV audio data. Waits up to
    /// `maximumWaitSeconds` if the voice is still loading.
    func synthesizeSpeechAudio(_ text: String, voiceName: String?, maximumWaitSeconds: TimeInterval = 20) async throws -> Data {
        prepare()
        let waitStartDate = Date()
        while speechEngine == nil {
            if case .failed(let message) = modelState {
                throw KokoroVoiceError(message: "The local voice couldn't load: \(message)")
            }
            if Date().timeIntervalSince(waitStartDate) > maximumWaitSeconds {
                throw KokoroVoiceError(message: "The local voice is still getting ready.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let speechEngine else { throw KokoroVoiceError(message: "The local voice isn't loaded.") }
        let chosenVoiceName = voiceName.flatMap { speechEngine.voiceNames.contains($0) ? $0 : nil }
            ?? (speechEngine.voiceNames.contains(Self.defaultVoiceName) ? Self.defaultVoiceName : speechEngine.voiceNames.first)
        guard let chosenVoiceName else { throw KokoroVoiceError(message: "No Kokoro voices were found.") }
        let audioSamples = try await speechEngine.generateAudioSamples(text: text, voiceName: chosenVoiceName)
        return Self.wavData(fromFloatSamples: audioSamples, sampleRate: KokoroTTS.Constants.samplingRate)
    }

    /// Float samples (-1...1) → 16-bit mono WAV, which AVAudioPlayer plays.
    private static func wavData(fromFloatSamples floatSamples: [Float], sampleRate: Int) -> Data {
        var pcm16AudioData = Data(capacity: floatSamples.count * 2)
        for floatSample in floatSamples {
            let clampedSample = max(-1, min(1, floatSample))
            var pcm16Sample = Int16(clampedSample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &pcm16Sample) { pcm16AudioData.append(contentsOf: $0) }
        }
        return BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm16AudioData, sampleRate: sampleRate)
    }

    /// "af_heart" → "Heart (US, female)".
    static func displayName(forVoiceName voiceName: String) -> String {
        let nameParts = voiceName.split(separator: "_", maxSplits: 1)
        guard nameParts.count == 2, let accentAndGender = nameParts.first, accentAndGender.count == 2 else { return voiceName }
        let accent = accentAndGender.first == "b" ? "UK" : (accentAndGender.first == "a" ? "US" : String(accentAndGender.first!))
        let gender = accentAndGender.last == "m" ? "male" : "female"
        return "\(nameParts[1].capitalized) (\(accent), \(gender))"
    }
}

/// Owns the Kokoro model and voices. Generation is heavy and synchronous,
/// so it runs one request at a time on its own queue, off the main thread.
nonisolated final class KokoroSpeechEngine: @unchecked Sendable {
    private let kokoroTTS: KokoroTTS
    private let voiceStylesByName: [String: MLXArray]
    let voiceNames: [String]
    private let generationQueue = DispatchQueue(label: "com.heysona.kokoro.generation", qos: .userInitiated)

    private init(kokoroTTS: KokoroTTS, voiceStylesByName: [String: MLXArray]) {
        self.kokoroTTS = kokoroTTS
        self.voiceStylesByName = voiceStylesByName
        self.voiceNames = voiceStylesByName.keys.sorted()
    }

    /// Loads the model and voices on a background queue.
    static func load(modelFileURL: URL, voicesFileURL: URL) async throws -> KokoroSpeechEngine {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let rawVoiceStyles = NpyzReader.read(fileFromPath: voicesFileURL), !rawVoiceStyles.isEmpty else {
                    continuation.resume(throwing: KokoroVoiceError(message: "The voices file couldn't be read."))
                    return
                }
                // Keys in the file look like "af_heart.npy".
                var voiceStylesByName: [String: MLXArray] = [:]
                for (fileKey, voiceStyle) in rawVoiceStyles {
                    voiceStylesByName[String(fileKey.split(separator: ".").first ?? Substring(fileKey))] = voiceStyle
                }
                let kokoroTTS = KokoroTTS(modelPath: modelFileURL, g2p: .misaki)
                continuation.resume(returning: KokoroSpeechEngine(kokoroTTS: kokoroTTS, voiceStylesByName: voiceStylesByName))
            }
        }
    }

    /// 24 kHz samples for `text`. Long text is split into sentences so each
    /// call stays under Kokoro's 510-token limit.
    func generateAudioSamples(text: String, voiceName: String) async throws -> [Float] {
        guard let voiceStyle = voiceStylesByName[voiceName] else {
            throw KokoroVoiceError(message: "No Kokoro voice named \(voiceName).")
        }
        // Voices starting with "b" are British English.
        let language: Language = voiceName.hasPrefix("b") ? .enGB : .enUS
        return try await withCheckedThrowingContinuation { continuation in
            generationQueue.async { [kokoroTTS] in
                do {
                    var allSamples: [Float] = []
                    for textChunk in Self.chunksUnderTokenLimit(text) {
                        let (chunkSamples, _) = try kokoroTTS.generateAudio(voice: voiceStyle, language: language, text: textChunk)
                        allSamples += chunkSamples
                    }
                    continuation.resume(returning: allSamples)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sentences grouped into chunks of at most ~350 characters (well under
    /// 510 phoneme tokens).
    private static func chunksUnderTokenLimit(_ text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > 350 else { return trimmedText.isEmpty ? [] : [trimmedText] }
        var textChunks: [String] = []
        var currentChunk = ""
        trimmedText.enumerateSubstrings(in: trimmedText.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if currentChunk.count + sentence.count > 350, !currentChunk.isEmpty {
                textChunks.append(currentChunk)
                currentChunk = ""
            }
            currentChunk += sentence
        }
        if !currentChunk.trimmingCharacters(in: .whitespaces).isEmpty { textChunks.append(currentChunk) }
        return textChunks
    }
}
