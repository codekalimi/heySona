//
//  VisualExplanationSession.swift
//  leanring-buddy
//
//  One visual explanation, from question to finished narration:
//
//  1. Asks Claude to write a scene for the topic. Claude streams it as JSON
//     Lines: the first line sets up the scene, each following line is one
//     step, so the first step can play while later steps are still written.
//  2. Shows the scene in the explainer window as lines arrive.
//  3. With spoken replies on, narrates each step with ElevenLabs while the
//     window shows it, preparing the next step's audio in the background.
//     Pause, previous/next, and the step dots in the window keep the voice
//     in sync. With spoken replies off, the window advances on its own.
//

import Foundation

/// Where a session's scene comes from.
enum VisualExplanationSource {
    /// Claude writes a new scene for a question.
    case newTopic
    /// Claude adds steps to the scene already open, answering a follow-up.
    case followUp(existingSceneLines: [String])
    /// A scene saved in the library, replayed without asking Claude.
    case saved(sceneLines: [String])
}

@MainActor
final class VisualExplanationSession {
    private let source: VisualExplanationSource
    private let explanationBrief: String
    private let userQuestion: String
    private let claudeAPI: ClaudeAPI
    private let elevenLabsTTSClient: ElevenLabsTTSClient
    private let explainerPanelManager: VisualExplainerPanelManager
    private let isNarrationEnabled: Bool

    private var sceneStreamingTask: Task<Void, Never>?
    private var narrationTask: Task<Void, Never>?

    /// Narration text of every step received so far, by step index.
    private var stepNarrations: [String] = []
    /// The furthest step shown so far; the self-check only replaces later ones.
    private var highestStartedStepIndex = -1
    /// Problems the renderer's layout self-check reported, for the Claude review.
    private(set) var layoutIssueLines: [String] = []
    private var isSceneStreamFinished = false
    private var hasShownSceneHeader = false

    /// The step the narration asked the window to show. A "stepStarted"
    /// message for any other step means the user navigated in the window.
    private var stepIndexRequestedByNarration: Int?
    private var stepIndexRequestedByUser: Int?
    private var isPausedByUser = false
    private var isNarrationLoopRunning = false

    /// Audio prepared ahead of time, by step index.
    private var preparedNarrationAudioByStepIndex: [Int: Data] = [:]
    private var narrationAudioPreparationTasks: [Int: Task<Data?, Never>] = [:]

    /// Awaited before the first narration, so it doesn't talk over heySona's
    /// streamed lead-in.
    var waitForLeadInToFinish: (() async -> Void)?

    /// Called once if the scene couldn't be made, with a short spoken apology.
    var onSceneFailed: ((_ spokenFailureMessage: String) -> Void)?

    /// Called once the whole scene has arrived (setup, steps, quiz), with
    /// every line as played, so it can be saved and followed up on.
    var onSceneCompleted: ((_ sceneLines: [String], _ sceneTitle: String, _ concepts: ExplanationConcepts?) -> Void)?

    /// Every line of the scene so far, normalized: setup, steps, quiz.
    private var recordedSceneLines: [String] = []
    private var recordedQuizLine: String?
    /// From the scene's {"concepts": {...}} line; kept out of the scene lines.
    private var recordedConcepts: ExplanationConcepts?
    /// Topics already explained (from the library), so this explanation can
    /// link back to them. Nil when nothing is saved yet.
    private let learnedTopicsDescription: String?
    /// Topic skills matched to the brief (recipes for drawing this subject).
    private let topicSkillsText: String?
    private var sceneTitle = "Explanation"

    init(
        source: VisualExplanationSource = .newTopic,
        explanationBrief: String,
        userQuestion: String,
        claudeAPI: ClaudeAPI,
        elevenLabsTTSClient: ElevenLabsTTSClient,
        explainerPanelManager: VisualExplainerPanelManager,
        isNarrationEnabled: Bool,
        learnedTopicsDescription: String? = nil,
        topicSkillsText: String? = nil
    ) {
        self.learnedTopicsDescription = learnedTopicsDescription
        self.topicSkillsText = topicSkillsText
        self.source = source
        self.explanationBrief = explanationBrief
        self.userQuestion = userQuestion
        self.claudeAPI = claudeAPI
        self.elevenLabsTTSClient = elevenLabsTTSClient
        self.explainerPanelManager = explainerPanelManager
        self.isNarrationEnabled = isNarrationEnabled
    }

    // MARK: - Start And Stop

    func start() {
        explainerPanelManager.onStepStarted = { [weak self] stepIndex, _ in
            self?.handleWindowStepStarted(stepIndex: stepIndex)
        }
        explainerPanelManager.onPlayPauseRequested = { [weak self] isPlaying in
            self?.handleWindowPlayPause(isPlaying: isPlaying)
        }
        explainerPanelManager.onStepIssuesReported = { [weak self] stepIndex, issues in
            self?.layoutIssueLines.append("step \(stepIndex): " + issues.joined(separator: "; "))
        }

        switch source {
        case .newTopic:
            explainerPanelManager.showPreparingStatus("Building your explanation…")
            sceneStreamingTask = Task { [weak self] in
                await self?.streamSceneFromClaude()
            }

        case .followUp(let existingSceneLines):
            // The scene is already on screen: remember its steps so new step
            // indexes continue after them, then let Claude add steps.
            for existingSceneLine in existingSceneLines {
                guard let lineObject = Self.jsonObject(from: existingSceneLine) else { continue }
                if recordedSceneLines.isEmpty {
                    sceneTitle = lineObject["title"] as? String ?? sceneTitle
                    recordedSceneLines.append(existingSceneLine)
                } else if lineObject["quiz"] != nil {
                    recordedQuizLine = existingSceneLine
                } else {
                    recordedSceneLines.append(existingSceneLine)
                    stepNarrations.append(lineObject["narration"] as? String ?? "")
                }
            }
            hasShownSceneHeader = true
            explainerPanelManager.continueScene()
            if isNarrationEnabled {
                startNarrationLoop(fromStepIndex: stepNarrations.count)
            }
            sceneStreamingTask = Task { [weak self] in
                await self?.streamSceneFromClaude()
            }

        case .saved(let sceneLines):
            sceneLines.forEach(handleSceneLine)
            isSceneStreamFinished = true
            if hasShownSceneHeader {
                explainerPanelManager.finishSteps()
            }
        }
    }

    /// Stops generation and narration. The window stays open for the user.
    func stop() {
        sceneStreamingTask?.cancel()
        narrationTask?.cancel()
        narrationAudioPreparationTasks.values.forEach { $0.cancel() }
        narrationAudioPreparationTasks = [:]
        elevenLabsTTSClient.stopPlayback()
        explainerPanelManager.onStepStarted = nil
        explainerPanelManager.onPlayPauseRequested = nil
        explainerPanelManager.onStepIssuesReported = nil
    }

    /// Applies a visual self-check fix if the step hasn't been shown yet.
    /// Returns whether it was applied live.
    @discardableResult
    func applyReviewedStepFix(stepIndex: Int, stepJSON: String) -> Bool {
        guard stepIndex > highestStartedStepIndex, stepIndex < stepNarrations.count,
              stepIndex + 1 < recordedSceneLines.count,
              let stepObject = Self.jsonObject(from: stepJSON) else { return false }
        stepNarrations[stepIndex] = stepObject["narration"] as? String ?? ""
        recordedSceneLines[stepIndex + 1] = stepJSON
        // Narration audio prepared from the old text is no longer right.
        narrationAudioPreparationTasks[stepIndex]?.cancel()
        narrationAudioPreparationTasks[stepIndex] = nil
        preparedNarrationAudioByStepIndex[stepIndex] = nil
        explainerPanelManager.replaceStep(stepIndex: stepIndex, stepJSON: stepJSON)
        return true
    }

    // MARK: - Scene Streaming

    private func streamSceneFromClaude() async {
        let sceneLineReader = JSONLineReader()

        let isFollowUp: Bool
        if case .followUp = source { isFollowUp = true } else { isFollowUp = false }
        // In the user prompt, not the system prompt, so the system prompt
        // stays identical between requests and keeps its prompt cache.
        let learnedTopicsSection = learnedTopicsDescription.map {
            "\n\nTopics the user has already learned with heySona (connect to them where it truly helps, and name them exactly in the concepts line): \($0)"
        } ?? ""
        let sceneRequestUserPrompt = (isFollowUp
            ? """
            The scene currently open, as JSON Lines (setup line, then steps):
            \(recordedSceneLines.joined(separator: "\n"))

            The user's follow-up: "\(userQuestion)"

            What to show next: \(explanationBrief)

            Write only the new step lines now (and new quiz and concepts lines at the end if they fit).
            """
            : """
            The user asked: "\(userQuestion)"

            What to explain: \(explanationBrief)

            Write the scene now, as JSON Lines.
            """) + learnedTopicsSection + (topicSkillsText.map { "\n\nTopic recipes to follow:\n" + $0 } ?? "")

        do {
            _ = try await claudeAPI.analyzeImageStreaming(
                images: [],
                systemPrompt: isFollowUp ? Self.sceneAuthoringSystemPrompt + Self.followUpAuthoringPromptSection : Self.sceneAuthoringSystemPrompt,
                userPrompt: sceneRequestUserPrompt,
                onTextChunk: { [weak self] accumulatedText in
                    for completeLine in sceneLineReader.newCompleteLines(in: accumulatedText) {
                        self?.handleSceneLine(completeLine)
                    }
                }
            )
        } catch is CancellationError {
            return
        } catch {
            print("⚠️ Visual explanation: scene request failed: \(error)")
        }

        guard !Task.isCancelled else { return }

        // The last line has no trailing newline.
        if let finalLine = sceneLineReader.remainingPartialLine() {
            handleSceneLine(finalLine)
        }

        isSceneStreamFinished = true
        guard hasShownSceneHeader else {
            print("⚠️ Visual explanation: no usable scene was produced")
            explainerPanelManager.closeExplainer()
            onSceneFailed?("sorry, i couldn't build a visual for that one. want me to just explain it out loud?")
            return
        }
        explainerPanelManager.finishSteps()
        print("🎬 Visual explanation: scene complete with \(stepNarrations.count) step(s)")
        onSceneCompleted?(recordedSceneLines + [recordedQuizLine].compactMap { $0 }, sceneTitle, recordedConcepts)
    }

    /// Routes one JSON line: the first scene object sets up the scene,
    /// every later object is a step. Anything else (prose, code fences,
    /// malformed JSON) is skipped so one bad line doesn't sink the scene.
    private func handleSceneLine(_ sceneLine: String) {
        let trimmedSceneLine = sceneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSceneLine.hasPrefix("{"),
              let lineData = trimmedSceneLine.data(using: .utf8),
              let lineObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            if !trimmedSceneLine.isEmpty {
                print("⚠️ Visual explanation: skipped a line that isn't a JSON object")
            }
            return
        }

        // The concepts line ({"concepts": {...}}) links this explanation to
        // others on the concept map. It isn't shown or replayed.
        if let conceptsObject = lineObject["concepts"] as? [String: Any], lineObject["actions"] == nil {
            handleConcepts(conceptsObject)
            if hasShownSceneHeader || lineObject["objects"] == nil { return }
        }

        // A quiz can come as its own line ({"quiz": [...]}) at the end.
        if hasShownSceneHeader, let quizQuestions = lineObject["quiz"] as? [Any] {
            handleQuiz(quizQuestions)
            return
        }

        if !hasShownSceneHeader {
            // Steps written inside the header (instead of on their own
            // lines) are split out and handled like streamed steps.
            var sceneHeader = lineObject
            let stepsInsideHeader = sceneHeader["steps"] as? [[String: Any]] ?? []
            let quizInsideHeader = sceneHeader["quiz"] as? [Any]
            sceneHeader["steps"] = [Any]()
            sceneHeader["quiz"] = nil
            sceneHeader["concepts"] = nil
            guard let headerJSON = Self.jsonText(sceneHeader) else { return }

            hasShownSceneHeader = true
            sceneTitle = sceneHeader["title"] as? String ?? sceneTitle
            recordedSceneLines.append(headerJSON)
            explainerPanelManager.showScene(
                sceneJSON: headerJSON,
                autoAdvance: !isNarrationEnabled,
                stepsStillStreaming: true
            )
            print("🎬 Visual explanation: scene \"\(sceneHeader["title"] as? String ?? "untitled")\" started")
            if isNarrationEnabled {
                startNarrationLoop()
            }
            stepsInsideHeader.forEach(handleStepObject)
            if let quizInsideHeader {
                handleQuiz(quizInsideHeader)
            }
            return
        }

        handleStepObject(lineObject)
    }

    private func handleStepObject(_ stepObject: [String: Any]) {
        guard stepObject["narration"] != nil || stepObject["actions"] != nil,
              let stepJSON = Self.jsonText(stepObject) else { return }
        stepNarrations.append(stepObject["narration"] as? String ?? "")
        recordedSceneLines.append(stepJSON)
        explainerPanelManager.appendStep(stepJSON: stepJSON)
    }

    private func handleQuiz(_ quizQuestions: [Any]) {
        guard let quizData = try? JSONSerialization.data(withJSONObject: quizQuestions),
              let quizJSON = String(data: quizData, encoding: .utf8) else { return }
        recordedQuizLine = Self.jsonText(["quiz": quizQuestions])
        explainerPanelManager.setQuiz(quizJSON: quizJSON)
    }

    private func handleConcepts(_ conceptsObject: [String: Any]) {
        guard let conceptsData = try? JSONSerialization.data(withJSONObject: conceptsObject),
              let concepts = try? JSONDecoder().decode(ExplanationConcepts.self, from: conceptsData),
              !concepts.mainConcept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("⚠️ Visual explanation: skipped an unreadable concepts line")
            return
        }
        recordedConcepts = concepts
        print("🧠 Visual explanation: concepts \(concepts.mainConcept) → \(concepts.relatedConcepts + concepts.prerequisiteConcepts)")
    }

    private static func jsonObject(from jsonLine: String) -> [String: Any]? {
        guard let lineData = jsonLine.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
    }

    // MARK: - Narration

    /// `isFirstStepAlreadyShown` is true when the user picked the step in
    /// the window, so it's on screen and shouldn't be replayed visually.
    private func startNarrationLoop(fromStepIndex firstStepIndex: Int = 0, isFirstStepAlreadyShown: Bool = false) {
        narrationTask?.cancel()
        narrationTask = Task { [weak self] in
            await self?.narrateSteps(fromStepIndex: firstStepIndex, isFirstStepAlreadyShown: isFirstStepAlreadyShown)
        }
    }

    private func narrateSteps(fromStepIndex firstStepIndex: Int, isFirstStepAlreadyShown: Bool) async {
        isNarrationLoopRunning = true
        defer { isNarrationLoopRunning = false }

        // Let heySona's spoken lead-in ("let me show you…") finish first.
        if let waitForLeadInToFinish {
            await waitForLeadInToFinish()
            if Task.isCancelled { return }
        }
        while elevenLabsTTSClient.isPlaying {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }

        var stepIndex = firstStepIndex
        var isStepAlreadyShownByUser = isFirstStepAlreadyShown
        while !Task.isCancelled {
            // Wait for this step to stream in, or for the scene to end.
            while stepIndex >= stepNarrations.count && !isSceneStreamFinished {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
            guard stepIndex < stepNarrations.count else {
                if recordedQuizLine != nil, let quizInvitationAudio = try? await elevenLabsTTSClient.synthesizeSpeechAudio("when you're ready, try the quick quiz to check your understanding.") {
                    if Task.isCancelled { return }
                    try? elevenLabsTTSClient.playSpeechAudio(quizInvitationAudio)
                }
                explainerPanelManager.markFinished()
                return
            }

            stepIndexRequestedByNarration = stepIndex
            stepIndexRequestedByUser = nil
            if !isStepAlreadyShownByUser {
                explainerPanelManager.goToStep(stepIndex)
            }
            isStepAlreadyShownByUser = false
            prepareNarrationAudio(forStepIndex: stepIndex + 1)

            await narrateStep(stepIndex)
            if Task.isCancelled { return }

            // The user picked another step while this one was playing.
            if let stepIndexRequestedByUser {
                elevenLabsTTSClient.stopPlayback()
                stepIndex = stepIndexRequestedByUser
                isStepAlreadyShownByUser = true
                continue
            }

            // A short beat between steps lets the visual land.
            try? await Task.sleep(nanoseconds: 400_000_000)
            stepIndex += 1
        }
    }

    private func narrateStep(_ stepIndex: Int) async {
        highestStartedStepIndex = max(highestStartedStepIndex, stepIndex)
        let narrationText = stepNarrations[stepIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narrationText.isEmpty else {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            return
        }

        let narrationAudio: Data?
        if let preparedNarrationAudio = preparedNarrationAudioByStepIndex[stepIndex] {
            narrationAudio = preparedNarrationAudio
        } else if let narrationAudioPreparationTask = narrationAudioPreparationTasks[stepIndex] {
            narrationAudio = await narrationAudioPreparationTask.value
        } else {
            narrationAudio = try? await elevenLabsTTSClient.synthesizeSpeechAudio(narrationText)
        }
        if Task.isCancelled || stepIndexRequestedByUser != nil { return }

        guard let narrationAudio, (try? elevenLabsTTSClient.playSpeechAudio(narrationAudio)) != nil else {
            // No voice available: give the user time to read the caption.
            try? await Task.sleep(nanoseconds: UInt64(max(3.0, Double(narrationText.count) / 15.0) * 1_000_000_000))
            return
        }

        // Wait for the audio to end, holding while the user has paused.
        while (elevenLabsTTSClient.isPlaying || isPausedByUser) && stepIndexRequestedByUser == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
    }

    /// Starts making the audio for a step in the background, if it exists.
    private func prepareNarrationAudio(forStepIndex stepIndex: Int) {
        guard stepIndex < stepNarrations.count,
              preparedNarrationAudioByStepIndex[stepIndex] == nil,
              narrationAudioPreparationTasks[stepIndex] == nil else { return }
        let narrationText = stepNarrations[stepIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narrationText.isEmpty else { return }

        narrationAudioPreparationTasks[stepIndex] = Task { [weak self] in
            guard let self else { return nil }
            let narrationAudio = try? await self.elevenLabsTTSClient.synthesizeSpeechAudio(narrationText)
            if let narrationAudio {
                self.preparedNarrationAudioByStepIndex[stepIndex] = narrationAudio
            }
            return narrationAudio
        }
    }

    // MARK: - Window Controls

    private func handleWindowStepStarted(stepIndex: Int) {
        highestStartedStepIndex = max(highestStartedStepIndex, stepIndex)
        guard isNarrationEnabled else { return }
        if stepIndex == stepIndexRequestedByNarration { return }

        // The user clicked previous/next, a step dot, or replay.
        isPausedByUser = false
        if isNarrationLoopRunning {
            stepIndexRequestedByUser = stepIndex
            elevenLabsTTSClient.stopPlayback()
        } else {
            // Narration already finished: replay or a step click restarts it.
            elevenLabsTTSClient.stopPlayback()
            startNarrationLoop(fromStepIndex: stepIndex, isFirstStepAlreadyShown: true)
        }
    }

    private func handleWindowPlayPause(isPlaying: Bool) {
        guard isNarrationEnabled else { return }
        isPausedByUser = !isPlaying
        if isPlaying {
            elevenLabsTTSClient.resumePlayback()
        } else {
            elevenLabsTTSClient.pausePlayback()
        }
    }

    // MARK: - Helpers

    private static func jsonText(_ jsonObject: [String: Any]) -> String? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject) else { return nil }
        return String(data: jsonData, encoding: .utf8)
    }

    /// Added to the authoring prompt when continuing an open scene.
    static let followUpAuthoringPromptSection = """


    FOLLOW-UP MODE: the scene is already on screen and the user asked a follow-up. Do NOT write a setup line. Write only 2 to 4 new step lines that answer the follow-up, continuing from where the scene is: reuse the existing object ids (they're all still there, in the state the last step left them), move the camera to what the follow-up is about, add new objects with "add" if needed (with new unique ids), and tidy up earlier labels and effects that no longer apply. Optionally end with a new quiz line about the follow-up, and a concepts line listing any new related ideas.
    If the user asked for it simpler (or said they didn't get it), re-explain the same idea from scratch in even plainer words, with a different, more everyday analogy and a smaller concrete example; don't just repeat the earlier steps.
    """

    // MARK: - Main Reply Tag

    /// Finds a [VISUAL:brief] tag anywhere in Claude's main reply and
    /// removes it so it's never spoken.
    static func extractVisualExplanationBrief(from responseText: String) -> (textWithoutTag: String, brief: String?) {
        guard let visualTagRegex = try? NSRegularExpression(pattern: #"\[VISUAL:\s*([^\]]+?)\s*\]"#, options: [.caseInsensitive]),
              let tagMatch = visualTagRegex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(tagMatch.range, in: responseText),
              let briefRange = Range(tagMatch.range(at: 1), in: responseText) else {
            return (responseText, nil)
        }

        let brief = String(responseText[briefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var textWithoutTag = responseText
        textWithoutTag.removeSubrange(tagRange)
        textWithoutTag = textWithoutTag
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (textWithoutTag, brief.isEmpty ? nil : brief)
    }

    /// Finds a [VISUAL_FOLLOWUP:brief] tag (a follow-up about the scene
    /// already open) and removes it so it's never spoken.
    static func extractVisualFollowUpBrief(from responseText: String) -> (textWithoutTag: String, brief: String?) {
        guard let followUpTagRegex = try? NSRegularExpression(pattern: #"\[VISUAL_FOLLOWUP:\s*([^\]]+?)\s*\]"#, options: [.caseInsensitive]),
              let tagMatch = followUpTagRegex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(tagMatch.range, in: responseText),
              let briefRange = Range(tagMatch.range(at: 1), in: responseText) else {
            return (responseText, nil)
        }
        let brief = String(responseText[briefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var textWithoutTag = responseText
        textWithoutTag.removeSubrange(tagRange)
        textWithoutTag = textWithoutTag.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (textWithoutTag, brief.isEmpty ? nil : brief)
    }

    /// Added to the main system prompt while an explanation is open, so
    /// follow-up questions build on it instead of starting over.
    static func followUpMainReplySystemPromptSection(openSceneTitle: String) -> String {
        """

        the visual explainer is open, showing "\(openSceneTitle)". if the user's question is a follow-up about it (zoom in, show a part, go deeper, why or how something in it works, compare a part, explain it simpler or with a different analogy, how it relates to another idea), reply with a short one-sentence lead-in and add [VISUAL_FOLLOWUP:a brief of what to show and explain next] at the very end, before [POINT:none]; the explainer will add new steps to the same scene. if they ask about something different that deserves its own visual, use [VISUAL:...] instead. otherwise answer normally.
        """
    }

    /// Appended to the main system prompt while visual explanations are on.
    static let mainReplySystemPromptSection = """

    visual explanations:
    you can open heySona's visual explainer: a window where an animated 3d model or 2d diagram is built and narrated step by step. use it when the user asks you to explain, show, teach, or visualize how something works, what's inside something, how a process unfolds, or how ideas connect, whenever seeing it would genuinely help (data structures, algorithms, math ideas, machine learning, neural networks, ai agents, how computers work, machines, science, history). the user is learning computer science, math, data structures and algorithms, machine learning, deep learning, and ai agents, so lean toward a visual for "how does it work" and "what is" questions about these. don't use it for quick facts, yes or no questions, or things on their screen you can simply point at.
    when you use it, your spoken reply is only a short, natural one-sentence lead-in like "sure, let me show you how a rocket engine works." the explainer gives the full explanation, so don't explain it yourself. then add this tag at the very end, before [POINT:none]: [VISUAL:a detailed brief for the explainer: what to explain, the level (a curious beginner, in simple english, unless they say otherwise), the parts or stages to cover in order, a real-world analogy that fits, a tiny concrete example to walk through (for example, five numbers to sort or a three-node network), and anything relevant from their screen or this conversation]. the brief must not contain square brackets.
    """

    // MARK: - Scene Authoring Prompt

    /// Teaches Claude the scene format (mirrors the documentation at the top
    /// of VisualExplainer.bundle/visual-explainer.js) and what makes a good
    /// visual explanation.
    static let sceneAuthoringSystemPrompt = """
    You create animated visual explanations for heySona, a Mac assistant. Your output is rendered by a 3D/2D engine and each step's narration is spoken aloud while its visuals play. You write data, not code.

    OUTPUT FORMAT: JSON Lines. No prose, no markdown, no code fences.
    - Line 1: the scene setup object: {"title", "mode", "camera", "floor", "view", "objects"}.
    - Every following line: one step object: {"narration", "actions"}.
    - One complete JSON object per line. Write lines in order; the first step plays while you write the rest, so put line 1 and the first step out quickly and keep line 1 small (start with only the objects the first steps need; bring in the rest with "add" actions in later steps).

    SCENE SETUP
    - "mode": "3d" for physical things (machines, bodies, planets, molecules, buildings); "2d" for flat diagrams (graphs, charts, timelines, flowcharts, processes, algorithms, maps of ideas).
    - "camera": {"fit": true, "angle": [degreesAround, degreesAboveHorizon], "autoRotate": true}. Prefer fit over positions. autoRotate false for 2d.
    - 3d: y is up, the ground is around y = 0, keep the model within about -8..8 on each axis, sizes about 0.2-10 units. "floor": true adds a subtle grid ("floorY" moves it).
    - 2d: x right, y up, z = 0. "view": {"width": 18} shows x from about -9 to 9 and y from about -5 to 5. Keep content inside that.
    - Colors: hex strings that read well on a near-black background: #3380ff blue, #7cc4ff light blue, #ff9a3c orange, #ffd27a yellow, #4cd6a0 green, #ff6b8b pink, #c9a0ff purple, #dfe5ee light gray, #8fa3c7 slate.

    OBJECTS (every object needs a unique "id"; numbers in scene units, angles in degrees):
    common fields: "position": [x,y,z], "rotation": [x,y,z], "scale", "color", "opacity" (0-1), "hidden": true (start invisible), "metalness", "roughness"
    - box: "size": [w,h,d]
    - sphere: "radius"
    - cylinder: "radius" (or "radiusTop"/"radiusBottom"), "height", "openEnded"
    - cone: "radius", "height"
    - torus: "radius", "tube"
    - lathe: "profile": [[radius, y], ...] spun around the y axis (nozzles, vases, bells, bottles, cells)
    - tube: "points": [[x,y,z], ...], "radius" (smooth pipes, vessels, wires)
    - line: "points": [[x,y,z], ...], "width" (straight segments: graph curves, axes, timelines, arrows' paths). "drawn": false starts it invisible so a "draw" action traces it. For a graph, compute the curve's points yourself (up to 60 points) and scale them into the view.
    - rect: "size": [w,h]   circle: "radius"   ring: "innerRadius", "outerRadius" (flat shapes; in 3d rotate [-90,0,0] to lay flat)
    - card: "title", "text", "width" (pixels, 180-260) — a text box at "position" for definitions, notes, timeline events. Keep text under 25 words. "math": a LaTeX equation typeset above the text (KaTeX), for example "math":"w_{\\\\text{new}} = w - \\\\eta \\\\frac{dL}{dw}" (in JSON every LaTeX backslash is written twice).

    ACTIONS (inside each step's "actions"; "targets" is an id or a list of ids):
    - show / hide: {"do":"show","targets":[...]}
    - focus: spotlight targets and dim everything else. unfocus: undo.
    - highlight: {"do":"highlight","targets":"x","color":"#ff9a3c","glow":true}. unhighlight.
    - cutaway: {"do":"cutaway","targets":"shell","opacity":0.12} makes an outer shell see-through to reveal insides.
    - color: {"do":"color","targets":"x","color":"#hex"}
    - label: {"do":"label","target":"x","text":"Short name","offset":[x,y,z]} or {"do":"label","position":[x,y,z],"text":"..."}. unlabel: {"do":"unlabel"} (all) or with targets. Offset labels to the side when objects are stacked so labels don't cover each other.
    - arrow: {"do":"arrow","from":[x,y,z] or "id","to":[x,y,z] or "id","text":"Force","color":"#hex"}
    - flow: {"do":"flow","path":["id", [x,y,z], "id2"],"color":"#hex","speed":1.5,"count":30} glowing particles moving along a path (blood, current, fuel, data packets, heat).
    - plume: {"do":"plume","from":"id" or [x,y,z],"direction":[0,-1,0],"length":4,"spread":0.3,"color":"#ff9a3c"} exhaust, steam, sparks.
    - spin: {"do":"spin","targets":"gear","axis":"y","speed":1} turns per second. stopSpin.
    - revolve: {"do":"revolve","targets":"electron","center":[0,0,0],"speed":0.3,"axis":"y"} orbit around a point (axis defaults to z in 2d). stopRevolve.
    - move: {"do":"move","targets":"block","to":[x,y,z],"seconds":1.2} or "by":[dx,dy,dz] (sorting, things traveling).
    - draw: {"do":"draw","targets":"curve","seconds":2} traces a line that has "drawn": false.
    - add: {"do":"add","objects":[{...object...}]} brings in new objects (they fade in).
    - camera: {"do":"camera","fit":["id1","id2"],"angle":[45,20],"seconds":1.6} frames those objects; {"do":"camera","fit":true} frames everything.
    - orbit: {"do":"orbit","enabled":false} stops the slow auto-rotation.
    - clearEffects: removes earlier arrows, flows, and plumes.
    - update: {"do":"update","target":"eqCard","math":"...","text":"...","title":"..."} changes a card's content with a soft transition: show an equation turning into the next form one step at a time, or a running total.
    - label also takes "math" instead of "text" for a short equation label: {"do":"label","position":[x,y,z],"math":"y = x^2"}.
    TIMING: any action can have "delay" (seconds after the step starts), so one step plays as a sequence instead of all at once: compare, then swap, then highlight the next pair; or light up a network layer by layer (delays 0, 0.8, 1.6). Keep the last delay within the time the narration takes to speak (about 2.5 words per second), and describe the sequence in the narration in the same order.
    Actions from earlier steps stay in effect (labels, flows, highlights) until you undo them, so tidy up: unlabel old labels and clearEffects when the focus moves on.

    LIVE SLIDERS (let the user play with the idea; use them whenever a number controls the behavior: learning rate, input size n, k in k-nearest neighbors, a probability, a function's coefficients, temperature, momentum):
    - Show one with {"do":"slider","id":"lr","label":"Learning rate","min":0.01,"max":1.05,"step":0.01,"value":0.1}. The id is a variable name. One or two sliders per scene, usually in the last step or two, with narration that invites the user to drag it and says what to watch for ("drag the learning rate up and watch the steps start to overshoot"). The slider panel sits in the top-left corner of the stage, so keep that area empty. {"do":"hideSliders"} removes them.
    - Optional setup field "variables": {"lr": 0.1} gives starting values, so objects can use a variable before its slider appears.
    - Things react through expressions: strings with numbers, variables, + - * / ^, parentheses, pi, and the functions sin cos tan sqrt abs exp ln log log2 log10 min max floor ceil round pow sigmoid. No other code.
    - "bind" on any object: {"bind":{"position":[x,y,z],"scale":s or [sx,sy,sz],"opacity":o}}, each value a number or an expression like "lr * 4" (null keeps that axis). A rect scales from its center, so to grow a bar upward from a baseline at y = -3, bind both "scale":[1,"h",1] and "position":[x,"-3 + h * height / 2",0] (height = the rect's own height).
    - "plot" on a line instead of "points": {"plot":{"y":"a * x^2","from":-3,"to":3,"samples":80,"origin":[ox,oy],"unit":[sx,sy]}} draws y = f(x); graph point (x, y) lands at scene (ox + x * sx, oy + y * sy). Or the path of a repeated update: {"plot":{"iterate":{"start":2.8,"next":"x - lr * 2 * x","count":10},"y":"x^2","origin":[...],"unit":[...],"markers":0.15}} plots x, next(x), next(next(x)), ... with a dot at each point (gradient descent steps, Newton's method, a recurrence). Plots redraw instantly when a slider moves, and work with "drawn": false and "draw".
    - Live numbers: "[[expression]]" inside card title, text, or math, or label text, shows the current value, for example "text":"Steps needed: [[ceil(log2(n))]]" or "math":"w_{\\\\text{new}} = w - [[lr]] \\\\cdot 2w".

    MAKING IT GOOD
    - 5 to 9 steps. Build understanding in this order: the problem it solves (why it exists), a real-world analogy, what it is and its parts, how it works on a tiny concrete example, the key insight, how it connects to other ideas, a one-sentence summary.
    - Each step has one clear visual change and 1 to 3 short spoken sentences of narration, warm and spoken, no markdown. The narration must describe exactly what that step shows.
    - Every step should move the camera or the focus to what it's about (camera fit on the parts being explained).
    - Make models recognizable: compose them from several shapes with sensible proportions and distinct colors per part. Stylized and clear beats detailed and cluttered. Use at most 40 objects in total.
    - Every id used in an action must exist (in setup or added in an earlier or the same step).
    - Don't attach things to objects that are moving (revolving or moving): if you need a label or line on a moving object, stop it first.
    - Be accurate. If the topic is abstract (ideas, history, economics), use a 2d diagram: cards, connecting arrows or lines, a timeline line with circle markers and cards, or a simple chart built from rects.

    SIMPLE ENGLISH (the user wants to understand deeply, not be impressed):
    - Short sentences and everyday words, as if explaining to a smart friend who is new to the topic. One idea per sentence.
    - Use a technical word only when it matters, and say what it means the first time, in plain words ("a pointer, which is the address of where something lives in memory").
    - Intuition first, then the precise idea. Show a formula only after its meaning is clear, as a card with "math", and say aloud what it means in words ("the new weight is the old weight minus a small step downhill"), never by reading symbols.
    - Use small, concrete numbers in examples (five items, not n; a learning rate of 0.1, not alpha).
    - Never say "simply", "just", "obviously", or "trivially".

    REAL-WORLD ANALOGY (always include one):
    - Give one step to an everyday analogy that matches how the idea really works, shown visually in a corner (cards, simple shapes) next to the real thing. For example: a hash map is a coat check, where your ticket number tells the attendant exactly which hook to go to; a stack is a pile of plates; a queue is a line at a coffee shop; recursion is a set of nesting dolls; gradient descent is walking downhill in fog by feeling the slope under your feet; attention is a student highlighting the words in a sentence that matter for the question; an ai agent is an intern who reads the task, uses tools, checks the result, and tries again.
    - Say where the analogy breaks down when that matters, in one short sentence.

    CONNECTING IDEAS:
    - Show where the idea fits: what it builds on and what builds on it. When the user prompt lists topics the user has already learned, link to one or two of them where it truly helps ("remember arrays? a hash map is an array plus a clever way to pick the slot"), shown as a card or a line to a small labeled circle.
    - Point out the one key insight that makes the idea click, and compare it with a close neighbor when that clears up confusion (array versus linked list, stack versus queue, supervised versus unsupervised learning).

    DRAWING CS, MATH, AND ML IDEAS (use 2d unless the idea is physical):
    - Data as shapes: arrays as rows of rects with the index under each and the value inside; nodes as circles joined by lines (trees top to bottom); pointers as small arrows or colored circles that move.
    - Processes as motion: walk through a tiny input step by step with "move", "highlight", and "delay"; show flows (data, gradients, an agent's loop) with "flow".
    - Math as graphs: labeled axes, "plot" curves, equations in "math" cards, and a slider for the number that matters.
    - Code: a card with "code": true holds a few lines of real code (under 8 short lines, with real line breaks written as \\n); narrate what it does in words, never read it out symbol by symbol.
    - When the user prompt includes topic recipes, follow them: they hold the best analogy, example, and drawing for that subject.

    CONCEPTS: after the quiz, add one last line: {"concepts":{"main":"Hash map","related":["Array","Hash function","Set"],"prerequisites":["Array"]}} where main is the topic's short common name (2 to 4 words, title case), related lists 2 to 5 closely connected ideas, and prerequisites lists the ideas worth knowing first. Use the exact names of already-learned topics when they fit, so the user's concept map links them.

    QUIZ: after the last step, add a line: {"quiz":[{"question":"...","choices":["...","...","...","..."],"answerIndex":2,"explanation":"one short sentence"}]} with 2 or 3 questions that check the key ideas (not trivia), 3 or 4 short choices each, one clearly correct.

    PRE-BUILT PARTS (use them where they fit; they look much better than stacking boxes):
    - gear: "radius", "teeth" (6-60), "thickness", optional "innerRadius", "holeRadius". A flat toothed gear facing +z (rotate [90,0,0] to lay it flat). Meshing gears: place centers about radiusA + radiusB × 0.9 apart, and spin them in opposite directions with speeds in the inverse ratio of their teeth.
    - capsule: "radius", "height" — a cylinder with rounded ends (cells, bacteria, pills, pistons, batteries).
    - spring: "radius", "height", "coils", "wireRadius" — a coil around the y axis (springs, coils, solenoids, windings).

    EXAMPLE (shortened):
    {"title":"Why compound interest snowballs","mode":"2d","view":{"width":18},"camera":{"fit":true},"objects":[{"id":"xAxis","shape":"line","points":[[-7,-4,0],[7,-4,0]],"width":0.06,"color":"#6b736f"},{"id":"yAxis","shape":"line","points":[[-7,-4,0],[-7,5,0]],"width":0.06,"color":"#6b736f"},{"id":"simple","shape":"line","drawn":false,"width":0.12,"color":"#7cc4ff","points":[[-7,-3,0],[0,-0.2,0],[7,2.6,0]]}]}
    {"narration":"Here's how a balance grows over thirty years.","actions":[{"do":"label","position":[0,-4.6,0],"text":"Years"},{"do":"label","position":[-7,4.6,0],"text":"Balance"}]}
    {"narration":"With simple interest you earn the same amount every year, so the balance climbs in a straight line.","actions":[{"do":"draw","targets":"simple","seconds":2},{"do":"add","objects":[{"id":"simpleCard","shape":"card","title":"Simple interest","text":"Earns only on what you put in.","position":[-3.5,3.4,0],"color":"#7cc4ff"}]}]}
    """
}

/// Splits growing streamed text into complete lines, returning each line
/// only once.
@MainActor
private final class JSONLineReader {
    private var consumedCharacterCount = 0

    /// The full text seen so far, to recover the final line (which has no
    /// trailing newline) once the stream ends.
    private var latestAccumulatedText = ""

    func newCompleteLines(in accumulatedText: String) -> [String] {
        latestAccumulatedText = accumulatedText
        guard accumulatedText.count > consumedCharacterCount else { return [] }
        let unconsumedText = accumulatedText.dropFirst(consumedCharacterCount)
        guard let lastNewlineIndex = unconsumedText.lastIndex(of: "\n") else { return [] }

        let completeText = unconsumedText[..<lastNewlineIndex]
        consumedCharacterCount += completeText.count + 1
        return completeText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whatever follows the last newline once the stream has ended.
    func remainingPartialLine() -> String? {
        let remainingText = latestAccumulatedText
            .dropFirst(consumedCharacterCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        consumedCharacterCount = latestAccumulatedText.count
        return remainingText.isEmpty ? nil : remainingText
    }
}
