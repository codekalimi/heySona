//
//  ClaudeModelRouting.swift
//  leanring-buddy
//
//  Auto mode (the "Auto" model choice): each question goes to the cheapest
//  Claude model that handles it well.
//  - Haiku: plain questions and explanations that don't need the screen.
//  - Sonnet: anything about the screen (pointing, guided tasks, Mac actions,
//    code on screen), and the safe choice when unsure.
//  - Opus: requests for deep, rigorous, or long explanations. Visual
//    explanation scenes always use Opus in Auto mode (see CompanionManager).
//
//  Free, instant rules decide most questions. Only when they're unsure does
//  a tiny Haiku call (question text only, no screenshot) classify it, with
//  a short time limit so a slow check never holds up the answer.
//

import Foundation

struct ClaudeModelRoutingDecision {
    let modelOption: ClaudeModelOption
    /// Short reason for the log and Settings, e.g. "plain explanation".
    let reason: String
    /// "rule" or "Haiku check".
    let decidedBy: String

    var summary: String {
        "\(modelOption.pickerLabel) — \(reason) (\(decidedBy))"
    }
}

enum ClaudeModelRouter {
    /// Words that point at the screen or at doing something on the Mac.
    private static let screenOrActionPhrases = [
        "this", "these", "that one", "here", "screen", "click", "button", "menu", "window", "tab",
        "where is", "where do", "where's", "how do i", "how can i", "show me where", "find the",
        "open", "close", "set ", "turn on", "turn off", "remind", "reminder", "calendar", "event",
        "volume", "mute", "play", "pause", "skip", "save", "note", "file", "folder", "shortcut",
        "error", "bug", "fix", "debug", "my code", "this code", "line", "selected", "highlighted",
        "settings", "install", "export", "import", "run ", "build", "compile",
    ]

    /// Words asking for depth rather than a quick answer.
    private static let deepExplanationPhrases = [
        "in depth", "in-depth", "deeply", "in detail", "detailed", "thorough", "thoroughly",
        "rigorous", "prove", "proof", "derive", "derivation", "from first principles",
        "go deeper", "explain everything", "full explanation", "comprehensive",
    ]

    /// Openers of general questions and explanations.
    private static let plainQuestionPhrases = [
        "what is", "what's", "what are", "what does", "explain", "how does", "how do ", "how is",
        "why", "difference between", "define", "meaning of", "tell me about", "teach me",
        "who ", "when ", "compare", "is it true", "can you explain", "help me understand",
    ]

    /// Decides from the question text alone; nil when the rules aren't sure.
    static func decideByRules(transcript: String, isGuidedTaskContinuation: Bool) -> ClaudeModelRoutingDecision? {
        if isGuidedTaskContinuation {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.sonnet, reason: "next step of a guided task", decidedBy: "rule")
        }
        let paddedQuestion = " " + transcript.lowercased() + " "
        func containsAny(_ phrases: [String]) -> Bool {
            phrases.contains { phrase in
                // Single words must stand alone ("this", not "thistle").
                if phrase.contains(" ") { return paddedQuestion.contains(phrase) }
                return paddedQuestion.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
            }
        }

        if containsAny(deepExplanationPhrases) {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.opus, reason: "asks for a deep explanation", decidedBy: "rule")
        }
        if containsAny(screenOrActionPhrases) {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.sonnet, reason: "about the screen or a Mac action", decidedBy: "rule")
        }
        if containsAny(plainQuestionPhrases) {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.haiku, reason: "plain question or explanation", decidedBy: "rule")
        }
        return nil
    }

    private static let classifierSystemPrompt = """
    You route questions for heySona, a voice assistant on the user's Mac that can see their screen. Reply with exactly one word:
    SIMPLE: general knowledge or an explanation that doesn't need the user's screen.
    SCREEN: about something on the user's screen, a task in an app, code they're looking at, or an action on their Mac.
    DEEP: asks for a thorough, rigorous, or long explanation, a proof, or a derivation.
    """

    /// Asks Haiku to classify the question (text only). Falls back to Sonnet
    /// if the check fails or takes longer than `timeLimitInSeconds`.
    static func decideWithHaikuCheck(
        transcript: String,
        haikuClaudeAPI: ClaudeAPI,
        timeLimitInSeconds: Double = 2.5
    ) async -> ClaudeModelRoutingDecision {
        let fallbackDecision = ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.sonnet, reason: "unclear question", decidedBy: "default")
        let classificationTask = Task { () -> String? in
            try? await haikuClaudeAPI.analyzeImage(
                images: [],
                systemPrompt: classifierSystemPrompt,
                userPrompt: "Question: \(transcript)"
            ).text
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeLimitInSeconds * 1_000_000_000))
            classificationTask.cancel()
        }
        let classificationText = await classificationTask.value
        timeoutTask.cancel()

        guard let classificationWord = classificationText?.uppercased() else { return fallbackDecision }
        if classificationWord.contains("DEEP") {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.opus, reason: "asks for a deep explanation", decidedBy: "Haiku check")
        }
        if classificationWord.contains("SCREEN") {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.sonnet, reason: "about the screen or a Mac action", decidedBy: "Haiku check")
        }
        if classificationWord.contains("SIMPLE") {
            return ClaudeModelRoutingDecision(modelOption: ClaudeModelCatalog.haiku, reason: "plain question or explanation", decidedBy: "Haiku check")
        }
        return fallbackDecision
    }
}

// MARK: - Choosing The Model For A Reply

extension CompanionManager {
    /// The chosen model, or in Auto mode the routed one (logged and shown in Settings).
    func responseModelOption(for transcript: String) async -> ClaudeModelOption {
        guard selectedModel == ClaudeModelCatalog.autoModelChoiceID else {
            return ClaudeModelCatalog.modelOption(forModelID: selectedModel) ?? ClaudeModelCatalog.defaultModelOption
        }
        let routingDecision: ClaudeModelRoutingDecision
        if let ruleDecision = ClaudeModelRouter.decideByRules(
            transcript: transcript,
            isGuidedTaskContinuation: transcript.hasPrefix("(guided mode)")
        ) {
            routingDecision = ruleDecision
        } else {
            routingDecision = await ClaudeModelRouter.decideWithHaikuCheck(
                transcript: transcript,
                haikuClaudeAPI: claudeAPI(for: ClaudeModelCatalog.haiku)
            )
        }
        lastAutoModelRoutingSummary = routingDecision.summary
        print("🧭 Auto model: \(routingDecision.summary)")
        return routingDecision.modelOption
    }

    /// The connection for a model: the main one if it matches, otherwise one
    /// kept per model (so each warms up its connection once).
    func claudeAPI(for modelOption: ClaudeModelOption) -> ClaudeAPI {
        if claudeAPI.model == modelOption.modelID { return claudeAPI }
        if let existingClaudeAPI = claudeAPIsByRoutedModelID[modelOption.modelID] { return existingClaudeAPI }
        let routedClaudeAPI = ClaudeAPI(model: modelOption.modelID)
        claudeAPIsByRoutedModelID[modelOption.modelID] = routedClaudeAPI
        return routedClaudeAPI
    }
}
