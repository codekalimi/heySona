import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case readingScreen
    case processing
    case agentWorking
    case responding
}

enum HeySonaCursorColor: String, CaseIterable, Identifiable {
    case green
    case blue
    case yellow
    case pink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .pink: "Current"
        }
    }

    var primaryHex: String {
        switch self {
        case .green: "#22C55E"
        case .blue: "#3B82F6"
        case .yellow: "#FACC15"
        case .pink: "#8B1A4A"
        }
    }

    var accentHex: String {
        switch self {
        case .green: "#4ADE80"
        case .blue: "#60A5FA"
        case .yellow: "#FDE047"
        case .pink: "#F7A6C6"
        }
    }

    var primaryColor: Color { Color(hex: primaryHex) }
    var accentColor: Color { Color(hex: accentHex) }
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
    @Published private(set) var hasInputMonitoringPermission = false

    
    
    
    @Published var detectedElementScreenLocation: CGPoint?
    
    
    @Published var detectedElementDisplayFrame: CGRect?
    
    
    @Published var detectedElementBubbleText: String?

    

    
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    
    

    
    
    private static let workerBaseURL = AppBundleConfiguration.serverBaseURL

    private lazy var aiSDK: AISDK = {
        return AISDK(proxyURL: "\(Self.workerBaseURL)/chat")
    }()

    private lazy var gradiumTTSClient: GradiumTTSClient = {
        return GradiumTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    
    
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    
    
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    
    
    private var transientHideTask: Task<Void, Never>?

    
    
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    
    
    @Published private(set) var isOverlayVisible: Bool = false

    
    @Published var selectedCursorColor: HeySonaCursorColor = HeySonaCursorColor(rawValue: UserDefaults.standard.string(forKey: "selectedCursorColor") ?? "") ?? .pink

    func setSelectedCursorColor(_ color: HeySonaCursorColor) {
        selectedCursorColor = color
        UserDefaults.standard.set(color.rawValue, forKey: "selectedCursorColor")
    }

    
    
    
    @Published var isHeySonaCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isHeySonaCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isHeySonaCursorEnabled")

    func setHeySonaCursorEnabled(_ enabled: Bool) {
        isHeySonaCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isHeySonaCursorEnabled")
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

    
    
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print(" heySona start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        
        
        _ = aiSDK

        
        
        
        
        if hasCompletedOnboarding && allPermissionsGranted && isHeySonaCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    
    
    
    
    func triggerOnboarding() {
        
        NotificationCenter.default.post(name: .HeySonaDismissPanel, object: nil)

        
        
        hasCompletedOnboarding = true

        HeySonaAnalytics.trackOnboardingStarted()

        
        
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    
    
    
    
    
    func completeFirstLaunchOnboarding() {
        hasCompletedOnboarding = true
        HeySonaAnalytics.trackOnboardingCompleted()
    }

    func showHeySonaCursorAfterFirstLaunchOnboarding() {
        refreshAllPermissions()

        guard isHeySonaCursorEnabled, allPermissionsGranted else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    
    
    
    func replayOnboarding() {
        NotificationCenter.default.post(name: .HeySonaDismissPanel, object: nil)
        HeySonaAnalytics.trackOnboardingReplayed()
        
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }


    var isTTSPlaying: Bool {
        gradiumTTSClient.isPlaying
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
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        globalPushToTalkShortcutMonitor.start()

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        if #available(macOS 10.15, *) {
            hasInputMonitoringPermission = CGPreflightListenEventAccess()
        } else {
            hasInputMonitoringPermission = true
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            HeySonaAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            HeySonaAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            HeySonaAnalytics.trackPermissionGranted(permission: "microphone")
        }
        
        
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            HeySonaAnalytics.trackAllPermissionsGranted()
        }
    }

    
    
    
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
                
                
                let didCapture = image.width > 0 && image.height > 0
                print("Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    HeySonaAnalytics.trackPermissionGranted(permission: "screen_content")

                    
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isHeySonaCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    

    
    
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    
    
    
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
                
                
                guard self.voiceState != .responding,
                      self.voiceState != .readingScreen,
                      self.voiceState != .agentWorking else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    
                    
                    
                    
                    
                    
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

    func beginManualPushToTalk() {
        handleShortcutTransition(.pressed)
    }

    func endManualPushToTalk() {
        handleShortcutTransition(.released)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            
            transientHideTask?.cancel()
            transientHideTask = nil

            
            // Always surface the cursor overlay while push-to-talk is active so
            // the Listening waveform / Thinking spinner is visible, matching
            // the Electron app. Previously this only showed the overlay when
            // the heySona cursor was disabled, so users with the cursor enabled
            // but hidden never saw the state indicator.
            if !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Show Thinking while the transcription token / websocket is being
            // prepared. The listening waveform should only appear once the
            // transcription session is actually active.
            voiceState = .processing

            
            NotificationCenter.default.post(name: .HeySonaDismissPanel, object: nil)

            
            currentResponseTask?.cancel()
            gradiumTTSClient.stopPlayback()
            clearDetectedElementLocation()

            
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            HeySonaAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("Companion received transcript: \(finalTranscript)")
                        HeySonaAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToAISDKWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            
            
            
            
            if voiceState == .listening {
                voiceState = .processing
            }

            HeySonaAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    

    private static let companionVoiceResponseSystemPrompt = """
    you're heySona, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

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
    you have a small pink triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, use the pointAt tool. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    call pointAt with x, y, a short 1-3 word label (like "search bar" or "save button"), and a short description sentence to speak while pointing there. if the element is on a DIFFERENT screen, include the screen number from the image label. this is important — without the screen number, the cursor will point at the wrong place.

    if the user asks for more than one UI action or target, call pointAt once for each target in order, with a separate spoken description for each target. for example, for "show me how to change font and font size", call pointAt for the font control with a font description, then call pointAt for the font size control with a size description.

    after tool calls, you can add a final short response or summary. it will also be spoken.

    if pointing wouldn't help, do not call the tool.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    

    
    
    
    
    
    private func sendTranscriptToAISDKWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        gradiumTTSClient.stopPlayback()

        currentResponseTask = Task {
            
            voiceState = .readingScreen
            let readingScreenStartedAt = Date()

            do {
                
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Screen capture can complete so quickly that SwiftUI never gets
                // a visible frame to render the Dynamic Island feedback. Keep
                // the state up briefly so users actually see "Reading screen".
                let minimumReadingScreenDuration: TimeInterval = 0.85
                let elapsedReadingScreenDuration = Date().timeIntervalSince(readingScreenStartedAt)
                if elapsedReadingScreenDuration < minimumReadingScreenDuration {
                    try await Task.sleep(nanoseconds: UInt64((minimumReadingScreenDuration - elapsedReadingScreenDuration) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                }

                voiceState = .processing

                
                
                
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await aiSDK.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        
                    },
                    onToolActivity: { [weak self] _, isRunning in
                        guard let self else { return }
                        self.voiceState = isRunning ? .agentWorking : .processing
                    }
                )

                guard !Task.isCancelled else { return }

                
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText
                let pointingSequence = Self.pointingSequence(from: fullResponseText)

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("Conversation history: \(conversationHistory.count) exchanges")
                HeySonaAnalytics.trackAIResponseReceived(response: spokenText)

                do {
                    if pointingSequence.isEmpty {
                        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            voiceState = .responding
                            try await speakAndWait(spokenText)
                        }
                    } else {
                        for step in pointingSequence {
                            guard !Task.isCancelled else { return }
                            voiceState = .responding
                            applyPointingResult(step.point, screenCaptures: screenCaptures)
                            HeySonaAnalytics.trackElementPointed(elementLabel: step.point.elementLabel)
                            if let pointCoordinate = step.point.coordinate {
                                print("Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(step.point.elementLabel ?? "element")\"")
                            }
                            let trimmedSpeech = step.speech.trimmingCharacters(in: .whitespacesAndNewlines)

                            // Give the overlay enough time to actually fly to and dwell on this
                            // target before the next POINT tag updates detectedElementScreenLocation.
                            // AI SDK responses often put several point tags at the end with little or
                            // no text between them; without this minimum dwell, the published location
                            // is overwritten rapidly and the cursor only visibly points at the last one.
                            try await Task.sleep(nanoseconds: trimmedSpeech.isEmpty ? 2_200_000_000 : 900_000_000)

                            if !trimmedSpeech.isEmpty {
                                try await speakAndWait(trimmedSpeech)
                                voiceState = .idle
                                try await Task.sleep(nanoseconds: 350_000_000)
                            }
                        }
                    }
                } catch {
                    HeySonaAnalytics.trackTTSError(error: error.localizedDescription)
                    print("Gradium TTS error: \(error)")
                }
            } catch is CancellationError {
                
            } catch {
                HeySonaAnalytics.trackResponseError(error: error.localizedDescription)
                print("Companion response error: \(error)")
                
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    
    
    
    
    private func scheduleTransientHideIfNeeded() {
        guard !isHeySonaCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            
            while gradiumTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            
            
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    

    
    struct PointingParseResult {
        
        let spokenText: String
        
        let coordinate: CGPoint?
        
        let elementLabel: String?
        
        let screenNumber: Int?
    }

    struct PointingSpeechStep {
        let point: PointingParseResult
        let speech: String
    }

    private func speakAndWait(_ text: String) async throws {
        try await gradiumTTSClient.speakText(text)
        while gradiumTTSClient.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    
    
    static func latestPointTag(in responseText: String) -> String? {
        let pattern = #"\[POINT:(?:none|\d+\s*,\s*\d+(?::[^\]:\s][^\]:]*?)?(?::screen\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        guard let match = matches.last, let range = Range(match.range, in: responseText) else { return nil }
        return String(responseText[range])
    }

    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, range: fullRange)
        guard let match = matches.last else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let spokenText = regex.stringByReplacingMatches(in: responseText, options: [], range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        
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

    static func pointingSequence(from responseText: String) -> [PointingSpeechStep] {
        let pattern = #"\[POINT:(?:none|\d+\s*,\s*\d+(?::[^\]:\s][^\]:]*?)?(?::screen\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        guard !matches.isEmpty else { return [] }

        let prefixSpeech: String = {
            guard let firstRange = Range(matches[0].range, in: responseText) else { return "" }
            return String(responseText[..<firstRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        var steps: [PointingSpeechStep] = []
        var seenPointKeys = Set<String>()
        for (index, match) in matches.enumerated() {
            guard let tagRange = Range(match.range, in: responseText) else { continue }
            let nextStart = index + 1 < matches.count
                ? Range(matches[index + 1].range, in: responseText)?.lowerBound
                : responseText.endIndex
            guard let segmentEnd = nextStart else { continue }

            let tag = String(responseText[tagRange])
            let point = parsePointingCoordinates(from: tag)
            guard let coordinate = point.coordinate else { continue }

            // Some models repeat the exact same navigation plan after completing it
            // (especially after tool/tag conversion). Keep the first occurrence so
            // join → share → download doesn't replay as join → share → download again.
            let pointKey = [
                String(Int(coordinate.x.rounded())),
                String(Int(coordinate.y.rounded())),
                point.elementLabel?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                point.screenNumber.map(String.init) ?? ""
            ].joined(separator: ":")
            guard !seenPointKeys.contains(pointKey) else { continue }
            seenPointKeys.insert(pointKey)

            var speech = String(responseText[tagRange.upperBound..<segmentEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0, !prefixSpeech.isEmpty {
                speech = speech.isEmpty ? prefixSpeech : "\(prefixSpeech) \(speech)"
            }
            steps.append(PointingSpeechStep(point: point, speech: speech))
        }
        return steps
    }

    private func applyPointingResult(_ parseResult: PointingParseResult, screenCaptures: [CompanionScreenCapture]) {
        guard let pointCoordinate = parseResult.coordinate else { return }

        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        guard let targetScreenCapture else { return }

        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        detectedElementBubbleText = parseResult.elementLabel
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    

    func startOnboardingPromptStream() {
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

    

    private static let onboardingDemoSystemPrompt = """
    you're heySona, a small pink cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    
    
    
    func performOnboardingDemoInteraction() {
        
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                
                
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await aiSDK.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("Onboarding demo: no element to point at")
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

                
                
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" - \"\(parseResult.spokenText)\"")
            } catch {
                print("Onboarding demo error: \(error)")
            }
        }
    }
}
