//
//  ClaudeModelCatalog.swift
//  leanring-buddy
//
//  The Claude models heySona offers, and the per-model request settings
//  that go with them. Both model pickers (menu bar panel and Settings) read
//  from here so they always match.
//

import Foundation

struct ClaudeModelOption: Identifiable, Equatable {
    let modelID: String
    let pickerLabel: String
    let pickerDetail: String
    /// Whether the model accepts `fallbacks: "default"`, which re-runs a
    /// request on another model when a safety classifier declines it.
    /// Claude Haiku 5.5 has no server-side fallback.
    let supportsServerSideRefusalFallback: Bool

    var id: String { modelID }
}

enum ClaudeModelCatalog {
    static let haiku = ClaudeModelOption(
        modelID: "claude-haiku-5-5",
        pickerLabel: "Haiku",
        pickerDetail: "Fastest",
        supportsServerSideRefusalFallback: false
    )

    static let sonnet = ClaudeModelOption(
        modelID: "claude-sonnet-5-5",
        pickerLabel: "Sonnet",
        pickerDetail: "Balanced",
        supportsServerSideRefusalFallback: true
    )

    static let opus = ClaudeModelOption(
        modelID: "claude-opus-5-5",
        pickerLabel: "Opus",
        pickerDetail: "Smartest",
        supportsServerSideRefusalFallback: true
    )

    /// Picker order, fastest to smartest.
    static let allModelOptions = [haiku, sonnet, opus]

    static let defaultModelOption = opus

    /// How much the model thinks before answering. heySona's replies are
    /// short and spoken, so time to first word matters most; "low" keeps
    /// thinking brief while the current models still read screenshots well.
    /// Raise to "medium" if answers or pointing get less accurate.
    static let responseEffortLevel = "low"

    /// Room for adaptive thinking plus the reply. Thinking counts toward
    /// this limit, so a small value would cut replies off.
    static let streamingResponseMaximumTokens = 64000

    /// Maps a saved model ID to a current option. Older saved choices
    /// (Sonnet 4.6, Opus 4.6) move to the same family's current model, and
    /// anything unknown falls back to the default.
    static func modelOption(forSavedModelID savedModelID: String?) -> ClaudeModelOption {
        guard let savedModelID else { return defaultModelOption }

        if let currentModelOption = allModelOptions.first(where: { $0.modelID == savedModelID }) {
            return currentModelOption
        }
        if savedModelID.contains("sonnet") { return sonnet }
        if savedModelID.contains("haiku") { return haiku }
        return defaultModelOption
    }

    static func modelOption(forModelID modelID: String) -> ClaudeModelOption? {
        allModelOptions.first { $0.modelID == modelID }
    }
}
