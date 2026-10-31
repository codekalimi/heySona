//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Turns text into speech and plays it: with ElevenLabs, or with the free
//  built-in Mac voice (MacSystemVoice.swift), chosen in Settings. When
//  ElevenLabs fails (out of credits, bad key, offline), it falls back to the
//  Mac voice so heySona keeps talking.
//

import AVFoundation
import Foundation

/// Which voice speaks heySona's replies.
enum SpeechVoiceProvider: String, CaseIterable, Identifiable {
    case elevenLabs
    case macSystemVoice
    /// Kokoro-82M on this Mac (KokoroVoice.swift): natural and free.
    case kokoroLocalVoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .macSystemVoice: return "Mac voice"
        case .kokoroLocalVoice: return "Local AI (free)"
        }
    }
}

@MainActor
final class ElevenLabsTTSClient {
    /// ElevenLabs voice used for playback. Changeable at runtime from Settings.
    var voiceId: String
    private let session: URLSession

    /// Set from Settings. Choosing a provider clears any ElevenLabs pause, so
    /// switching back to ElevenLabs (e.g. after topping up) retries it at once.
    var speechVoiceProvider: SpeechVoiceProvider = .elevenLabs {
        didSet { elevenLabsPausedUntilDate = nil }
    }
    /// The installed Mac voice to use; nil picks the best one for the user's language.
    var macSystemVoiceIdentifier: String?
    /// The Kokoro voice to use, like "af_heart"; nil uses the default.
    var kokoroVoiceName: String?
    /// Called when ElevenLabs or the local AI voice fails and the Mac voice
    /// takes over, with which voice failed and why.
    var onFallbackToMacSystemVoice: ((_ failedVoiceName: String, _ failureDescription: String) -> Void)?
    /// So a Kokoro problem is reported once, not for every sentence.
    private var hasReportedKokoroFallback = false

    /// After ElevenLabs fails, every sentence would fail again (and add a
    /// delay), so the Mac voice is used for a while before trying again.
    private var elevenLabsPausedUntilDate: Date?
    private static let elevenLabsRetryDelayInSeconds: TimeInterval = 10 * 60

    private var shouldUseMacSystemVoice: Bool {
        if speechVoiceProvider == .macSystemVoice { return true }
        if APIKeyKeychainStore.readAPIKey(for: .elevenLabs) == nil { return true }
        if let elevenLabsPausedUntilDate, elevenLabsPausedUntilDate > Date() { return true }
        return false
    }

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(voiceId: String) {
        self.voiceId = voiceId

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        let speechAudioData = try await synthesizeSpeechAudio(text)
        try Task.checkCancellation()
        try playSpeechAudio(speechAudioData)
    }

    /// Plays audio made by `synthesizeSpeechAudio`, replacing anything playing.
    func playSpeechAudio(_ speechAudioData: Data) throws {
        let player = try AVAudioPlayer(data: speechAudioData)
        self.audioPlayer = player
        player.play()
        print("🔊 TTS: playing \(speechAudioData.count / 1024)KB audio")
    }

    func pausePlayback() {
        audioPlayer?.pause()
    }

    func resumePlayback() {
        audioPlayer?.play()
    }

    /// Turns `text` into audio without playing it, so audio for the next
    /// part of an explanation can be prepared while the current part plays.
    func synthesizeSpeechAudio(_ text: String) async throws -> Data {
        if speechVoiceProvider == .kokoroLocalVoice {
            do {
                let kokoroAudioData = try await KokoroVoiceModelManager.shared.synthesizeSpeechAudio(text, voiceName: kokoroVoiceName)
                hasReportedKokoroFallback = false
                return kokoroAudioData
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                print("⚠️ Local AI voice failed, using the Mac voice: \(error.localizedDescription)")
                if !hasReportedKokoroFallback {
                    hasReportedKokoroFallback = true
                    onFallbackToMacSystemVoice?(SpeechVoiceProvider.kokoroLocalVoice.displayName, error.localizedDescription)
                }
                return try await synthesizeSpeechAudioWithMacSystemVoice(text)
            }
        }
        if shouldUseMacSystemVoice {
            return try await synthesizeSpeechAudioWithMacSystemVoice(text)
        }
        do {
            return try await synthesizeSpeechAudioWithElevenLabs(text)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            pauseElevenLabsAfterFailure(error)
            return try await synthesizeSpeechAudioWithMacSystemVoice(text)
        }
    }

    private func synthesizeSpeechAudioWithMacSystemVoice(_ text: String) async throws -> Data {
        try await MacSystemVoiceAudioRenderer.renderSpeechAudio(text: text, voiceIdentifier: macSystemVoiceIdentifier)
    }

    private func pauseElevenLabsAfterFailure(_ error: Error) {
        let isNewFailure = elevenLabsPausedUntilDate == nil
        elevenLabsPausedUntilDate = Date().addingTimeInterval(Self.elevenLabsRetryDelayInSeconds)
        print("⚠️ ElevenLabs failed, using the Mac voice for the next 10 minutes: \(error.localizedDescription)")
        if isNewFailure {
            onFallbackToMacSystemVoice?(SpeechVoiceProvider.elevenLabs.displayName, error.localizedDescription)
        }
    }

    /// MP3 audio from ElevenLabs.
    private func synthesizeSpeechAudioWithElevenLabs(_ text: String) async throws -> Data {
        // Read the key on every request so a key saved after launch is picked up.
        let elevenLabsAPIKey = try APIKeyKeychainStore.requireAPIKey(for: .elevenLabs)

        let textToSpeechURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: textToSpeechURL)
        request.httpMethod = "POST"
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        return data
    }

    /// Sends `text` to ElevenLabs' timestamped endpoint, plays the audio, and
    /// returns when each character starts being spoken (seconds from the
    /// start). Used by step-by-step guidance to move the cursor in sync with
    /// the voice. Returns nil timestamps if ElevenLabs didn't include them.
    func speakTextWithCharacterTimestamps(_ text: String) async throws -> (characterStartTimesInSeconds: [Double]?, audioDurationInSeconds: Double) {
        // The Mac and local AI voices have no character timestamps; step
        // guidance then estimates timing from each step's position in the text.
        if speechVoiceProvider == .kokoroLocalVoice {
            let speechAudioData = try await synthesizeSpeechAudio(text)
            try Task.checkCancellation()
            try playSpeechAudio(speechAudioData)
            return (characterStartTimesInSeconds: nil, audioDurationInSeconds: currentAudioDurationInSeconds)
        }
        if shouldUseMacSystemVoice {
            return try await speakTextWithoutTimestampsUsingMacSystemVoice(text)
        }
        do {
            return try await speakTextWithCharacterTimestampsUsingElevenLabs(text)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            pauseElevenLabsAfterFailure(error)
            return try await speakTextWithoutTimestampsUsingMacSystemVoice(text)
        }
    }

    private func speakTextWithoutTimestampsUsingMacSystemVoice(_ text: String) async throws -> (characterStartTimesInSeconds: [Double]?, audioDurationInSeconds: Double) {
        let speechAudioData = try await synthesizeSpeechAudioWithMacSystemVoice(text)
        try Task.checkCancellation()
        try playSpeechAudio(speechAudioData)
        return (characterStartTimesInSeconds: nil, audioDurationInSeconds: currentAudioDurationInSeconds)
    }

    private func speakTextWithCharacterTimestampsUsingElevenLabs(_ text: String) async throws -> (characterStartTimesInSeconds: [Double]?, audioDurationInSeconds: Double) {
        let elevenLabsAPIKey = try APIKeyKeychainStore.requireAPIKey(for: .elevenLabs)

        let timestampedSpeechURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/with-timestamps")!
        var request = URLRequest(url: timestampedSpeechURL)
        request.httpMethod = "POST"
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Timestamped TTS API error (\(statusCode)): \(errorBody)"])
        }

        let timestampedSpeech = try JSONDecoder().decode(ElevenLabsTimestampedSpeechResponse.self, from: data)
        guard let audioData = Data(base64Encoded: timestampedSpeech.audioBase64) else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Timestamped TTS returned unreadable audio"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: audioData)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio with timestamps")

        return (
            characterStartTimesInSeconds: timestampedSpeech.alignment?.characterStartTimesInSeconds,
            audioDurationInSeconds: player.duration
        )
    }

    /// Length of the audio currently loaded, or 0 if nothing is loaded.
    var currentAudioDurationInSeconds: Double {
        audioPlayer?.duration ?? 0
    }

    /// Lists the voices available to the saved ElevenLabs API key, sorted by
    /// name, so Settings can show them in a picker.
    func fetchAvailableVoices() async throws -> [ElevenLabsVoice] {
        let elevenLabsAPIKey = try APIKeyKeychainStore.requireAPIKey(for: .elevenLabs)

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Could not load voices (\(statusCode)): \(errorBody)"])
        }

        let voicesResponse = try JSONDecoder().decode(ElevenLabsVoicesResponse.self, from: data)
        return voicesResponse.voices.sorted { firstVoice, secondVoice in
            firstVoice.name.localizedCaseInsensitiveCompare(secondVoice.name) == .orderedAscending
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

struct ElevenLabsVoice: Decodable, Identifiable, Hashable {
    let voiceId: String
    let name: String

    var id: String { voiceId }

    private enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
    }
}

private struct ElevenLabsVoicesResponse: Decodable {
    let voices: [ElevenLabsVoice]
}

/// Response of ElevenLabs' `/with-timestamps` endpoint. `alignment` maps each
/// character of the input text to when it's spoken.
private struct ElevenLabsTimestampedSpeechResponse: Decodable {
    struct CharacterAlignment: Decodable {
        let characterStartTimesInSeconds: [Double]

        private enum CodingKeys: String, CodingKey {
            case characterStartTimesInSeconds = "character_start_times_seconds"
        }
    }

    let audioBase64: String
    let alignment: CharacterAlignment?

    private enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case alignment
    }
}
