//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

/// The speech-to-text service picked in Settings > Speech to text.
enum SpeechToTextChoice: String, CaseIterable, Identifiable {
    case assemblyAI = "assemblyai"
    case whisperKit = "whisperkit"

    static let userDefaultsKey = "speechToTextChoice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .whisperKit: return "WhisperKit (free)"
        }
    }

    /// The saved choice, or nil if the user never picked one.
    static var savedChoice: SpeechToTextChoice? {
        UserDefaults.standard.string(forKey: userDefaultsKey).flatMap(SpeechToTextChoice.init(rawValue:))
    }
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case assemblyAI = "assemblyai"
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()

        // A choice made in Settings wins over Info.plist.
        switch SpeechToTextChoice.savedChoice {
        case .whisperKit:
            return WhisperKitTranscriptionProvider()
        case .assemblyAI:
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }
            print("⚠️ Transcription: AssemblyAI chosen but no key saved, using Apple Speech")
            return AppleSpeechTranscriptionProvider()
        case nil:
            break
        }

        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))
        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }
        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }
        print("⚠️ Transcription: no AssemblyAI key saved, using Apple Speech")
        return AppleSpeechTranscriptionProvider()
    }
}
