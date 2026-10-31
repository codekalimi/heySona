//
//  MacSystemVoice.swift
//  leanring-buddy
//
//  The free, offline voice: macOS's built-in speech synthesis. Speech is
//  rendered into audio data (instead of spoken straight to the speakers) so
//  it plays through the same AVAudioPlayer path as ElevenLabs audio, and
//  streamed replies, step guidance, and explainer narration all work as-is.
//
//  Better voices ("Enhanced" and "Premium") are a free download in System
//  Settings > Accessibility > Spoken Content > System Voice > Manage Voices.
//

import AVFoundation
import Foundation

/// One installed macOS voice, for the Settings picker.
struct MacSystemVoice: Identifiable, Hashable {
    let identifier: String
    let name: String
    let languageCode: String
    let qualityRank: Int

    var id: String { identifier }

    var qualityDescription: String {
        switch qualityRank {
        case 2: return "Premium"
        case 1: return "Enhanced"
        default: return "Standard"
        }
    }

    /// e.g. "Ava (English, United States) · Premium"
    var pickerTitle: String {
        let languageName = Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
        return "\(name) (\(languageName)) · \(qualityDescription)"
    }
}

nonisolated enum MacSystemVoiceCatalog {
    /// Installed voices without the novelty ones (Bells, Bubbles, ...),
    /// in the user's language first, best quality first.
    static func installedVoices() -> [MacSystemVoice] {
        let preferredLanguageCode = AVSpeechSynthesisVoice.currentLanguageCode()
        let preferredLanguagePrefix = String(preferredLanguageCode.prefix(2))
        // 0: the user's exact language and region, 1: same language, 2: others.
        func languageMatchRank(_ voice: MacSystemVoice) -> Int {
            if voice.languageCode == preferredLanguageCode { return 0 }
            return voice.languageCode.hasPrefix(preferredLanguagePrefix) ? 1 : 2
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { systemVoice in
                MacSystemVoice(
                    identifier: systemVoice.identifier,
                    name: systemVoice.name,
                    languageCode: systemVoice.language,
                    qualityRank: qualityRank(of: systemVoice.quality)
                )
            }
            .sorted { firstVoice, secondVoice in
                let firstLanguageMatchRank = languageMatchRank(firstVoice)
                let secondLanguageMatchRank = languageMatchRank(secondVoice)
                if firstLanguageMatchRank != secondLanguageMatchRank { return firstLanguageMatchRank < secondLanguageMatchRank }
                if firstVoice.qualityRank != secondVoice.qualityRank { return firstVoice.qualityRank > secondVoice.qualityRank }
                if firstVoice.languageCode != secondVoice.languageCode { return firstVoice.languageCode < secondVoice.languageCode }
                return firstVoice.name.localizedCaseInsensitiveCompare(secondVoice.name) == .orderedAscending
            }
    }

    /// The best installed voice in the user's language.
    static func bestDefaultVoiceIdentifier() -> String? {
        installedVoices().first?.identifier
    }

    private static func qualityRank(of voiceQuality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch voiceQuality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }
}

struct MacSystemVoiceRenderingError: LocalizedError {
    var errorDescription: String? {
        "The Mac voice didn't produce any audio. Try another voice in Settings."
    }
}

enum MacSystemVoiceAudioRenderer {
    /// Renders `text` with the given voice (or the best default) into audio
    /// data that AVAudioPlayer can play. Cancellation stops the rendering.
    nonisolated static func renderSpeechAudio(text: String, voiceIdentifier: String?) async throws -> Data {
        let renderJob = MacSystemVoiceRenderJob(text: text, voiceIdentifier: voiceIdentifier)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                renderJob.start(continuation: continuation)
            }
        } onCancel: {
            renderJob.cancel()
        }
    }
}

/// One rendering. Not tied to the main actor: AVSpeechSynthesizer delivers
/// audio buffers on its own queue, so all state is guarded by a lock.
nonisolated private final class MacSystemVoiceRenderJob: @unchecked Sendable {
    private let text: String
    private let voiceIdentifier: String?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let outputFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("heysona-mac-voice-\(UUID().uuidString).caf")

    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var outputAudioFile: AVAudioFile?
    private var hasWrittenAudio = false
    private var isFinished = false
    private var renderStartUptime: TimeInterval = 0
    private var lastAudioBufferUptime: TimeInterval = 0

    /// Some voices never send the empty "done" buffer, so rendering also
    /// ends after this long with no new audio, or after the overall limit.
    private static let silenceMeaningDoneInSeconds: TimeInterval = 1.0
    private static let maximumRenderSeconds: TimeInterval = 60

    init(text: String, voiceIdentifier: String?) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
    }

    func start(continuation: CheckedContinuation<Data, Error>) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            continuation.resume(throwing: MacSystemVoiceRenderingError())
            return
        }

        stateLock.lock()
        self.continuation = continuation
        renderStartUptime = ProcessInfo.processInfo.systemUptime
        lastAudioBufferUptime = renderStartUptime
        stateLock.unlock()

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? MacSystemVoiceCatalog.bestDefaultVoiceIdentifier().flatMap { AVSpeechSynthesisVoice(identifier: $0) }

        speechSynthesizer.write(utterance) { [self] audioBuffer in
            guard let pcmAudioBuffer = audioBuffer as? AVAudioPCMBuffer else { return }
            if pcmAudioBuffer.frameLength == 0 {
                finish()
            } else {
                append(pcmAudioBuffer)
            }
        }
        scheduleDoneCheck()
    }

    func cancel() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        finish(cancelled: true)
    }

    private func append(_ pcmAudioBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        do {
            if outputAudioFile == nil {
                outputAudioFile = try AVAudioFile(
                    forWriting: outputFileURL,
                    settings: pcmAudioBuffer.format.settings,
                    commonFormat: pcmAudioBuffer.format.commonFormat,
                    interleaved: pcmAudioBuffer.format.isInterleaved
                )
            }
            try outputAudioFile?.write(from: pcmAudioBuffer)
            hasWrittenAudio = true
            lastAudioBufferUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            print("⚠️ Mac voice: couldn't write audio: \(error)")
        }
    }

    private func scheduleDoneCheck() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) { [self] in
            stateLock.lock()
            let isAlreadyFinished = isFinished
            let currentUptime = ProcessInfo.processInfo.systemUptime
            let hasGoneQuiet = hasWrittenAudio && currentUptime - lastAudioBufferUptime > Self.silenceMeaningDoneInSeconds
            let hasTakenTooLong = currentUptime - renderStartUptime > Self.maximumRenderSeconds
            stateLock.unlock()

            guard !isAlreadyFinished else { return }
            if hasGoneQuiet || hasTakenTooLong {
                finish()
            } else {
                scheduleDoneCheck()
            }
        }
    }

    private func finish(cancelled: Bool = false) {
        stateLock.lock()
        guard !isFinished else {
            stateLock.unlock()
            return
        }
        isFinished = true
        // Releasing the file closes it, which writes its header.
        outputAudioFile = nil
        let finishedContinuation = continuation
        continuation = nil
        let didWriteAudio = hasWrittenAudio
        stateLock.unlock()

        defer { try? FileManager.default.removeItem(at: outputFileURL) }
        if cancelled {
            finishedContinuation?.resume(throwing: CancellationError())
            return
        }
        guard didWriteAudio, let renderedAudioData = try? Data(contentsOf: outputFileURL) else {
            finishedContinuation?.resume(throwing: MacSystemVoiceRenderingError())
            return
        }
        finishedContinuation?.resume(returning: renderedAudioData)
    }
}
