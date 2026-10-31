//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Carbon
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var lastTranscript: String?
    let panelConversation = CompanionPanelConversation()
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    var onboardingMusicPlayer: AVAudioPlayer?
    var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Shows the reply as a text bubble next to the cursor. Only used when
    /// spoken replies are turned off in Settings, since otherwise the reply
    /// is heard instead of read.
    let responseOverlayManager = CompanionResponseOverlayManager()

    /// ElevenLabs voice used until the user picks a different one in Settings.
    static let defaultElevenLabsVoiceId = "kPzsL2i3teMYv0FxEYQ6"

    lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(model: selectedModel)
    }()

    lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        let ttsClient = ElevenLabsTTSClient(voiceId: selectedElevenLabsVoiceId)
        ttsClient.speechVoiceProvider = speechVoiceProvider
        ttsClient.macSystemVoiceIdentifier = selectedMacSystemVoiceIdentifier
        ttsClient.onFallbackToMacSystemVoice = { [weak self] elevenLabsFailureDescription in
            self?.elevenLabsFallbackMessage = "ElevenLabs isn't working right now, so heySona is using the Mac voice. (\(elevenLabsFailureDescription))"
        }
        return ttsClient
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    // MARK: Conversation archive (CompanionManager+ConversationMemory.swift)

    /// Past exchanges and session summaries, saved on this Mac.
    let conversationArchiveStore = ConversationArchiveStore()
    /// Topic, app, and saved-procedure skills (SkillLibrary.swift).
    let skillLibrary = SkillLibrary()

    /// Optional Claude review of new visual explanations (VisualExplanationReviewer.swift).
    @Published private(set) var isVisualSelfCheckEnabled: Bool =
        UserDefaults.standard.bool(forKey: "isVisualSelfCheckEnabled")
    let visualExplanationReviewer = VisualExplanationReviewer()
    var visualExplanationReviewTask: Task<Void, Never>?

    func setVisualSelfCheckEnabled(_ isEnabled: Bool) {
        isVisualSelfCheckEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isVisualSelfCheckEnabled")
    }
    /// When on, exchanges are saved, summarized, searchable, and restored at launch.
    @Published var isConversationHistoryEnabled: Bool =
        UserDefaults.standard.object(forKey: "isConversationHistoryEnabled") as? Bool ?? true
    var currentConversationSessionID = UUID().uuidString
    var lastConversationExchangeDate: Date?
    var conversationSessionSummaryTask: Task<Void, Never>?
    var isSummarizingConversationSessions = false
    /// Session summaries are short, so the cheapest model writes them.
    lazy var conversationSummaryClaudeAPI = ClaudeAPI(model: ClaudeModelCatalog.haiku.modelID)

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    /// Voices the reply currently streaming in, if spoken replies are on.
    var currentStreamingReplySpeaker: StreamingReplySpeaker?

    // MARK: - Open Visual Explanation

    /// The explanation currently in the explainer window, kept so follow-up
    /// questions can add to it and so it can be saved to the library.
    struct OpenVisualExplanation {
        /// Library id once saved (nil if not saved, e.g. deleted).
        var savedExplanationID: String?
        var sceneLines: [String]
        var title: String
        var question: String
    }

    var openVisualExplanation: OpenVisualExplanation?

    // MARK: - Guided Mode State (behavior in CompanionManager+GuidedMode.swift)

    /// When on, multi-step tasks continue after each of the user's clicks.
    @Published private(set) var isGuidedModeEnabled: Bool = UserDefaults.standard.object(forKey: "isGuidedModeEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isGuidedModeEnabled")

    func setGuidedModeEnabled(_ enabled: Bool) {
        isGuidedModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isGuidedModeEnabled")
        if !enabled {
            stopGuidedMode()
        }
    }

    /// True while heySona waits for the user's click to show the next step.
    @Published var isWaitingForGuidedModeClick = false
    /// The question that started the guided task, repeated to Claude each round.
    var guidedTaskQuestion: String?
    var guidedModeRoundCount = 0
    var guidedModeClickMonitor: Any?
    var guidedModeTimeoutTask: Task<Void, Never>?
    /// Set while a guided round starts, so the usual "new question" cleanup
    /// doesn't end guided mode.
    var isContinuingGuidedTask = false

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?

    // MARK: - Type-To-Ask And Stop Shortcuts

    let globalHotKeyRegistrar = GlobalHotKeyRegistrar()
    let typeToAskPanelManager = TypeToAskPanelManager()
    /// Double-tap control, for the app's whole lifetime.
    var typeToAskDoubleTapCancellable: AnyCancellable?
    /// Esc, registered only while a reply is being generated or spoken, so
    /// Esc keeps working normally in other apps the rest of the time.
    var escapeToStopHotKey: RegisteredGlobalHotKey?
    /// Waits for the current reply to finish, then releases the Esc hot key.
    var escapeToStopReleaseTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    /// Older saved choices (Sonnet 4.6, Opus 4.6) map to the current model in
    /// the same family; see ClaudeModelCatalog.
    @Published var selectedModel: String = ClaudeModelCatalog
        .modelOption(forSavedModelID: UserDefaults.standard.string(forKey: "selectedClaudeModel"))
        .modelID

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// The ElevenLabs voice used for spoken replies. Persisted to UserDefaults.
    @Published private(set) var selectedElevenLabsVoiceId: String =
        UserDefaults.standard.string(forKey: "selectedElevenLabsVoiceId") ?? CompanionManager.defaultElevenLabsVoiceId

    func setSelectedElevenLabsVoiceId(_ voiceId: String) {
        let trimmedVoiceId = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoiceId.isEmpty else { return }
        selectedElevenLabsVoiceId = trimmedVoiceId
        UserDefaults.standard.set(trimmedVoiceId, forKey: "selectedElevenLabsVoiceId")
        elevenLabsTTSClient.voiceId = trimmedVoiceId
    }

    /// AssemblyAI (cloud) or WhisperKit (on-device, free). Persisted.
    @Published private(set) var speechToTextChoice: SpeechToTextChoice =
        SpeechToTextChoice.savedChoice ?? .assemblyAI

    func setSpeechToTextChoice(_ choice: SpeechToTextChoice) {
        speechToTextChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: SpeechToTextChoice.userDefaultsKey)
        buddyDictationManager.reloadTranscriptionProvider()
        if choice == .whisperKit {
            WhisperKitSpeechModelManager.shared.prepare(selectedWhisperKitSpeechModel)
        } else {
            // Free the model's memory while it isn't used.
            WhisperKitSpeechModelManager.shared.unload()
        }
    }

    /// Which Whisper model WhisperKit uses. Persisted.
    @Published private(set) var selectedWhisperKitSpeechModel: WhisperKitSpeechModel =
        UserDefaults.standard.string(forKey: "selectedWhisperKitSpeechModel").flatMap(WhisperKitSpeechModel.init(rawValue:)) ?? .fastEnglish

    func setSelectedWhisperKitSpeechModel(_ speechModel: WhisperKitSpeechModel) {
        selectedWhisperKitSpeechModel = speechModel
        UserDefaults.standard.set(speechModel.rawValue, forKey: "selectedWhisperKitSpeechModel")
        if speechToTextChoice == .whisperKit {
            WhisperKitSpeechModelManager.shared.prepare(speechModel)
        }
    }

    /// ElevenLabs or the free Mac voice. Persisted to UserDefaults.
    @Published private(set) var speechVoiceProvider: SpeechVoiceProvider =
        UserDefaults.standard.string(forKey: "speechVoiceProvider").flatMap(SpeechVoiceProvider.init(rawValue:)) ?? .elevenLabs

    func setSpeechVoiceProvider(_ provider: SpeechVoiceProvider) {
        speechVoiceProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "speechVoiceProvider")
        elevenLabsTTSClient.speechVoiceProvider = provider
        elevenLabsFallbackMessage = nil
    }

    /// The installed Mac voice; nil uses the best one for the user's language.
    @Published private(set) var selectedMacSystemVoiceIdentifier: String? =
        UserDefaults.standard.string(forKey: "selectedMacSystemVoiceIdentifier")

    func setSelectedMacSystemVoiceIdentifier(_ voiceIdentifier: String) {
        selectedMacSystemVoiceIdentifier = voiceIdentifier
        UserDefaults.standard.set(voiceIdentifier, forKey: "selectedMacSystemVoiceIdentifier")
        elevenLabsTTSClient.macSystemVoiceIdentifier = voiceIdentifier
    }

    /// Shown in Settings after ElevenLabs failed and the Mac voice took over.
    @Published var elevenLabsFallbackMessage: String?

    func fetchAvailableElevenLabsVoices() async throws -> [ElevenLabsVoice] {
        try await elevenLabsTTSClient.fetchAvailableVoices()
    }

    /// Speaks a short sample with the selected voice so the user can hear
    /// it before committing to it in Settings.
    func previewSelectedVoice() async throws {
        elevenLabsTTSClient.stopPlayback()
        try await elevenLabsTTSClient.speakText("Hey, I'm Sona. This is how I sound.")
    }

    /// Runs the Mac actions (open apps, volume, reminders, ...) Claude calls.
    let macActionExecutor = MacActionExecutor()

    /// When on, Claude can take actions on the Mac through tools. Persisted
    /// to UserDefaults; defaults to on.
    @Published private(set) var isMacActionsEnabled: Bool = UserDefaults.standard.object(forKey: "isMacActionsEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isMacActionsEnabled")

    func setMacActionsEnabled(_ enabled: Bool) {
        isMacActionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isMacActionsEnabled")
    }

    // MARK: - Memory, Project, And Notes Settings

    /// Facts remembered across launches. Shown and editable in Settings.
    let longTermMemoryStore = LongTermMemoryStore()
    lazy var personalContextToolExecutor = PersonalContextToolExecutor(longTermMemoryStore: longTermMemoryStore)

    @Published private(set) var isLongTermMemoryEnabled: Bool = UserDefaults.standard.object(forKey: "isLongTermMemoryEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isLongTermMemoryEnabled")

    func setLongTermMemoryEnabled(_ enabled: Bool) {
        isLongTermMemoryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLongTermMemoryEnabled")
    }

    /// When on, heySona detects the project from the front window (or uses
    /// the pinned folder) and lets Claude read its files.
    @Published private(set) var isProjectAwarenessEnabled: Bool = UserDefaults.standard.object(forKey: "isProjectAwarenessEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isProjectAwarenessEnabled")

    func setProjectAwarenessEnabled(_ enabled: Bool) {
        isProjectAwarenessEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isProjectAwarenessEnabled")
    }

    /// Used when no project is detected from the front window.
    @Published private(set) var pinnedProjectFolderPath: String? = UserDefaults.standard.string(forKey: "pinnedProjectFolderPath")

    func setPinnedProjectFolderPath(_ folderPath: String?) {
        pinnedProjectFolderPath = folderPath
        UserDefaults.standard.set(folderPath, forKey: "pinnedProjectFolderPath")
    }

    @Published private(set) var defaultNoteDestination: NoteDestination =
        NoteDestination(rawValue: UserDefaults.standard.string(forKey: "defaultNoteDestination") ?? "") ?? .appleNotes

    func setDefaultNoteDestination(_ noteDestination: NoteDestination) {
        defaultNoteDestination = noteDestination
        UserDefaults.standard.set(noteDestination.rawValue, forKey: "defaultNoteDestination")
    }

    @Published private(set) var markdownNotesFolderPath: String =
        UserDefaults.standard.string(forKey: "markdownNotesFolderPath") ?? NoteSaver.defaultMarkdownFolderPath

    func setMarkdownNotesFolderPath(_ folderPath: String) {
        markdownNotesFolderPath = folderPath
        UserDefaults.standard.set(folderPath, forKey: "markdownNotesFolderPath")
    }

    @Published private(set) var obsidianVaultFolderPath: String? = UserDefaults.standard.string(forKey: "obsidianVaultFolderPath")

    func setObsidianVaultFolderPath(_ folderPath: String?) {
        obsidianVaultFolderPath = folderPath
        UserDefaults.standard.set(folderPath, forKey: "obsidianVaultFolderPath")
    }

    // MARK: - On-Screen Drawing And Captions

    /// Drawings currently shown on the overlay. Each screen's overlay
    /// renders the ones whose display frame matches it.
    @Published var screenDrawings: [ScreenDrawing] = []
    var screenDrawingsFadeOutTask: Task<Void, Never>?
    var captionHideTask: Task<Void, Never>?

    /// When on, Claude can circle, box, underline, and draw arrows on screen.
    @Published private(set) var isScreenDrawingEnabled: Bool = UserDefaults.standard.object(forKey: "isScreenDrawingEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isScreenDrawingEnabled")

    func setScreenDrawingEnabled(_ enabled: Bool) {
        isScreenDrawingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isScreenDrawingEnabled")
        if !enabled {
            clearScreenDrawings()
        }
    }

    // MARK: - Visual Explainer

    /// Floating window that shows animated 3D/2D explanations.
    let visualExplainerPanelManager = VisualExplainerPanelManager()

    /// When on, "explain how X works" questions open an animated, narrated
    /// explanation in the explainer window.
    @Published private(set) var isVisualExplanationEnabled: Bool = UserDefaults.standard.object(forKey: "isVisualExplanationEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isVisualExplanationEnabled")

    func setVisualExplanationEnabled(_ enabled: Bool) {
        isVisualExplanationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isVisualExplanationEnabled")
    }

    var currentVisualExplanationSession: VisualExplanationSession?

    // MARK: - Step-By-Step Guidance

    /// When on, "how do I…" answers walk through steps on screen in sync
    /// with the voice.
    @Published private(set) var isStepGuidanceEnabled: Bool = UserDefaults.standard.object(forKey: "isStepGuidanceEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isStepGuidanceEnabled")

    func setStepGuidanceEnabled(_ enabled: Bool) {
        isStepGuidanceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isStepGuidanceEnabled")
    }

    /// True while a step-by-step reply is playing. The cursor overlay reads
    /// this to stay on each step instead of flying back between steps.
    @Published var isGuidingThroughSteps: Bool = false
    var stepGuidanceTask: Task<Void, Never>?

    /// When on, the spoken reply is also shown as text next to the cursor.
    @Published private(set) var isLiveCaptionsEnabled: Bool = UserDefaults.standard.object(forKey: "isLiveCaptionsEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isLiveCaptionsEnabled")

    func setLiveCaptionsEnabled(_ enabled: Bool) {
        isLiveCaptionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLiveCaptionsEnabled")
    }

    /// When off, replies are shown as a text bubble instead of spoken aloud.
    /// Persisted to UserDefaults; defaults to on.
    @Published private(set) var isSpokenReplyEnabled: Bool = UserDefaults.standard.object(forKey: "isSpokenReplyEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isSpokenReplyEnabled")

    func setSpokenReplyEnabled(_ enabled: Bool) {
        isSpokenReplyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isSpokenReplyEnabled")
        if !enabled {
            elevenLabsTTSClient.stopPlayback()
        }
    }

    /// User preference for whether the heySona cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    /// Reads the new key first, then the key older builds used, so a saved
    /// choice survives the rename. Defaults to on.
    @Published var isCursorOverlayEnabled: Bool =
        (UserDefaults.standard.object(forKey: "isCursorOverlayEnabled")
            ?? UserDefaults.standard.object(forKey: "isClickyCursorEnabled")) as? Bool ?? true

    func setCursorOverlayEnabled(_ enabled: Bool) {
        isCursorOverlayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isCursorOverlayEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    @Published var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 heySona start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindTypeToAskDoubleTap()
        restoreConversationContextFromArchive()
        // Load the on-device speech model now, so the first push-to-talk
        // doesn't wait for it.
        if speechToTextChoice == .whisperKit {
            WhisperKitSpeechModelManager.shared.prepare(selectedWhisperKitSpeechModel)
        }
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isCursorOverlayEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published var isRequestingScreenContent = false

    // MARK: - Private

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            prepareForNewInteraction()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    /// Shared setup for every new question, spoken or typed: makes sure the
    /// cursor overlay is showing and clears whatever the previous reply left.
    func prepareForNewInteraction() {
        // Cancel any pending transient hide so the overlay stays visible
        transientHideTask?.cancel()
        transientHideTask = nil

        // If the cursor is hidden, bring it back transiently for this interaction
        if !isCursorOverlayEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Dismiss the menu bar panel so it doesn't cover the screen
        NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)

        // Cancel any in-progress response and TTS from a previous utterance
        currentResponseTask?.cancel()
        currentStreamingReplySpeaker?.cancel()
        panelConversation.interrupt()
        elevenLabsTTSClient.stopPlayback()
        hideCaptionAndBubble()
        stopStepGuidance()
        stopVisualExplanation()
        if !isContinuingGuidedTask {
            stopGuidedMode()
        }
        clearScreenDrawings()
        clearDetectedElementLocation()

        // Dismiss the onboarding prompt if it's showing
        if showOnboardingPrompt {
            withAnimation(.easeOut(duration: 0.3)) {
                onboardingPromptOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }
    }

    // MARK: - Type To Ask

    // MARK: - Stop / Interrupt

    /// Spoken when Claude declines a request and no fallback model answers.
    private static let declinedRequestSpokenReply = "sorry, i can't help with that one. want to try asking it a different way?"

    // MARK: - Companion Prompt

    static let companionVoiceResponseSystemPrompt = """
    you're sona, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - when you explain a concept (especially computer science, math, data structures and algorithms, machine learning, deep learning, or ai agents), use simple english: everyday words, short sentences, and say what any technical word means the first time. start with the intuition and why the idea exists, give one real-world analogy that matches how it really works (for example, a hash map is like a coat check: your ticket number tells the attendant exactly which hook to go to), then a tiny concrete example with small numbers. when it helps, connect it to an idea they already know or learned earlier in this conversation. if they say they don't get it or ask for it simpler, explain it again from a different angle with a different, more everyday analogy instead of repeating yourself.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    func sendTranscriptToClaudeWithScreenshot(transcript: String, presentInMenuBar: Bool = false) {
        currentResponseTask?.cancel()
        currentStreamingReplySpeaker?.cancel()
        elevenLabsTTSClient.stopPlayback()
        let panelQuestion = isContinuingGuidedTask ? (guidedTaskQuestion ?? transcript) : transcript
        let panelExchangeID = panelConversation.beginQuestion(panelQuestion)

        currentResponseTask = Task {
            var didPresentConversationPanel = false
            // The cursor keeps its processing state while the menu panel can
            // independently display the reply as it streams.
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context.
                // The cursor's screen is sent as sharp as the model can read.
                let selectedModelOption = ClaudeModelCatalog.modelOption(forModelID: selectedModel) ?? ClaudeModelCatalog.defaultModelOption
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                    cursorScreenMaximumLongEdgeInPixels: selectedModelOption.screenshotMaximumLongEdgeInPixels,
                    otherScreensMaximumLongEdgeInPixels: ClaudeModelCatalog.otherScreensMaximumLongEdgeInPixels
                )

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let requestSetup = makeRequestSetup(transcript: transcript)

                // Capture the user's app and screen before showing our panel. A
                // background voice question never opens it over the user's work.
                if presentInMenuBar {
                    NotificationCenter.default.post(name: .heySonaShowConversationPanel, object: nil)
                    didPresentConversationPanel = true
                }

                // With spoken replies on, sentences are voiced as soon as
                // they're written instead of after the whole reply arrives.
                let streamingReplySpeaker: StreamingReplySpeaker? = isSpokenReplyEnabled
                    ? StreamingReplySpeaker(
                        elevenLabsTTSClient: elevenLabsTTSClient,
                        screenCaptures: screenCaptures,
                        isStepGuidanceEnabled: isStepGuidanceEnabled,
                        isLiveDrawingEnabled: isScreenDrawingEnabled
                    )
                    : nil
                currentStreamingReplySpeaker = streamingReplySpeaker
                streamingReplySpeaker?.onFirstAudioStarted = { [weak self] in
                    self?.voiceState = .responding
                }
                streamingReplySpeaker?.onDrawingReached = { [weak self] liveDrawing in
                    self?.addScreenDrawingWhileSpeaking(liveDrawing)
                }
                streamingReplySpeaker?.onSegmentStarted = { [weak self] segmentText in
                    guard let self, self.isLiveCaptionsEnabled else { return }
                    self.responseOverlayManager.showOverlayAndBeginStreaming()
                    self.responseOverlayManager.updateStreamingText(segmentText)
                }
                streamingReplySpeaker?.onGuidanceStepReached = { [weak self] guidanceStep in
                    self?.isGuidingThroughSteps = true
                    self?.showGuidanceStep(guidanceStep)
                }

                let fullResponseText: String
                do {
                    let streamingResult = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: requestSetup.systemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: requestSetup.userPrompt,
                        tools: requestSetup.toolDefinitions,
                        toolCallHandler: requestSetup.toolDefinitions.isEmpty ? nil : requestSetup.toolCallHandler,
                        onTextChunk: { accumulatedResponseText in
                            guard !Task.isCancelled else { return }
                            self.panelConversation.receive(accumulatedResponseText, for: panelExchangeID)
                            streamingReplySpeaker?.receive(accumulatedText: accumulatedResponseText)
                        }
                    )
                    fullResponseText = streamingResult.text
                } catch is ClaudeResponseRefusedError {
                    // A safety decline isn't an outage, so say so plainly instead
                    // of the "out of credits" error message.
                    print("⚠️ Claude declined this request")
                    fullResponseText = Self.declinedRequestSpokenReply
                }

                guard !Task.isCancelled else { return }

                // Voice whatever is left (e.g. a final sentence with no
                // trailing space, or the decline message after a refusal).
                streamingReplySpeaker?.finish(fullText: fullResponseText)

                // Drawing tags come before the [POINT:...] tag, which must be
                // last for its parser, so pull them out first. They're always
                // removed from the text so they're never spoken.
                // A [VISUAL:...] brief means Claude wants to explain this in the
                // visual explainer; the spoken reply is just a short lead-in.
                // [WAIT_FOR_CLICK] asks heySona to wait for the user's click
                // and then continue the task (guided mode).
                let waitForClickExtraction = Self.removeWaitForClickTag(from: fullResponseText)
                let shouldWaitForClickAfterReply = isGuidedModeEnabled && isStepGuidanceEnabled && waitForClickExtraction.didRequestWaitForClick

                // A follow-up about the explanation already open adds steps to
                // that scene; [VISUAL:...] starts a new one.
                let followUpExtraction = VisualExplanationSession.extractVisualFollowUpBrief(from: waitForClickExtraction.textWithoutTag)
                let visualExplanationFollowUpBrief = isVisualExplanationEnabled && openVisualExplanation != nil ? followUpExtraction.brief : nil
                let dockExtraction = VisualExplanationSession.extractVisualDockBrief(from: followUpExtraction.textWithoutTag)
                let visualExplanationExtraction = VisualExplanationSession.extractVisualExplanationBrief(from: dockExtraction.textWithoutTag)
                let isVisualExplanationFollowUp = visualExplanationFollowUpBrief != nil
                let dockedVisualExplanationBrief = isVisualExplanationEnabled && !isVisualExplanationFollowUp ? dockExtraction.brief : nil
                let isVisualExplanationDocked = dockedVisualExplanationBrief != nil
                let visualExplanationBrief = visualExplanationFollowUpBrief ?? dockedVisualExplanationBrief ?? (isVisualExplanationEnabled ? visualExplanationExtraction.brief : nil)

                let drawingExtraction = ScreenDrawingTagParser.extractDrawings(
                    from: visualExplanationExtraction.textWithoutTag,
                    screenCaptures: screenCaptures
                )
                // Drawings already drawn while speaking aren't drawn twice.
                let didDrawWhileSpeaking = (streamingReplySpeaker?.liveDrawingCount ?? 0) > 0
                if isScreenDrawingEnabled && !drawingExtraction.drawings.isEmpty && !didDrawWhileSpeaking {
                    showScreenDrawings(drawingExtraction.drawings)
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: drawingExtraction.textWithoutDrawingTags)

                // Step tags sit inside the text, so they're removed after the
                // POINT tag. Their offsets then refer to the exact text spoken.
                let stepExtraction = StepGuidanceParser.extractSteps(
                    from: parseResult.spokenText,
                    screenCaptures: screenCaptures
                )
                // When streaming, steps were already attached to their
                // sentences as they arrived; this list is for text-only replies.
                let guidanceSteps = isStepGuidanceEnabled && streamingReplySpeaker == nil ? stepExtraction.steps : []
                let isWalkingThroughSteps = !guidanceSteps.isEmpty || (streamingReplySpeaker?.guidanceStepCount ?? 0) > 0
                let spokenText = stepExtraction.spokenTextWithoutStepTags
                panelConversation.finish(spokenText, for: panelExchangeID)

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil && !isWalkingThroughSteps
                // If speech already started, the triangle is visible already.
                if hasPointCoordinate && voiceState == .processing {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if !isWalkingThroughSteps,
                   let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                // Note the visual explanation in history so follow-up
                // questions ("why is the nozzle that shape?") have context.
                let assistantResponseForHistory = visualExplanationBrief.map { brief in
                    spokenText + " (then showed a visual explanation: \(brief))"
                } ?? spokenText
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: assistantResponseForHistory
                ))
                recordExchangeInConversationArchive(userTranscript: transcript, assistantResponse: assistantResponseForHistory)

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > Self.maximumConversationHistoryExchangeCount {
                    conversationHistory.removeFirst(conversationHistory.count - Self.maximumConversationHistoryExchangeCount)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                // With spoken replies off, show the text in a bubble instead.
                let hasReplyText = !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let streamingReplySpeaker {
                    // Generation of a visual explanation starts now, but its
                    // narration waits for this lead-in to finish speaking.
                    if let visualExplanationBrief {
                        startVisualExplanation(
                            brief: visualExplanationBrief,
                            userQuestion: transcript,
                            isFollowUp: isVisualExplanationFollowUp,
                            isDockedBesideUserWindow: isVisualExplanationDocked,
                            waitForLeadInToFinish: { await streamingReplySpeaker.waitUntilFinished() }
                        )
                    }
                    await streamingReplySpeaker.waitUntilFinished()
                    if Task.isCancelled { return }
                    if hasReplyText && !streamingReplySpeaker.didSpeakAnything {
                        print("⚠️ ElevenLabs TTS: no sentence could be voiced")
                        speakCreditsErrorFallback()
                    }
                    if isLiveCaptionsEnabled {
                        responseOverlayManager.finishStreaming(afterDelayInSeconds: 1.5)
                    }
                    if isGuidingThroughSteps {
                        // Keep the cursor on the last step for a moment.
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        isGuidingThroughSteps = false
                    }
                } else if hasReplyText && !guidanceSteps.isEmpty {
                    await presentReplyWithStepGuidance(spokenText: spokenText, guidanceSteps: guidanceSteps)
                } else if hasReplyText && !isSpokenReplyEnabled {
                    responseOverlayManager.showOverlayAndBeginStreaming()
                    responseOverlayManager.updateStreamingText(spokenText)
                    responseOverlayManager.finishStreaming()
                } else if hasReplyText {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                        if isLiveCaptionsEnabled {
                            showCaptionUntilSpeechEnds(captionText: spokenText)
                        }
                    } catch {
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
                // Text-only replies: start the visual explanation after the
                // lead-in is shown. (Streaming replies started it above.)
                if streamingReplySpeaker == nil, let visualExplanationBrief, !Task.isCancelled {
                    startVisualExplanation(brief: visualExplanationBrief, userQuestion: transcript, isFollowUp: isVisualExplanationFollowUp, isDockedBesideUserWindow: isVisualExplanationDocked)
                }

                if shouldWaitForClickAfterReply && !Task.isCancelled {
                    // Keep the step circles up so the user sees what to click.
                    if guidedTaskQuestion == nil {
                        guidedTaskQuestion = transcript
                    }
                    startWaitingForGuidedModeClick(replyTextToKeepVisible: isSpokenReplyEnabled ? nil : spokenText)
                } else {
                    if guidedTaskQuestion != nil {
                        print("🧭 Guided mode: task finished")
                        stopGuidedMode()
                    }
                    scheduleScreenDrawingsFadeOut()
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                guard !Task.isCancelled else { return }
                print("⚠️ Companion response error: \(error)")
                panelConversation.fail(
                    "I couldn't finish this reply. Check your connection and API settings, then try again.",
                    for: panelExchangeID
                )
                if presentInMenuBar && !didPresentConversationPanel {
                    NotificationCenter.default.post(name: .heySonaShowConversationPanel, object: nil)
                }
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }

        armEscapeToStopUntilResponseFinishes()
    }

    /// If the cursor is in transient mode (user toggled "Show heySona" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isCursorOverlayEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil || !screenDrawings.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when a
    /// request fails (bad or missing key, no credits, network down). Uses
    /// NSSpeechSynthesizer so it works even when ElevenLabs is down.
    func speakCreditsErrorFallback() {
        let utterance = "I couldn't reach my AI service. Check your API keys and credits in heySona Settings, then try again."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    // MARK: - Onboarding Video

    // MARK: - Onboarding Demo Interaction

}
