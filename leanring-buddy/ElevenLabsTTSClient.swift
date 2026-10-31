//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    /// ElevenLabs voice used for playback. Changeable at runtime from Settings.
    var voiceId: String
    private let session: URLSession

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
        print("🔊 ElevenLabs TTS: playing \(speechAudioData.count / 1024)KB audio")
    }

    func pausePlayback() {
        audioPlayer?.pause()
    }

    func resumePlayback() {
        audioPlayer?.play()
    }

    /// Turns `text` into MP3 audio without playing it, so audio for the next
    /// part of an explanation can be prepared while the current part plays.
    func synthesizeSpeechAudio(_ text: String) async throws -> Data {
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
