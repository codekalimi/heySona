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

@MainActor
final class VisualExplanationSession {
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

    init(
        explanationBrief: String,
        userQuestion: String,
        claudeAPI: ClaudeAPI,
        elevenLabsTTSClient: ElevenLabsTTSClient,
        explainerPanelManager: VisualExplainerPanelManager,
        isNarrationEnabled: Bool
    ) {
        self.explanationBrief = explanationBrief
        self.userQuestion = userQuestion
        self.claudeAPI = claudeAPI
        self.elevenLabsTTSClient = elevenLabsTTSClient
        self.explainerPanelManager = explainerPanelManager
        self.isNarrationEnabled = isNarrationEnabled
    }

    // MARK: - Start And Stop

    func start() {
        explainerPanelManager.showPreparingStatus("Building your explanation…")
        explainerPanelManager.onStepStarted = { [weak self] stepIndex, _ in
            self?.handleWindowStepStarted(stepIndex: stepIndex)
        }
        explainerPanelManager.onPlayPauseRequested = { [weak self] isPlaying in
            self?.handleWindowPlayPause(isPlaying: isPlaying)
        }

        sceneStreamingTask = Task { [weak self] in
            await self?.streamSceneFromClaude()
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
    }

    // MARK: - Scene Streaming

    private func streamSceneFromClaude() async {
        let sceneLineReader = JSONLineReader()

        do {
            _ = try await claudeAPI.analyzeImageStreaming(
                images: [],
                systemPrompt: Self.sceneAuthoringSystemPrompt,
                userPrompt: """
                The user asked: "\(userQuestion)"

                What to explain: \(explanationBrief)

                Write the scene now, as JSON Lines.
                """,
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

        if !hasShownSceneHeader {
            // Steps written inside the header (instead of on their own
            // lines) are split out and handled like streamed steps.
            var sceneHeader = lineObject
            let stepsInsideHeader = sceneHeader["steps"] as? [[String: Any]] ?? []
            sceneHeader["steps"] = [Any]()
            guard let headerJSON = Self.jsonText(sceneHeader) else { return }

            hasShownSceneHeader = true
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
            return
        }

        handleStepObject(lineObject)
    }

    private func handleStepObject(_ stepObject: [String: Any]) {
        guard stepObject["narration"] != nil || stepObject["actions"] != nil,
              let stepJSON = Self.jsonText(stepObject) else { return }
        stepNarrations.append(stepObject["narration"] as? String ?? "")
        explainerPanelManager.appendStep(stepJSON: stepJSON)
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

    /// Appended to the main system prompt while visual explanations are on.
    static let mainReplySystemPromptSection = """

    visual explanations:
    you can open heySona's visual explainer: a window where an animated 3d model or 2d diagram is built and narrated step by step. use it when the user asks you to explain, show, teach, or visualize how something works, what's inside something, how a process unfolds, or how ideas connect, whenever seeing it would genuinely help (machines, science, the body, space, math ideas, algorithms, history, economics). don't use it for quick facts, yes or no questions, or things on their screen you can simply point at.
    when you use it, your spoken reply is only a short, natural one-sentence lead-in like "sure, let me show you how a rocket engine works." the explainer gives the full explanation, so don't explain it yourself. then add this tag at the very end, before [POINT:none]: [VISUAL:a detailed brief for the explainer: what to explain, the level (a curious beginner unless they say otherwise), the parts or stages to cover in order, and anything relevant from their screen or this conversation]. the brief must not contain square brackets.
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
    - card: "title", "text", "width" (pixels, 180-260) — a text box at "position" for definitions, notes, timeline events. Keep text under 25 words.

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
    Actions from earlier steps stay in effect (labels, flows, highlights) until you undo them, so tidy up: unlabel old labels and clearEffects when the focus moves on.

    MAKING IT GOOD
    - 5 to 8 steps. Build understanding in order: what it is, its parts, how they work together, the key insight, a closing summary.
    - Each step has one clear visual change and 1 to 3 short spoken sentences of narration: warm, plain language, no symbols or abbreviations that sound odd aloud, no markdown. The narration must describe exactly what that step shows.
    - Every step should move the camera or the focus to what it's about (camera fit on the parts being explained).
    - Make models recognizable: compose them from several shapes with sensible proportions and distinct colors per part. Stylized and clear beats detailed and cluttered. Use at most 40 objects in total.
    - Every id used in an action must exist (in setup or added in an earlier or the same step).
    - Don't attach things to objects that are moving (revolving or moving): if you need a label or line on a moving object, stop it first.
    - Be accurate. If the topic is abstract (ideas, history, economics), use a 2d diagram: cards, connecting arrows or lines, a timeline line with circle markers and cards, or a simple chart built from rects.

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
