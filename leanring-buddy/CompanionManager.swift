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
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

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
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Shows the reply as a text bubble next to the cursor. Only used when
    /// spoken replies are turned off in Settings, since otherwise the reply
    /// is heard instead of read.
    private let responseOverlayManager = CompanionResponseOverlayManager()

    /// ElevenLabs voice used until the user picks a different one in Settings.
    static let defaultElevenLabsVoiceId = "kPzsL2i3teMYv0FxEYQ6"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(voiceId: selectedElevenLabsVoiceId)
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?

    // MARK: - Type-To-Ask And Stop Shortcuts

    private let globalHotKeyRegistrar = GlobalHotKeyRegistrar()
    private let typeToAskPanelManager = TypeToAskPanelManager()
    /// cmd + shift + space, registered for the app's whole lifetime.
    private var typeToAskHotKey: RegisteredGlobalHotKey?
    /// Esc, registered only while a reply is being generated or spoken, so
    /// Esc keeps working normally in other apps the rest of the time.
    private var escapeToStopHotKey: RegisteredGlobalHotKey?
    /// Waits for the current reply to finish, then releases the Esc hot key.
    private var escapeToStopReleaseTask: Task<Void, Never>?
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
    @Published private(set) var isOverlayVisible: Bool = false

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
    private let macActionExecutor = MacActionExecutor()

    /// When on, Claude can take actions on the Mac through tools. Persisted
    /// to UserDefaults; defaults to on.
    @Published private(set) var isMacActionsEnabled: Bool = UserDefaults.standard.object(forKey: "isMacActionsEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isMacActionsEnabled")

    func setMacActionsEnabled(_ enabled: Bool) {
        isMacActionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isMacActionsEnabled")
    }

    /// Everything that varies per request: the system prompt sections, the
    /// user message with context appended, the tools, and who runs them.
    private struct RequestSetup {
        let systemPrompt: String
        let userPrompt: String
        let toolDefinitions: [[String: Any]]
        let toolCallHandler: ClaudeToolCallHandler
    }

    /// Builds the request for one question. Called right when the question
    /// is sent, so project detection sees the app the user is working in.
    private func makeRequestSetup(transcript: String) -> RequestSetup {
        var systemPrompt = Self.companionVoiceResponseSystemPrompt
        var toolDefinitions: [[String: Any]] = []
        // The local time lets "remind me tomorrow at 3" or "what day is it"
        // resolve correctly.
        var userMessageContextLines = ["current local time: \(Self.currentLocalTimeDescription())"]

        if isScreenDrawingEnabled {
            systemPrompt += ScreenDrawingTagParser.systemPromptSection
        }

        if isStepGuidanceEnabled {
            systemPrompt += StepGuidanceParser.systemPromptSection
        }

        if isVisualExplanationEnabled {
            systemPrompt += VisualExplanationSession.mainReplySystemPromptSection
        }

        if isMacActionsEnabled {
            systemPrompt += MacActionTools.systemPromptSection
            toolDefinitions += MacActionTools.toolDefinitionsForClaudeRequest
        }

        if isLongTermMemoryEnabled {
            systemPrompt += PersonalContextTools.memorySystemPromptSection(
                rememberedFactsList: longTermMemoryStore.systemPromptListOfRememberedFacts()
            )
            toolDefinitions += PersonalContextTools.memoryToolDefinitions
        }

        let detectedProject = isProjectAwarenessEnabled
            ? ActiveProjectContext.detectProject(
                isFrontWindowDetectionEnabled: true,
                pinnedProjectFolderPath: pinnedProjectFolderPath
            )
            : nil
        if let detectedProject {
            systemPrompt += PersonalContextTools.projectSystemPromptSection
            toolDefinitions += PersonalContextTools.projectToolDefinitions
            userMessageContextLines.append(ActiveProjectContext.contextDescription(for: detectedProject))
        }

        systemPrompt += PersonalContextTools.noteSystemPromptSection(defaultNoteDestination: defaultNoteDestination)
        toolDefinitions += PersonalContextTools.noteToolDefinitions

        let userPrompt = transcript + "\n\n(" + userMessageContextLines.joined(separator: "\n") + ")"

        return RequestSetup(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            toolDefinitions: toolDefinitions,
            toolCallHandler: makeToolCallHandler(detectedProject: detectedProject)
        )
    }

    /// Sends each tool call to the executor that owns it.
    private func makeToolCallHandler(detectedProject: DetectedProject?) -> ClaudeToolCallHandler {
        return { [weak self] toolName, toolInput in
            guard let self else {
                return (resultText: "heySona is shutting down.", isError: true)
            }

            let toolResult: MacActionResult
            if MacActionToolName(rawValue: toolName) != nil {
                toolResult = await self.macActionExecutor.execute(toolName: toolName, toolInput: toolInput)
            } else {
                toolResult = self.personalContextToolExecutor.execute(
                    toolName: toolName,
                    toolInput: toolInput,
                    detectedProject: detectedProject,
                    noteSettingsSnapshot: NoteSettingsSnapshot(
                        defaultNoteDestination: self.defaultNoteDestination,
                        markdownFolderPath: self.markdownNotesFolderPath,
                        obsidianVaultFolderPath: self.obsidianVaultFolderPath
                    )
                )
            }
            return (resultText: toolResult.resultText, isError: toolResult.isError)
        }
    }

    // MARK: - Memory, Project, And Notes Settings

    /// Facts remembered across launches. Shown and editable in Settings.
    let longTermMemoryStore = LongTermMemoryStore()
    private lazy var personalContextToolExecutor = PersonalContextToolExecutor(longTermMemoryStore: longTermMemoryStore)

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

    /// e.g. "Saturday, October 31, 2026 at 3:12 PM (America/Los_Angeles)"
    private static func currentLocalTimeDescription() -> String {
        let localTimeFormatter = DateFormatter()
        localTimeFormatter.dateStyle = .full
        localTimeFormatter.timeStyle = .short
        return "\(localTimeFormatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    // MARK: - On-Screen Drawing And Captions

    /// Drawings currently shown on the overlay. Each screen's overlay
    /// renders the ones whose display frame matches it.
    @Published private(set) var screenDrawings: [ScreenDrawing] = []
    private var screenDrawingsFadeOutTask: Task<Void, Never>?
    private var captionHideTask: Task<Void, Never>?

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

    /// Opens the built-in rocket engine demo (Settings > Visuals).
    func showVisualExplainerDemo() {
        stopVisualExplanation()
        visualExplainerPanelManager.showDemoRocketExplanation()
    }

    /// When on, "explain how X works" questions open an animated, narrated
    /// explanation in the explainer window.
    @Published private(set) var isVisualExplanationEnabled: Bool = UserDefaults.standard.object(forKey: "isVisualExplanationEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isVisualExplanationEnabled")

    func setVisualExplanationEnabled(_ enabled: Bool) {
        isVisualExplanationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isVisualExplanationEnabled")
    }

    private var currentVisualExplanationSession: VisualExplanationSession?

    private func startVisualExplanation(brief: String, userQuestion: String) {
        stopVisualExplanation()
        print("🎬 Visual explanation requested: \(brief)")

        let visualExplanationSession = VisualExplanationSession(
            explanationBrief: brief,
            userQuestion: userQuestion,
            claudeAPI: claudeAPI,
            elevenLabsTTSClient: elevenLabsTTSClient,
            explainerPanelManager: visualExplainerPanelManager,
            isNarrationEnabled: isSpokenReplyEnabled
        )
        visualExplanationSession.onSceneFailed = { [weak self] spokenFailureMessage in
            guard let self else { return }
            if self.isSpokenReplyEnabled {
                Task { try? await self.elevenLabsTTSClient.speakText(spokenFailureMessage) }
            } else {
                self.responseOverlayManager.showOverlayAndBeginStreaming()
                self.responseOverlayManager.updateStreamingText(spokenFailureMessage)
                self.responseOverlayManager.finishStreaming()
            }
        }
        // Closing the window stops generation and narration.
        visualExplainerPanelManager.onExplainerClosed = { [weak self] in
            self?.stopVisualExplanation()
        }

        currentVisualExplanationSession = visualExplanationSession
        visualExplanationSession.start()
    }

    private func stopVisualExplanation() {
        currentVisualExplanationSession?.stop()
        currentVisualExplanationSession = nil
    }

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
    @Published private(set) var isGuidingThroughSteps: Bool = false
    private var stepGuidanceTask: Task<Void, Never>?

    /// Plays the reply and shows each step (numbered circle + cursor flight)
    /// as the voice reaches it. With spoken replies off, the text is shown
    /// and the steps advance on a reading-pace timer instead.
    private func presentReplyWithStepGuidance(spokenText: String, guidanceSteps: [GuidanceStep]) async {
        var stepActivationTimesInSeconds: [Double]

        if isSpokenReplyEnabled {
            do {
                let timestampedPlayback: (characterStartTimesInSeconds: [Double]?, audioDurationInSeconds: Double)
                do {
                    timestampedPlayback = try await elevenLabsTTSClient.speakTextWithCharacterTimestamps(spokenText)
                } catch is CancellationError {
                    return
                } catch {
                    // Timestamps are a nice-to-have: fall back to plain speech
                    // and estimate step timing from the text.
                    print("⚠️ Timestamped speech failed, estimating step timing: \(error)")
                    try await elevenLabsTTSClient.speakText(spokenText)
                    timestampedPlayback = (nil, elevenLabsTTSClient.currentAudioDurationInSeconds)
                }

                voiceState = .responding
                if isLiveCaptionsEnabled {
                    showCaptionUntilSpeechEnds(captionText: spokenText)
                }
                stepActivationTimesInSeconds = StepGuidanceParser.activationTimesInSeconds(
                    for: guidanceSteps,
                    spokenText: spokenText,
                    characterStartTimesInSeconds: timestampedPlayback.characterStartTimesInSeconds,
                    audioDurationInSeconds: timestampedPlayback.audioDurationInSeconds
                )
            } catch {
                print("⚠️ ElevenLabs TTS error: \(error)")
                speakCreditsErrorFallback()
                return
            }
        } else {
            responseOverlayManager.showOverlayAndBeginStreaming()
            responseOverlayManager.updateStreamingText(spokenText)
            responseOverlayManager.finishStreaming(afterDelayInSeconds: 6 + Double(guidanceSteps.count) * 3)
            let secondsBetweenStepsWhenReading = 3.0
            stepActivationTimesInSeconds = guidanceSteps.indices.map { stepIndex in
                0.4 + Double(stepIndex) * secondsBetweenStepsWhenReading
            }
        }

        print("🪜 Guiding through \(guidanceSteps.count) step(s) at \(stepActivationTimesInSeconds.map { String(format: "%.1fs", $0) })")
        isGuidingThroughSteps = true
        stepGuidanceTask?.cancel()
        let playbackStartDate = Date()

        stepGuidanceTask = Task { [weak self] in
            for (guidanceStep, activationTimeInSeconds) in zip(guidanceSteps, stepActivationTimesInSeconds) {
                let secondsUntilActivation = activationTimeInSeconds - Date().timeIntervalSince(playbackStartDate)
                if secondsUntilActivation > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(secondsUntilActivation * 1_000_000_000))
                }
                guard !Task.isCancelled, let self else { return }
                self.showGuidanceStep(guidanceStep)
            }

            // Keep the cursor on the last step until the voice finishes.
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.isGuidingThroughSteps = false
            // Step circles are added after the reply starts, so the fade-out
            // is scheduled here, once the last step has been shown.
            self?.scheduleScreenDrawingsFadeOut()
        }
    }

    /// Circles the step's target with its number and flies the cursor there.
    private func showGuidanceStep(_ guidanceStep: GuidanceStep) {
        let stepLabelText = guidanceStep.label.map { "\(guidanceStep.stepNumber) · \($0)" } ?? "\(guidanceStep.stepNumber)"

        screenDrawingsFadeOutTask?.cancel()
        screenDrawings.append(ScreenDrawing(
            shape: .circle(center: guidanceStep.displayLocalTargetPoint, radius: 22),
            label: stepLabelText,
            displayFrame: guidanceStep.displayFrame,
            drawingOrder: 0
        ))

        // The bubble text and display frame must be set before the location,
        // since the overlay starts the flight when the location changes.
        detectedElementBubbleText = stepLabelText
        detectedElementDisplayFrame = guidanceStep.displayFrame
        detectedElementScreenLocation = guidanceStep.globalScreenTargetPoint
        print("🪜 Step \(guidanceStep.stepNumber): \(guidanceStep.label ?? "unlabeled")")
    }

    private func stopStepGuidance() {
        stepGuidanceTask?.cancel()
        stepGuidanceTask = nil
        isGuidingThroughSteps = false
    }

    /// When on, the spoken reply is also shown as text next to the cursor.
    @Published private(set) var isLiveCaptionsEnabled: Bool = UserDefaults.standard.object(forKey: "isLiveCaptionsEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isLiveCaptionsEnabled")

    func setLiveCaptionsEnabled(_ enabled: Bool) {
        isLiveCaptionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLiveCaptionsEnabled")
    }

    private func showScreenDrawings(_ drawingsToShow: [ScreenDrawing]) {
        screenDrawingsFadeOutTask?.cancel()
        screenDrawings = drawingsToShow
        print("✏️ Drawing \(drawingsToShow.count) annotation(s) on screen")
    }

    private func clearScreenDrawings() {
        screenDrawingsFadeOutTask?.cancel()
        screenDrawingsFadeOutTask = nil
        guard !screenDrawings.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            screenDrawings = []
        }
    }

    /// Keeps drawings up while the reply is spoken (or read, when muted),
    /// then fades them out so they don't linger over the user's work.
    private func scheduleScreenDrawingsFadeOut() {
        guard !screenDrawings.isEmpty else { return }
        screenDrawingsFadeOutTask?.cancel()
        screenDrawingsFadeOutTask = Task { [weak self] in
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            // Text-only replies need longer, since they're being read.
            let secondsToKeepDrawingsAfterReply: UInt64 = self?.isSpokenReplyEnabled == true ? 4 : 8
            try? await Task.sleep(nanoseconds: secondsToKeepDrawingsAfterReply * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                self.screenDrawings = []
            }
        }
    }

    /// Shows the spoken reply as a caption next to the cursor and hides it
    /// shortly after the audio finishes.
    private func showCaptionUntilSpeechEnds(captionText: String) {
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(captionText)

        captionHideTask?.cancel()
        captionHideTask = Task { [weak self] in
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            self?.responseOverlayManager.finishStreaming(afterDelayInSeconds: 1.5)
        }
    }

    private func hideCaptionAndBubble() {
        captionHideTask?.cancel()
        captionHideTask = nil
        responseOverlayManager.hideOverlay()
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
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 heySona start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        registerTypeToAskHotKeyIfNeeded()
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

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true


        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ heySona: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ heySona: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
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

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isCursorOverlayEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

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
    private func prepareForNewInteraction() {
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
        elevenLabsTTSClient.stopPlayback()
        hideCaptionAndBubble()
        stopStepGuidance()
        stopVisualExplanation()
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

    private func registerTypeToAskHotKeyIfNeeded() {
        guard typeToAskHotKey == nil else { return }
        typeToAskHotKey = globalHotKeyRegistrar.register(
            carbonKeyCode: kVK_Space,
            carbonModifierFlags: cmdKey | shiftKey,
            action: { [weak self] in
                self?.toggleTypeToAskPanel()
            }
        )
    }

    private func toggleTypeToAskPanel() {
        if typeToAskPanelManager.isPanelVisible {
            typeToAskPanelManager.hidePanel()
        } else {
            openTypeToAskPanel()
        }
    }

    /// Opens the Spotlight-style text box. Also used by the menu bar panel's
    /// "Type a question" button.
    func openTypeToAskPanel() {
        // Same conditions as push-to-talk: setup must be finished and the
        // onboarding video must not be playing.
        guard hasCompletedOnboarding && allPermissionsGranted else {
            print("⚠️ Type to ask: finish setup in the menu bar panel first")
            return
        }
        guard !showOnboardingVideo else { return }

        NotificationCenter.default.post(name: .heySonaDismissPanel, object: nil)

        typeToAskPanelManager.showPanel(onSubmitQuestion: { [weak self] typedQuestion in
            self?.submitTypedQuestion(typedQuestion)
        })
    }

    private func submitTypedQuestion(_ typedQuestion: String) {
        guard !buddyDictationManager.isDictationInProgress else { return }

        prepareForNewInteraction()

        lastTranscript = typedQuestion
        print("⌨️ Companion received typed question: \(typedQuestion)")
        sendTranscriptToClaudeWithScreenshot(transcript: typedQuestion)
    }

    // MARK: - Stop / Interrupt

    /// Stops the current reply right away: cancels the Claude request if it's
    /// still running, cuts off speech, and hides the text bubble. Triggered by
    /// Esc while a reply is in progress.
    func stopCurrentResponse() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        elevenLabsTTSClient.stopPlayback()
        hideCaptionAndBubble()
        stopStepGuidance()
        stopVisualExplanation()
        clearScreenDrawings()
        clearDetectedElementLocation()

        if voiceState != .listening {
            voiceState = .idle
        }

        disarmEscapeToStop()
        scheduleTransientHideIfNeeded()
        print("⏹️ Companion response stopped by user")
    }

    /// Registers Esc as a stop key until the current reply has finished
    /// generating and speaking. Must be called after `currentResponseTask`
    /// is assigned so it waits on the right task.
    private func armEscapeToStopUntilResponseFinishes() {
        if escapeToStopHotKey == nil {
            escapeToStopHotKey = globalHotKeyRegistrar.register(
                carbonKeyCode: kVK_Escape,
                carbonModifierFlags: 0,
                action: { [weak self] in
                    self?.stopCurrentResponse()
                }
            )
        }

        escapeToStopReleaseTask?.cancel()
        let responseTaskToWaitFor = currentResponseTask
        escapeToStopReleaseTask = Task { [weak self] in
            await responseTaskToWaitFor?.value

            // speakText returns as soon as playback starts, so also wait
            // for the audio itself to finish.
            while self?.elevenLabsTTSClient.isPlaying == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            guard !Task.isCancelled else { return }
            self?.disarmEscapeToStop()
        }
    }

    private func disarmEscapeToStop() {
        escapeToStopReleaseTask?.cancel()
        escapeToStopReleaseTask = nil
        if let escapeToStopHotKey {
            globalHotKeyRegistrar.unregister(escapeToStopHotKey)
            self.escapeToStopHotKey = nil
        }
    }

    /// Spoken when Claude declines a request and no fallback model answers.
    private static let declinedRequestSpokenReply = "sorry, i can't help with that one. want to try asking it a different way?"

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
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
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

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

                let fullResponseText: String
                do {
                    let streamingResult = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: requestSetup.systemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: requestSetup.userPrompt,
                        tools: requestSetup.toolDefinitions,
                        toolCallHandler: requestSetup.toolDefinitions.isEmpty ? nil : requestSetup.toolCallHandler,
                        onTextChunk: { _ in
                            // No streaming text display — spinner stays until TTS plays
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

                // Drawing tags come before the [POINT:...] tag, which must be
                // last for its parser, so pull them out first. They're always
                // removed from the text so they're never spoken.
                // A [VISUAL:...] brief means Claude wants to explain this in the
                // visual explainer; the spoken reply is just a short lead-in.
                let visualExplanationExtraction = VisualExplanationSession.extractVisualExplanationBrief(from: fullResponseText)
                let visualExplanationBrief = isVisualExplanationEnabled ? visualExplanationExtraction.brief : nil

                let drawingExtraction = ScreenDrawingTagParser.extractDrawings(
                    from: visualExplanationExtraction.textWithoutTag,
                    screenCaptures: screenCaptures
                )
                if isScreenDrawingEnabled && !drawingExtraction.drawings.isEmpty {
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
                let guidanceSteps = isStepGuidanceEnabled ? stepExtraction.steps : []
                let spokenText = stepExtraction.spokenTextWithoutStepTags

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil && guidanceSteps.isEmpty
                if hasPointCoordinate {
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

                if guidanceSteps.isEmpty,
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

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")


                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                // With spoken replies off, show the text in a bubble instead.
                let hasReplyText = !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasReplyText && !guidanceSteps.isEmpty {
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
                // Started after the lead-in begins playing, so the explainer's
                // narration waits for it instead of talking over it.
                if let visualExplanationBrief, !Task.isCancelled {
                    startVisualExplanation(brief: visualExplanationBrief, userQuestion: transcript)
                }

                scheduleScreenDrawingsFadeOut()
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
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
    private func scheduleTransientHideIfNeeded() {
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
    private func speakCreditsErrorFallback() {
        let utterance = "I couldn't reach my AI service. Check your API keys and credits in heySona Settings, then try again."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // the heySona cursor flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're sona, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
