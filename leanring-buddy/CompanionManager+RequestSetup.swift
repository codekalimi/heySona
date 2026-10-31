//
//  CompanionManager+RequestSetup.swift
//  leanring-buddy
//
//  Builds each Claude request: which tools are available, the system prompt
//  sections for enabled features, and context added to the user message.
//  Split out of CompanionManager.swift; the state these methods use
//  lives there.
//

import AppKit
import Foundation
import SwiftUI

extension CompanionManager {
    /// Everything that varies per request: the system prompt sections, the
    /// user message with context appended, the tools, and who runs them.
    struct RequestSetup {
        let systemPrompt: String
        let userPrompt: String
        let toolDefinitions: [[String: Any]]
        let toolCallHandler: ClaudeToolCallHandler
    }

    /// Builds the request for one question. Called right when the question
    /// is sent, so project detection sees the app the user is working in.
    func makeRequestSetup(transcript: String) -> RequestSetup {
        var systemPrompt = Self.companionVoiceResponseSystemPrompt
        var toolDefinitions: [[String: Any]] = []
        // The local time lets "remind me tomorrow at 3" or "what day is it"
        // resolve correctly.
        var userMessageContextLines = ["current local time: \(Self.currentLocalTimeDescription())"]
        // Menus, panels, and shortcuts differ between apps and versions, so
        // Claude is told exactly which app (and version) the user is in.
        if let frontmostApplicationDescription = Self.frontmostApplicationDescription() {
            userMessageContextLines.append("app in front: \(frontmostApplicationDescription) (match its menus, panel names, and shortcuts to this version)")
        }

        if isScreenDrawingEnabled {
            systemPrompt += ScreenDrawingTagParser.systemPromptSection
        }

        if isStepGuidanceEnabled {
            systemPrompt += StepGuidanceParser.systemPromptSection
            if isGuidedModeEnabled {
                systemPrompt += Self.guidedModeSystemPromptSection
            }
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
    func makeToolCallHandler(detectedProject: DetectedProject?) -> ClaudeToolCallHandler {
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

    /// e.g. "DaVinci Resolve 19.1.3", or nil when heySona itself is in front.
    /// The type-to-ask box doesn't activate heySona, so this is the app the
    /// user was working in.
    static func frontmostApplicationDescription() -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let applicationName = frontmostApplication.localizedName else {
            return nil
        }
        let applicationVersion = frontmostApplication.bundleURL
            .flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return [applicationName, applicationVersion].compactMap { $0 }.joined(separator: " ")
    }

    /// e.g. "Saturday, October 31, 2026 at 3:12 PM (America/Los_Angeles)"
    static func currentLocalTimeDescription() -> String {
        let localTimeFormatter = DateFormatter()
        localTimeFormatter.dateStyle = .full
        localTimeFormatter.timeStyle = .short
        return "\(localTimeFormatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }
}
